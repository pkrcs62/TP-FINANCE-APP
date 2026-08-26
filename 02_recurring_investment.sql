-- ============================================================================
-- FinSphere — Recurring Investment Plan module
-- Standalone additive migration. Safe to run on top of the existing live
-- database regardless of drift from 01_schema_and_functions.sql (this file
-- does not touch any existing table/function). Every statement below is
-- create-if-not-exists / create-or-replace, so it is also safe to re-run.
--
-- Scope (per implementation plan): recurring monthly-contribution investment
-- plans, one plan/account per investor (NOT 12 separate accounts), 12-month
-- cycles, year-end Pay/Reinvest interest action, explicit catch-up
-- confirmation for missed months. Reuses investors/accounts/transactions —
-- does NOT alter loan, EMI, Bullet, Overdraft, or one-time investor logic.
-- ============================================================================

-- ---------- Table ----------

create table if not exists recurring_plans (
  id uuid primary key default gen_random_uuid(),
  plan_no text not null,                    -- e.g. 'RP-1', shown in UI
  investor_id text not null references investors(id),
  account_id uuid references accounts(id),  -- the investment account this plan's contributions post into
  monthly_amount numeric not null,
  contribution_day integer not null check (contribution_day between 1 and 28), -- capped at 28 so every month has that day
  start_date date not null,
  cycle_months integer not null default 12,
  annual_roi numeric not null,
  status text not null default 'ACTIVE',    -- ACTIVE | MATURED_PENDING_ACTION | CLOSED
  current_cycle_no integer not null default 1,
  current_cycle_start date not null,
  current_cycle_end date not null,          -- current_cycle_start + cycle_months, minus a day
  next_contribution_date date not null,
  year_end_action text not null default 'PAY', -- 'PAY' | 'REINVEST' — the investor's standing choice; asked again at each cycle-end screen
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_recurring_plans_investor on recurring_plans (investor_id);
create index if not exists idx_recurring_plans_status on recurring_plans (status);

-- One row per monthly contribution posted for a plan — separate from the
-- investor `transactions` table (which still records the actual money
-- movement/receipt) so we can track contribution-vs-cycle bookkeeping
-- (which month, which cycle, paid or not) without overloading the generic
-- transactions schema. Mirrors the loan_emi_schedule pattern.
create table if not exists recurring_contributions (
  id uuid primary key default gen_random_uuid(),
  recurring_plan_id uuid not null references recurring_plans(id),
  cycle_no integer not null,
  due_date date not null,
  amount numeric not null,
  status text not null default 'PENDING',   -- PENDING | PAID
  paid_date date,
  paid_txn_id uuid references transactions(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_recurring_contrib_plan on recurring_contributions (recurring_plan_id);

-- One row per completed 12-month cycle: principal contributed, interest
-- computed, and which year-end action was taken. Locked once processed —
-- prevents duplicate year-end processing (backend safety requirement).
create table if not exists recurring_cycle_history (
  id uuid primary key default gen_random_uuid(),
  recurring_plan_id uuid not null references recurring_plans(id),
  cycle_no integer not null,
  cycle_start date not null,
  cycle_end date not null,
  principal_contributed numeric not null,
  interest_earned numeric not null,
  total_value numeric not null,
  action_taken text not null,               -- 'PAY' | 'REINVEST'
  action_txn_id uuid references transactions(id),
  processed_at timestamptz not null default now(),
  unique (recurring_plan_id, cycle_no)
);

alter table recurring_plans enable row level security;
alter table recurring_contributions enable row level security;
alter table recurring_cycle_history enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'recurring_plans' and policyname = 'public read/write recurring_plans') then
    create policy "public read/write recurring_plans" on recurring_plans for all using (true) with check (true);
  end if;
  if not exists (select 1 from pg_policies where tablename = 'recurring_contributions' and policyname = 'public read/write recurring_contributions') then
    create policy "public read/write recurring_contributions" on recurring_contributions for all using (true) with check (true);
  end if;
  if not exists (select 1 from pg_policies where tablename = 'recurring_cycle_history' and policyname = 'public read/write recurring_cycle_history') then
    create policy "public read/write recurring_cycle_history" on recurring_cycle_history for all using (true) with check (true);
  end if;
end $$;

-- ============================================================================
-- Business logic
-- ============================================================================

-- Adds N calendar months to a date, clamping the day-of-month (Postgres
-- '+ interval' already clamps sensibly for month-end, but we pin to
-- contribution_day explicitly for predictability since contribution_day is
-- capped at 28).
create or replace function recurring_add_months(p_date date, p_months integer, p_day integer)
returns date language plpgsql immutable as $$
declare
  base date;
begin
  base := (date_trunc('month', p_date) + (p_months || ' months')::interval)::date;
  return make_date(extract(year from base)::int, extract(month from base)::int, p_day);
end;
$$;

-- ---------- Create a recurring plan ----------
-- p: investorId, monthlyAmount, contributionDay, startDate, annualRoi,
--    cycleMonths (optional, default 12), yearEndAction (optional, default PAY)
-- Creates one investment account for the plan (opening amount = first
-- month's contribution, so it shows up like a normal investor account),
-- posts that first contribution as a normal INVESTMENT transaction via the
-- existing add_investment(), and schedules the remaining 11 due dates.
create or replace function add_recurring_plan(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_investor investors%rowtype;
  v_plan_seq integer;
  v_plan_no text;
  v_plan recurring_plans%rowtype;
  v_monthly numeric := (p->>'monthlyAmount')::numeric;
  v_day integer := (p->>'contributionDay')::integer;
  v_start date := (p->>'startDate')::date;
  v_roi numeric := (p->>'annualRoi')::numeric;
  v_cycle_months integer := coalesce((p->>'cycleMonths')::integer, 12);
  v_year_end text := coalesce(p->>'yearEndAction', 'PAY');
  v_investment_result jsonb;
  v_account_id uuid;
  v_first_txn jsonb;
  i integer;
  v_due date;
begin
  select * into v_investor from investors where id = p->>'investorId';
  if not found then return jsonb_build_object('error', 'Investor not found'); end if;
  if v_monthly is null or v_monthly <= 0 then return jsonb_build_object('error', 'Monthly amount must be greater than zero'); end if;
  if v_day is null or v_day < 1 or v_day > 28 then return jsonb_build_object('error', 'Contribution day must be between 1 and 28'); end if;
  if v_roi is null or v_roi < 0 then return jsonb_build_object('error', 'Annual ROI is required'); end if;
  if v_start is null then return jsonb_build_object('error', 'Start date is required'); end if;
  if v_year_end not in ('PAY','REINVEST') then return jsonb_build_object('error', 'Invalid year-end action'); end if;

  -- Create the backing investment account + first month's contribution
  -- through the existing, unmodified add_investment() — this is the
  -- "normal investment transaction" the plan means: no new account/txn
  -- logic duplicated here.
  v_investment_result := add_investment(jsonb_build_object(
    'investorId', p->>'investorId',
    'amount', v_monthly,
    'date', v_start::text,
    'roi', v_roi,
    'remarks', 'Recurring plan — Month 1 contribution',
    'paymentMode', coalesce(p->>'paymentMode','')
  ));
  if v_investment_result ? 'error' then return v_investment_result; end if;

  v_account_id := (v_investment_result->'account'->>'id')::uuid;
  v_first_txn := v_investment_result->'transaction';

  v_plan_seq := next_available_number('recurring_plans', 'plan_no', 'RP');
  v_plan_no := 'RP-' || v_plan_seq;

  insert into recurring_plans (
    plan_no, investor_id, account_id, monthly_amount, contribution_day,
    start_date, cycle_months, annual_roi, status,
    current_cycle_no, current_cycle_start, current_cycle_end,
    next_contribution_date, year_end_action
  ) values (
    v_plan_no, p->>'investorId', v_account_id, v_monthly, v_day,
    v_start, v_cycle_months, v_roi, 'ACTIVE',
    1, v_start, recurring_add_months(v_start, v_cycle_months, v_day) - 1,
    recurring_add_months(v_start, 1, v_day), v_year_end
  ) returning * into v_plan;

  -- Record Month 1 as already-paid, then schedule the remaining
  -- (cycle_months - 1) months as PENDING.
  insert into recurring_contributions (recurring_plan_id, cycle_no, due_date, amount, status, paid_date, paid_txn_id)
  values (v_plan.id, 1, v_start, v_monthly, 'PAID', v_start, (v_first_txn->>'id')::uuid);

  v_due := v_start;
  for i in 2..v_cycle_months loop
    v_due := recurring_add_months(v_start, i - 1, v_day);
    insert into recurring_contributions (recurring_plan_id, cycle_no, due_date, amount, status)
    values (v_plan.id, 1, v_due, v_monthly, 'PENDING');
  end loop;

  perform log_audit('CREATE', 'RecurringPlan', v_plan.id::text, to_jsonb(v_plan));
  return jsonb_build_object('ok', true, 'plan', to_jsonb(v_plan), 'account', v_investment_result->'account');
end;
$$;

-- ---------- List due/unpaid contributions for a plan (for the Process Due screen) ----------
-- Never silently creates a transaction — read-only, requires an explicit
-- confirm step via process_due_contributions below.
create or replace function get_due_contributions(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_plan_id uuid := (p->>'recurringPlanId')::uuid;
  v_due jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(c) order by c.due_date), '[]'::jsonb) into v_due
  from recurring_contributions c
  where c.recurring_plan_id = v_plan_id
    and c.status = 'PENDING'
    and c.due_date <= current_date;

  return jsonb_build_object('ok', true, 'due', v_due);
end;
$$;

-- ---------- Process (confirm) one or more due contributions ----------
-- p: recurringPlanId, contributionIds (array of recurring_contributions.id
--    the person confirmed), date (optional posting date, default today),
--    paymentMode (optional)
-- Posts each confirmed contribution as a normal TOPUP transaction on the
-- plan's account via the existing add_investment() top-up path, then marks
-- it PAID and advances next_contribution_date. Explicit confirm-per-month —
-- never auto-posts anything on its own.
create or replace function process_due_contributions(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_plan recurring_plans%rowtype;
  v_ids uuid[];
  v_contrib recurring_contributions%rowtype;
  v_post_date date := coalesce((p->>'date')::date, current_date);
  v_result jsonb;
  v_posted jsonb := '[]'::jsonb;
  v_max_due date;
begin
  select * into v_plan from recurring_plans where id = (p->>'recurringPlanId')::uuid;
  if not found then return jsonb_build_object('error', 'Recurring plan not found'); end if;
  if v_plan.status <> 'ACTIVE' then return jsonb_build_object('error', 'Plan is not active'); end if;

  select array_agg((x)::uuid) into v_ids from jsonb_array_elements_text(p->'contributionIds') x;
  if v_ids is null or array_length(v_ids,1) is null then
    return jsonb_build_object('error', 'No contributions selected');
  end if;

  for v_contrib in
    select * from recurring_contributions
    where id = any(v_ids) and recurring_plan_id = v_plan.id and status = 'PENDING'
    order by due_date asc
  loop
    v_result := add_investment(jsonb_build_object(
      'investorId', v_plan.investor_id,
      'amount', v_contrib.amount,
      'date', v_post_date::text,
      'topUpAccountId', v_plan.account_id::text,
      'remarks', 'Recurring plan — Month ' || v_contrib.cycle_no || ' contribution (due ' || v_contrib.due_date || ')',
      'paymentMode', coalesce(p->>'paymentMode','')
    ));
    if v_result ? 'error' then return v_result; end if;

    update recurring_contributions
      set status = 'PAID', paid_date = v_post_date, paid_txn_id = (v_result->'transaction'->>'id')::uuid
      where id = v_contrib.id;

    v_posted := v_posted || jsonb_build_object('contributionId', v_contrib.id, 'transaction', v_result->'transaction');
  end loop;

  -- Advance next_contribution_date to the earliest still-PENDING due date.
  select min(due_date) into v_max_due from recurring_contributions
    where recurring_plan_id = v_plan.id and status = 'PENDING';

  update recurring_plans
    set next_contribution_date = coalesce(v_max_due, current_cycle_end + 1),
        updated_at = now()
    where id = v_plan.id;

  perform log_audit('PROCESS_DUE', 'RecurringPlan', v_plan.id::text, jsonb_build_object('posted', v_posted));
  return jsonb_build_object('ok', true, 'posted', v_posted);
end;
$$;

-- ---------- Compute a plan's live cycle summary ----------
-- Returns principal contributed so far in the CURRENT cycle, interest
-- earned (via the existing compute_account_value engine — same
-- investment-interest methodology the plan doc requires), and total value.
-- Used both for the ongoing dashboard card and to decide cycle maturity.
create or replace function get_recurring_plan_summary(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_plan recurring_plans%rowtype;
  v_val record;
  v_principal_this_cycle numeric;
  v_paid_count integer;
  v_total_count integer;
  v_is_matured boolean;
begin
  select * into v_plan from recurring_plans where id = (p->>'recurringPlanId')::uuid;
  if not found then return jsonb_build_object('error', 'Recurring plan not found'); end if;

  select * into v_val from compute_account_value(v_plan.account_id, current_date);

  select coalesce(sum(amount),0) into v_principal_this_cycle
  from recurring_contributions
  where recurring_plan_id = v_plan.id and cycle_no = v_plan.current_cycle_no and status = 'PAID';

  select count(*) filter (where status='PAID'), count(*) into v_paid_count, v_total_count
  from recurring_contributions where recurring_plan_id = v_plan.id and cycle_no = v_plan.current_cycle_no;

  v_is_matured := current_date > v_plan.current_cycle_end and v_plan.status = 'ACTIVE';
  if v_is_matured and v_plan.status = 'ACTIVE' then
    update recurring_plans set status = 'MATURED_PENDING_ACTION', updated_at = now() where id = v_plan.id;
    v_plan.status := 'MATURED_PENDING_ACTION';
  end if;

  return jsonb_build_object(
    'ok', true,
    'plan', to_jsonb(v_plan),
    'principalThisCycle', v_principal_this_cycle,
    'interestEarned', v_val.accrued_interest,
    'runningBalance', v_val.running_balance,
    'totalValue', v_val.current_value,
    'contributionsPaid', v_paid_count,
    'contributionsTotal', v_total_count,
    'isMatured', v_is_matured or v_plan.status = 'MATURED_PENDING_ACTION'
  );
end;
$$;

-- ---------- Year-end action: Pay Interest ----------
-- Pays out the accrued interest as a WITHDRAWAL-style transaction (does NOT
-- reduce principal — interest only), records it in recurring_cycle_history
-- (locking this cycle against reprocessing), then starts the next cycle and
-- schedules its 12 monthly due dates.
create or replace function recurring_pay_interest(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_plan recurring_plans%rowtype;
  v_val record;
  v_txn transactions%rowtype;
  v_principal_this_cycle numeric;
  v_next_cycle_start date;
  v_next_cycle_end date;
  i integer;
  v_due date;
begin
  select * into v_plan from recurring_plans where id = (p->>'recurringPlanId')::uuid;
  if not found then return jsonb_build_object('error', 'Recurring plan not found'); end if;
  if exists (select 1 from recurring_cycle_history where recurring_plan_id = v_plan.id and cycle_no = v_plan.current_cycle_no) then
    return jsonb_build_object('error', 'This cycle has already been processed');
  end if;
  if current_date <= v_plan.current_cycle_end then
    return jsonb_build_object('error', 'Cycle has not matured yet');
  end if;

  select * into v_val from compute_account_value(v_plan.account_id, current_date);

  select coalesce(sum(amount),0) into v_principal_this_cycle
  from recurring_contributions
  where recurring_plan_id = v_plan.id and cycle_no = v_plan.current_cycle_no and status = 'PAID';

  -- Pay out interest without touching principal: a WITHDRAWAL of exactly
  -- the accrued interest amount. balance_after therefore returns to the
  -- running principal balance (interest zeroed for this event), matching
  -- "principal continues, next cycle starts".
  insert into transactions (account_id, investor_id, txn_date, txn_type, amount,
    balance_before, interest_added, balance_after, remarks)
  values (v_plan.account_id, v_plan.investor_id, current_date, 'WITHDRAWAL', v_val.accrued_interest,
    v_val.running_balance, v_val.accrued_interest, v_val.running_balance,
    'Recurring plan — Cycle ' || v_plan.current_cycle_no || ' interest payout')
  returning * into v_txn;

  insert into recurring_cycle_history (recurring_plan_id, cycle_no, cycle_start, cycle_end,
    principal_contributed, interest_earned, total_value, action_taken, action_txn_id)
  values (v_plan.id, v_plan.current_cycle_no, v_plan.current_cycle_start, v_plan.current_cycle_end,
    v_principal_this_cycle, v_val.accrued_interest, v_val.current_value, 'PAY', v_txn.id);

  v_next_cycle_start := v_plan.current_cycle_end + 1;
  v_next_cycle_end := recurring_add_months(v_next_cycle_start, v_plan.cycle_months, v_plan.contribution_day) - 1;

  update recurring_plans set
    status = 'ACTIVE',
    current_cycle_no = current_cycle_no + 1,
    current_cycle_start = v_next_cycle_start,
    current_cycle_end = v_next_cycle_end,
    next_contribution_date = recurring_add_months(v_next_cycle_start, 0, v_plan.contribution_day),
    updated_at = now()
  where id = v_plan.id;

  for i in 1..v_plan.cycle_months loop
    v_due := recurring_add_months(v_next_cycle_start, i - 1, v_plan.contribution_day);
    insert into recurring_contributions (recurring_plan_id, cycle_no, due_date, amount, status)
    values (v_plan.id, v_plan.current_cycle_no + 1, v_due, v_plan.monthly_amount, 'PENDING');
  end loop;

  perform log_audit('PAY_INTEREST', 'RecurringPlan', v_plan.id::text, to_jsonb(v_txn));
  return jsonb_build_object('ok', true, 'transaction', to_jsonb(v_txn), 'interestPaid', v_val.accrued_interest);
end;
$$;

-- ---------- Year-end action: Reinvest Interest ----------
-- Capitalizes the accrued interest into principal (a TOPUP for the interest
-- amount), records it in recurring_cycle_history (locking this cycle), then
-- starts the next cycle exactly like recurring_pay_interest.
create or replace function recurring_reinvest_interest(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_plan recurring_plans%rowtype;
  v_val record;
  v_txn transactions%rowtype;
  v_principal_this_cycle numeric;
  v_next_cycle_start date;
  v_next_cycle_end date;
  i integer;
  v_due date;
begin
  select * into v_plan from recurring_plans where id = (p->>'recurringPlanId')::uuid;
  if not found then return jsonb_build_object('error', 'Recurring plan not found'); end if;
  if exists (select 1 from recurring_cycle_history where recurring_plan_id = v_plan.id and cycle_no = v_plan.current_cycle_no) then
    return jsonb_build_object('error', 'This cycle has already been processed');
  end if;
  if current_date <= v_plan.current_cycle_end then
    return jsonb_build_object('error', 'Cycle has not matured yet');
  end if;

  select * into v_val from compute_account_value(v_plan.account_id, current_date);

  select coalesce(sum(amount),0) into v_principal_this_cycle
  from recurring_contributions
  where recurring_plan_id = v_plan.id and cycle_no = v_plan.current_cycle_no and status = 'PAID';

  -- Capitalize interest into principal via the existing TOPUP path.
  insert into transactions (account_id, investor_id, txn_date, txn_type, amount,
    balance_before, interest_added, balance_after, remarks)
  values (v_plan.account_id, v_plan.investor_id, current_date, 'TOPUP', v_val.accrued_interest,
    v_val.running_balance, v_val.accrued_interest, v_val.current_value,
    'Recurring plan — Cycle ' || v_plan.current_cycle_no || ' interest reinvested')
  returning * into v_txn;

  insert into recurring_cycle_history (recurring_plan_id, cycle_no, cycle_start, cycle_end,
    principal_contributed, interest_earned, total_value, action_taken, action_txn_id)
  values (v_plan.id, v_plan.current_cycle_no, v_plan.current_cycle_start, v_plan.current_cycle_end,
    v_principal_this_cycle, v_val.accrued_interest, v_val.current_value, 'REINVEST', v_txn.id);

  v_next_cycle_start := v_plan.current_cycle_end + 1;
  v_next_cycle_end := recurring_add_months(v_next_cycle_start, v_plan.cycle_months, v_plan.contribution_day) - 1;

  update recurring_plans set
    status = 'ACTIVE',
    current_cycle_no = current_cycle_no + 1,
    current_cycle_start = v_next_cycle_start,
    current_cycle_end = v_next_cycle_end,
    next_contribution_date = recurring_add_months(v_next_cycle_start, 0, v_plan.contribution_day),
    updated_at = now()
  where id = v_plan.id;

  for i in 1..v_plan.cycle_months loop
    v_due := recurring_add_months(v_next_cycle_start, i - 1, v_plan.contribution_day);
    insert into recurring_contributions (recurring_plan_id, cycle_no, due_date, amount, status)
    values (v_plan.id, v_plan.current_cycle_no + 1, v_due, v_plan.monthly_amount, 'PENDING');
  end loop;

  perform log_audit('REINVEST_INTEREST', 'RecurringPlan', v_plan.id::text, to_jsonb(v_txn));
  return jsonb_build_object('ok', true, 'transaction', to_jsonb(v_txn), 'interestReinvested', v_val.accrued_interest);
end;
$$;

-- ---------- List all recurring plans with live summary (for the dashboard) ----------
create or replace function get_all_recurring_plans()
returns jsonb language plpgsql as $$
declare
  v_plans jsonb;
begin
  select coalesce(jsonb_agg(
    to_jsonb(rp) || jsonb_build_object(
      'investorName', inv.name,
      'principalThisCycle', (
        select coalesce(sum(amount),0) from recurring_contributions c
        where c.recurring_plan_id = rp.id and c.cycle_no = rp.current_cycle_no and c.status = 'PAID'
      ),
      'contributionsPaid', (
        select count(*) from recurring_contributions c
        where c.recurring_plan_id = rp.id and c.cycle_no = rp.current_cycle_no and c.status = 'PAID'
      ),
      'contributionsTotal', (
        select count(*) from recurring_contributions c
        where c.recurring_plan_id = rp.id and c.cycle_no = rp.current_cycle_no
      ),
      'dueCount', (
        select count(*) from recurring_contributions c
        where c.recurring_plan_id = rp.id and c.status = 'PENDING' and c.due_date <= current_date
      ),
      'accruedInterest', v.accrued_interest,
      'currentValue', v.current_value,
      'isMatured', (current_date > rp.current_cycle_end and rp.status <> 'CLOSED')
    ) order by rp.created_at desc
  ), '[]'::jsonb) into v_plans
  from recurring_plans rp
  join investors inv on inv.id = rp.investor_id
  cross join lateral compute_account_value(rp.account_id, current_date) v;

  return jsonb_build_object('ok', true, 'recurringPlans', v_plans);
end;
$$;

-- ---------- Plan detail: investor info + full contribution history ----------
create or replace function get_recurring_plan_detail(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_plan recurring_plans%rowtype;
  v_investor investors%rowtype;
  v_contributions jsonb;
  v_history jsonb;
  v_val record;
begin
  select * into v_plan from recurring_plans where id = (p->>'recurringPlanId')::uuid;
  if not found then return jsonb_build_object('error', 'Recurring plan not found'); end if;
  select * into v_investor from investors where id = v_plan.investor_id;

  select coalesce(jsonb_agg(to_jsonb(c) order by c.due_date), '[]'::jsonb) into v_contributions
  from recurring_contributions c where c.recurring_plan_id = v_plan.id;

  select coalesce(jsonb_agg(to_jsonb(h) order by h.cycle_no), '[]'::jsonb) into v_history
  from recurring_cycle_history h where h.recurring_plan_id = v_plan.id;

  select * into v_val from compute_account_value(v_plan.account_id, current_date);

  return jsonb_build_object(
    'ok', true,
    'plan', to_jsonb(v_plan),
    'investor', to_jsonb(v_investor),
    'contributions', v_contributions,
    'cycleHistory', v_history,
    'accruedInterest', v_val.accrued_interest,
    'runningBalance', v_val.running_balance,
    'currentValue', v_val.current_value
  );
end;
$$;
