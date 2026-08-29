-- ============================================================================
-- FinSphere — Amendment Batch v2.0 (v1.58)
-- Standalone additive/corrective migration. Safe to run on top of the
-- existing live database. Every statement is create-if-not-exists /
-- create-or-replace / alter-if-not-exists, so it is also safe to re-run.
--
-- Covers (see README-DEPLOY.md "v1.58 Amendment Summary" for plain-English
-- explanations of each item):
--   1. Loan Closure (replaces Full Settlement) with independent fine/
--      penalty collect-or-waive handling and full pool-credit breakdown
--   2. Bahi No -> Loan Number scheme (admin-only, editable, one-time-per-type)
--   3. Borrower Credit Rating (EMI + Overdraft, 0-10, monthly)
--   4. Overdraft cycle-end bug fix: 19th -> 20th
--   5. Sanction Date (+ agent "Application Form Collected Date")
--   6. Loan Details Excel export support data (get_loan_details_report)
-- ============================================================================


-- ============================================================================
-- SECTION 1 — Schema additions (all additive, no drops, no renames)
-- ============================================================================

-- ---- Bahi No / Loan Number rework ----
alter table loan_accounts add column if not exists bahi_no integer;
alter table loan_accounts add column if not exists sanction_date date;
-- Track which numbers have ever been issued per account_type so a Bahi No,
-- once used, is retired PERMANENTLY even after the loan is later deleted or
-- its Bahi No is edited away (per explicit "one-time-only per type" rule —
-- unlike the borrower/investor gap-filling scheme, this list never shrinks).
create table if not exists bahi_no_registry (
  account_type text not null,
  bahi_no integer not null,
  loan_account_id uuid references loan_accounts(id),
  assigned_at timestamptz not null default now(),
  primary key (account_type, bahi_no)
);

-- ---- Agent-side Application Form Collected Date ----
alter table agent_loan_requests add column if not exists application_form_collected_date date;

-- ---- Loan Closure: independent fine/penalty collect-vs-waive capture ----
-- One row per Loan Closure event, holding exactly how much of the fine and
-- of the penalty were collected vs waived, so the plain-language breakdown
-- and the audit trail always agree and can be redisplayed later.
create table if not exists loan_closure_breakdown (
  id uuid primary key default gen_random_uuid(),
  loan_account_id uuid not null references loan_accounts(id),
  loan_transaction_id uuid references loan_transactions(id),
  closure_date date not null,
  principal_outstanding numeric not null default 0,
  interest_dues numeric not null default 0,
  fine_total_due numeric not null default 0,
  fine_collected numeric not null default 0,
  fine_waived numeric not null default 0,
  penalty_total_due numeric not null default 0,
  penalty_collected numeric not null default 0,
  penalty_waived numeric not null default 0,
  final_payable numeric not null default 0,
  business_pool_id text,
  business_amount numeric not null default 0,
  profit_pool_id text,
  profit_amount numeric not null default 0,
  fine_penalty_profit_pool_id text,
  fine_penalty_profit_amount numeric not null default 0,
  created_at timestamptz not null default now()
);
alter table loan_closure_breakdown enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'loan_closure_breakdown' and policyname = 'public read/write loan_closure_breakdown') then
    create policy "public read/write loan_closure_breakdown" on loan_closure_breakdown for all using (true) with check (true);
  end if;
end $$;

-- ---- Borrower Credit Rating ----
-- One row per (loan, period) scored — a "period" is an EMI installment
-- number for EMI loans, or an Overdraft billing-cycle number for OD loans.
-- Kept separate from loan_emi_schedule / loan_od_cycles so re-scoring never
-- risks corrupting the schedule/cycle tables those other features rely on.
create table if not exists credit_rating_periods (
  id uuid primary key default gen_random_uuid(),
  loan_account_id uuid not null references loan_accounts(id),
  borrower_id text not null references borrowers(id),
  account_type text not null,          -- EMI | OVERDRAFT (Bullet excluded, per spec)
  period_no integer not null,          -- installment_no (EMI) or cycle_no (OD)
  due_date date not null,
  paid_date date,                      -- null while still pending/unpaid
  score integer not null default 0,    -- 0-10, whole number
  computed_at timestamptz not null default now(),
  unique (loan_account_id, period_no)
);
create index if not exists idx_credit_rating_periods_loan on credit_rating_periods (loan_account_id);
create index if not exists idx_credit_rating_periods_borrower on credit_rating_periods (borrower_id);
alter table credit_rating_periods enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'credit_rating_periods' and policyname = 'public read/write credit_rating_periods') then
    create policy "public read/write credit_rating_periods" on credit_rating_periods for all using (true) with check (true);
  end if;
end $$;


-- ============================================================================
-- SECTION 2 — Overdraft cycle-end bug fix (19th -> 20th)
-- ============================================================================
-- overdraft_interest_due_day() already existed, returning 20, but nothing
-- called it — next_od_cycle_end() hardcoded 19 days instead. Fixed here to
-- actually use the named constant, so there is a single source of truth.

create or replace function public.next_od_cycle_end(p_after date)
returns date language sql immutable as $$
  select case
    when (date_trunc('month', p_after) + ((overdraft_interest_due_day() - 1) || ' days')::interval)::date > p_after
      then (date_trunc('month', p_after) + ((overdraft_interest_due_day() - 1) || ' days')::interval)::date
    else (date_trunc('month', p_after) + interval '1 month' + ((overdraft_interest_due_day() - 1) || ' days')::interval)::date
  end;
$$;

-- One-time correction pass for any loan_od_cycles rows already computed
-- under the old (19th) logic. Only touches cycles that are not yet fully
-- PAID, to avoid rewriting settled history. Re-derives cycle_end from the
-- corrected function and recalculates that cycle's interest_amount to
-- match. Safe to re-run (idempotent once all eligible cycles are fixed).
do $$
declare
  r record;
  v_correct_end date;
  v_new_interest numeric;
begin
  for r in
    select * from loan_od_cycles
    where status <> 'PAID'
      and extract(day from cycle_end) = 19
  loop
    v_correct_end := (r.cycle_end + interval '1 day')::date;
    v_new_interest := calc_od_cycle_interest(r.loan_account_id,
      (select roi from loan_accounts where id = r.loan_account_id), r.cycle_start, v_correct_end);
    update loan_od_cycles set cycle_end = v_correct_end, interest_amount = v_new_interest
      where id = r.id;
  end loop;
  for r in
    select * from bank_od_cycles
    where status <> 'PAID'
      and extract(day from cycle_end) = 19
  loop
    v_correct_end := (r.cycle_end + interval '1 day')::date;
    v_new_interest := calc_bank_od_cycle_interest(r.bank_loan_account_id,
      (select roi from bank_loan_accounts where id = r.bank_loan_account_id), r.cycle_start, v_correct_end);
    update bank_od_cycles set cycle_end = v_correct_end, interest_amount = v_new_interest
      where id = r.id;
  end loop;
end $$;


-- ============================================================================
-- SECTION 3 — Bahi No -> Loan Number
-- ============================================================================

-- Admin-only, called at loan creation (direct) or at agent-request approval.
-- Enforces "one-time-only per type, permanently" via bahi_no_registry, which
-- is never cleaned up even when a loan is later deleted or its Bahi No is
-- changed — the used number stays retired.
create or replace function public.assign_bahi_no(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_loan_id uuid := (p->>'loanAccountId')::uuid;
  v_bahi_no integer := (p->>'bahiNo')::integer;
  la loan_accounts%rowtype;
  v_prefix text;
  v_new_loan_no text;
  v_old_bahi integer;
begin
  select * into la from loan_accounts where id = v_loan_id;
  if not found then return jsonb_build_object('error', 'Loan account not found'); end if;
  if v_bahi_no is null or v_bahi_no <= 0 then
    return jsonb_build_object('error', 'Enter a valid Bahi No (positive number)');
  end if;

  v_prefix := case la.account_type when 'BULLET' then 'B' when 'EMI' then 'E' else 'O' end;

  -- Reject if this (type, bahi_no) pair is already registered to a
  -- DIFFERENT loan. Registering the same bahi_no to the same loan again
  -- (i.e. re-saving unchanged) is a no-op, not an error.
  if exists (
    select 1 from bahi_no_registry
    where account_type = la.account_type and bahi_no = v_bahi_no and loan_account_id <> v_loan_id
  ) then
    return jsonb_build_object('error', format('Bahi No %s is already used for a %s loan and cannot be reused.', v_bahi_no, la.account_type));
  end if;

  v_old_bahi := la.bahi_no;
  v_new_loan_no := v_prefix || '-' || v_bahi_no;

  update loan_accounts set bahi_no = v_bahi_no, loan_no = v_new_loan_no where id = v_loan_id;

  insert into bahi_no_registry (account_type, bahi_no, loan_account_id)
    values (la.account_type, v_bahi_no, v_loan_id)
    on conflict (account_type, bahi_no) do update set loan_account_id = excluded.loan_account_id;

  perform log_audit('EDIT', 'LoanAccount', v_loan_id::text,
    jsonb_build_object('bahiNoOld', v_old_bahi, 'bahiNoNew', v_bahi_no, 'loanNoNew', v_new_loan_no));

  return jsonb_build_object('ok', true, 'loanNo', v_new_loan_no, 'bahiNo', v_bahi_no);
end;
$$;

-- Admin edit path (fix a wrongly-entered Bahi No later). Same uniqueness
-- rule as assign_bahi_no — this IS assign_bahi_no, kept as a distinctly
-- named RPC only so the frontend's "Edit Bahi No" action is self-documenting.
create or replace function public.edit_bahi_no(p jsonb)
returns jsonb language plpgsql as $$
begin
  return assign_bahi_no(p);
end;
$$;


-- ============================================================================
-- SECTION 4 — Sanction Date
-- ============================================================================

-- Wraps the existing add_loan_account(): same behavior, plus captures an
-- optional sanctionDate (defaults to disbursementDate if not supplied, so
-- older frontend calls without this field keep working unchanged).
create or replace function public.add_loan_account(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_borrower borrowers%rowtype;
  v_loan loan_accounts%rowtype;
  v_txn loan_transactions%rowtype;
  v_loan_no text;
  v_account_type text;
  v_principal numeric;
  v_roi numeric;
  v_tenure integer;
  v_emi_due_day integer;
  v_emi numeric;
  v_receipt text;
  v_sanctioned_limit numeric;
  v_maturity_date date;
  v_sanction_date date;
begin
  select * into v_borrower from borrowers where id = p->>'borrowerId';
  if not found then return jsonb_build_object('error', 'Borrower not found'); end if;

  v_account_type := upper(coalesce(p->>'accountType', ''));
  if v_account_type not in ('BULLET', 'EMI', 'OVERDRAFT') then
    return jsonb_build_object('error', 'Account type must be BULLET, EMI, or OVERDRAFT');
  end if;

  v_roi := (p->>'roi')::numeric;
  v_emi := null;
  v_tenure := null;
  v_emi_due_day := null;
  v_sanctioned_limit := null;
  v_maturity_date := null;
  v_sanction_date := coalesce((p->>'sanctionDate')::date, (p->>'disbursementDate')::date);

  if v_account_type = 'OVERDRAFT' then
    v_sanctioned_limit := (p->>'sanctionedLimit')::numeric;
    if v_sanctioned_limit is null or v_sanctioned_limit <= 0 then
      return jsonb_build_object('error', 'Sanctioned limit must be greater than zero for an Overdraft account');
    end if;
    v_principal := coalesce((p->>'principal')::numeric, 0);
    if v_principal < 0 or v_principal > v_sanctioned_limit then
      return jsonb_build_object('error', 'Initial draw cannot be negative or exceed the sanctioned limit');
    end if;
  else
    v_principal := (p->>'principal')::numeric;
    if v_principal is null or v_principal <= 0 then
      return jsonb_build_object('error', 'Principal must be greater than zero');
    end if;
  end if;

  if v_account_type = 'EMI' then
    v_tenure := (p->>'tenureMonths')::integer;
    if v_tenure is null or v_tenure <= 0 then
      return jsonb_build_object('error', 'Tenure (months) is required for an EMI loan');
    end if;
    v_emi_due_day := (p->>'emiDueDay')::integer;
    if v_emi_due_day is null or v_emi_due_day not in (10,20,30) then
      return jsonb_build_object('error', 'EMI collection date must be 10, 20, or 30');
    end if;
    v_emi := calc_emi_amount(v_principal, v_roi, v_tenure);
  end if;

  if v_account_type = 'BULLET' then
    v_maturity_date := ((p->>'disbursementDate')::date + interval '12 months')::date;
  end if;

  -- Loan number: legacy 'L-#' sequence by default. If a Bahi No is
  -- supplied directly at creation (admin flow, not agent flow), assign
  -- it immediately via the same uniqueness-checked path as assign_bahi_no.
  v_loan_no := 'L-' || next_available_number('loan_accounts', 'loan_no', 'L');

  insert into loan_accounts (loan_no, borrower_id, account_type, principal, roi,
    disbursement_date, sanction_date, tenure_months, emi_due_day, emi_amount, status,
    sanctioned_limit, maturity_date)
  values (v_loan_no, p->>'borrowerId', v_account_type, v_principal, v_roi,
    (p->>'disbursementDate')::date, v_sanction_date, v_tenure, v_emi_due_day, v_emi, 'ACTIVE',
    v_sanctioned_limit, v_maturity_date)
  returning * into v_loan;

  if p->>'bahiNo' is not null and trim(p->>'bahiNo') <> '' then
    perform assign_bahi_no(jsonb_build_object('loanAccountId', v_loan.id, 'bahiNo', (p->>'bahiNo')::integer));
    select * into v_loan from loan_accounts where id = v_loan.id;
  end if;

  if v_account_type = 'EMI' then
    perform generate_emi_schedule(v_loan.id);
  end if;

  if v_principal > 0 then
    v_receipt := next_receipt_no();
    insert into loan_transactions (loan_account_id, borrower_id, txn_date, txn_type, amount,
      balance_before, interest_added, balance_after, remarks, receipt_no, payment_mode)
    values (v_loan.id, p->>'borrowerId', (p->>'disbursementDate')::date, 'DISBURSEMENT', v_principal,
      0, 0, v_principal, coalesce(p->>'remarks',''), v_receipt, coalesce(p->>'paymentMode',''))
    returning * into v_txn;
  end if;

  perform log_audit('CREATE', 'LoanAccount', v_loan.id::text, to_jsonb(v_loan));
  return jsonb_build_object('ok', true, 'loanAccount', to_jsonb(v_loan), 'transaction', to_jsonb(v_txn));
end;
$$;

-- Agent flow: "Application Form Collected Date" -> becomes Sanction Date
-- automatically on admin approval (editable by admin at that point, via
-- the loanAccountId returned + a normal edit_loan_account-style call if
-- they choose to change it before finalizing).
create or replace function public.agent_request_loan(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_agent_id text := p->>'agentId';
  v_borrower_id text := p->>'borrowerId';
  v_account_type text := upper(coalesce(p->>'accountType', ''));
  v_principal numeric := (p->>'principal')::numeric;
  v_suggested_roi numeric := nullif(p->>'suggestedRoi','')::numeric;
  v_sanctioned_limit numeric := nullif(p->>'sanctionedLimit','')::numeric;
  v_form_date date := nullif(p->>'applicationFormCollectedDate','')::date;
  rec agent_loan_requests%rowtype;
begin
  if not exists (select 1 from agents where id = v_agent_id and status = 'ACTIVE') then
    return jsonb_build_object('error', 'Agent not found or inactive');
  end if;
  if not exists (select 1 from borrowers where id = v_borrower_id and agent_id = v_agent_id) then
    return jsonb_build_object('error', 'You can only request a loan for a borrower you added');
  end if;
  if v_account_type not in ('BULLET','EMI','OVERDRAFT') then
    return jsonb_build_object('error', 'Loan type must be Bullet, EMI, or Overdraft');
  end if;
  if v_principal is null or v_principal <= 0 then
    return jsonb_build_object('error', 'Enter an amount greater than zero');
  end if;
  if v_account_type = 'EMI' and coalesce((p->>'tenureMonths')::integer, 0) <= 0 then
    return jsonb_build_object('error', 'Tenure (months) is required for an EMI loan');
  end if;
  if v_suggested_roi is not null and (v_suggested_roi <= 0 or v_suggested_roi > 100) then
    return jsonb_build_object('error', 'Suggested ROI must be between 0 and 100');
  end if;
  if v_form_date is null then
    return jsonb_build_object('error', 'Application Form Collected Date is required');
  end if;

  insert into agent_loan_requests (agent_id, borrower_id, account_type, principal, suggested_roi,
    tenure_months, sanctioned_limit, purpose, application_form_collected_date)
  values (v_agent_id, v_borrower_id, v_account_type, v_principal, v_suggested_roi,
          nullif(p->>'tenureMonths','')::integer, v_sanctioned_limit, coalesce(p->>'purpose',''), v_form_date)
  returning * into rec;

  return jsonb_build_object('ok', true, 'request', to_jsonb(rec));
end;
$$;

-- On approval, the agent's Application Form Collected Date is copied
-- straight into the new loan's Sanction Date, and (if admin supplied one
-- in the same call) the Bahi No is assigned in the same step.
create or replace function public.mark_agent_loan_request_approved(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_request_id uuid := (p->>'requestId')::uuid;
  v_loan_id uuid := (p->>'loanAccountId')::uuid;
  v_agent_id text;
  v_form_date date;
begin
  select agent_id, application_form_collected_date into v_agent_id, v_form_date
    from agent_loan_requests where id = v_request_id;
  if v_agent_id is null then return jsonb_build_object('error', 'Request not found'); end if;

  update loan_accounts set
    agent_id = v_agent_id,
    sanction_date = coalesce(sanction_date, v_form_date)
    where id = v_loan_id;

  if p->>'bahiNo' is not null and trim(p->>'bahiNo') <> '' then
    perform assign_bahi_no(jsonb_build_object('loanAccountId', v_loan_id, 'bahiNo', (p->>'bahiNo')::integer));
  end if;

  update agent_loan_requests
    set status = 'APPROVED', decided_at = now(), resulting_loan_account_id = v_loan_id
    where id = v_request_id;

  return jsonb_build_object('ok', true);
end;
$$;

-- Extend edit_loan_account so Sanction Date, and any other core term
-- (principal, roi, tenure, emi due day for EMI, sanctioned limit for OD),
-- can be corrected after creation — this backs the new consolidated
-- "Edit Loan Details" frontend action. Whenever principal/roi/tenure
-- change on an EMI loan, its EMI schedule (and therefore every downstream
-- figure: payable, fines, credit-rating periods) is retrospectively
-- regenerated and PAID installments are re-matched by installment_no
-- where possible so payment history isn't silently lost.
create or replace function public.edit_loan_account(p jsonb)
returns jsonb language plpgsql as $$
declare
  rec loan_accounts%rowtype;
  v_profit_pool text;
  v_profit_pct numeric;
  v_clear_profit_share boolean;
  v_core_terms_changed boolean := false;
  v_old_paid_installments jsonb;
begin
  v_clear_profit_share := (p ? 'profitSharePoolId') and (nullif(p->>'profitSharePoolId','') is null);

  if p ? 'profitSharePoolId' and not v_clear_profit_share then
    v_profit_pool := p->>'profitSharePoolId';
    if not exists (select 1 from pool_accounts where id = v_profit_pool) then
      return jsonb_build_object('error', 'Profit-share pool account not found');
    end if;
    v_profit_pct := nullif(p->>'profitSharePct','')::numeric;
    if v_profit_pct is null or v_profit_pct <= 0 or v_profit_pct > 100 then
      return jsonb_build_object('error', 'Profit share percentage must be greater than 0 and up to 100');
    end if;
  end if;

  select * into rec from loan_accounts where id = (p->>'id')::uuid;
  if not found then return jsonb_build_object('error', 'Loan account not found'); end if;

  if (p ? 'principal' and (p->>'principal')::numeric <> rec.principal)
     or (p ? 'roi' and (p->>'roi')::numeric <> rec.roi)
     or (p ? 'tenureMonths' and rec.account_type = 'EMI' and (p->>'tenureMonths')::integer <> coalesce(rec.tenure_months,0)) then
    v_core_terms_changed := true;
  end if;

  if v_core_terms_changed and rec.account_type = 'EMI' then
    select coalesce(jsonb_agg(jsonb_build_object('installmentNo', installment_no, 'paidTxnId', paid_txn_id)), '[]'::jsonb)
      into v_old_paid_installments
      from loan_emi_schedule where loan_account_id = rec.id and status = 'PAID';
  end if;

  update loan_accounts set
    principal = coalesce((p->>'principal')::numeric, principal),
    roi = coalesce((p->>'roi')::numeric, roi),
    tenure_months = case when rec.account_type = 'EMI' then coalesce((p->>'tenureMonths')::integer, tenure_months) else tenure_months end,
    sanction_date = coalesce((p->>'sanctionDate')::date, sanction_date),
    sanctioned_limit = case when rec.account_type = 'OVERDRAFT' then coalesce((p->>'sanctionedLimit')::numeric, sanctioned_limit) else sanctioned_limit end,
    profit_share_pool_id = case
      when v_clear_profit_share then null
      when p ? 'profitSharePoolId' then v_profit_pool
      else profit_share_pool_id
    end,
    profit_share_pct = case
      when v_clear_profit_share then null
      when p ? 'profitSharePoolId' then v_profit_pct
      else profit_share_pct
    end
  where id = (p->>'id')::uuid
  returning * into rec;

  -- Retrospective recalculation: rebuild the EMI schedule under the new
  -- terms, then re-mark previously PAID installment numbers as PAID again
  -- (their emi_amount/interest/principal split reflect the NEW terms, but
  -- the fact that installment #N was already paid is preserved). Then
  -- refresh every other downstream figure exactly as if the loan had
  -- always had these terms: fines, overdue status, credit rating.
  if v_core_terms_changed and rec.account_type = 'EMI' then
    perform generate_emi_schedule(rec.id);
    update loan_emi_schedule s set status = 'PAID', paid_txn_id = (x->>'paidTxnId')::uuid
      from jsonb_array_elements(v_old_paid_installments) x
      where s.loan_account_id = rec.id and s.installment_no = (x->>'installmentNo')::integer;
    perform refresh_emi_fines(rec.id, current_date);
  end if;

  perform recalculate_loan_account(rec.id);
  perform refresh_overdue_status();
  perform recompute_credit_rating_for_loan(rec.id);

  perform log_audit('EDIT', 'LoanAccount', p->>'id', p || jsonb_build_object('coreTermsChanged', v_core_terms_changed));
  return jsonb_build_object('ok', true, 'loanAccount', to_jsonb(rec), 'coreTermsChanged', v_core_terms_changed);
end;
$$;


-- ============================================================================
-- SECTION 5 — Borrower Credit Rating (EMI + Overdraft, 0-10, whole numbers)
-- ============================================================================
-- Scoring rule (per period, per loan):
--   paid on/before due date          -> 10
--   paid late, N days after due date -> greatest(10 - N, 0)
--   not yet paid (pending/overdue)   -> 0
-- Loan-level rating  = round(avg(all period scores for that loan))
-- Borrower-level rating = round(avg(all period scores across every one
--   of that borrower's EMI + Overdraft loans)) -- Bullet excluded.

create or replace function public.recompute_credit_rating_for_loan(p_loan_account_id uuid)
returns void language plpgsql as $$
declare
  la loan_accounts%rowtype;
  sched loan_emi_schedule%rowtype;
  cyc loan_od_cycles%rowtype;
  v_days_late integer;
  v_score integer;
  v_paid_date date;
begin
  select * into la from loan_accounts where id = p_loan_account_id;
  if not found then return; end if;
  if la.account_type not in ('EMI','OVERDRAFT') then return; end if;

  delete from credit_rating_periods where loan_account_id = p_loan_account_id;

  if la.account_type = 'EMI' then
    for sched in select * from loan_emi_schedule where loan_account_id = p_loan_account_id order by installment_no asc loop
      if sched.status = 'PAID' and sched.paid_txn_id is not null then
        select txn_date into v_paid_date from loan_transactions where id = sched.paid_txn_id;
        v_days_late := greatest(days_between(sched.due_date, coalesce(v_paid_date, sched.due_date)), 0);
        v_score := greatest(10 - v_days_late, 0);
      else
        v_score := 0; -- not yet paid, pending or overdue
      end if;
      insert into credit_rating_periods (loan_account_id, borrower_id, account_type, period_no, due_date, paid_date, score)
      values (p_loan_account_id, la.borrower_id, 'EMI', sched.installment_no, sched.due_date, v_paid_date, v_score);
    end loop;
  else -- OVERDRAFT
    perform refresh_od_interest_cycles(p_loan_account_id, current_date);
    for cyc in select * from loan_od_cycles where loan_account_id = p_loan_account_id order by cycle_no asc loop
      if cyc.status = 'PAID' and cyc.paid_txn_id is not null then
        select txn_date into v_paid_date from loan_transactions where id = cyc.paid_txn_id;
        v_days_late := greatest(days_between(cyc.cycle_end, coalesce(v_paid_date, cyc.cycle_end)), 0);
        v_score := greatest(10 - v_days_late, 0);
      else
        v_score := 0;
      end if;
      insert into credit_rating_periods (loan_account_id, borrower_id, account_type, period_no, due_date, paid_date, score)
      values (p_loan_account_id, la.borrower_id, 'OVERDRAFT', cyc.cycle_no, cyc.cycle_end, v_paid_date, v_score);
    end loop;
  end if;
end;
$$;

-- Recomputes every EMI/Overdraft loan's rating periods. Call this from
-- get_all_data() (already wired below) so ratings stay live without a
-- separate scheduled job.
create or replace function public.recompute_all_credit_ratings()
returns void language plpgsql as $$
declare r record;
begin
  for r in select id from loan_accounts where account_type in ('EMI','OVERDRAFT') and status <> 'CLOSED' loop
    perform recompute_credit_rating_for_loan(r.id);
  end loop;
end;
$$;

-- Loan-level rating + full month-wise breakdown, for the popup modal.
create or replace function public.get_loan_credit_rating(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_loan_id uuid := (p->>'loanAccountId')::uuid;
  v_periods jsonb;
  v_avg numeric;
begin
  perform recompute_credit_rating_for_loan(v_loan_id);
  select coalesce(jsonb_agg(to_jsonb(cp) order by cp.period_no), '[]'::jsonb), avg(cp.score)
    into v_periods, v_avg
    from credit_rating_periods cp where cp.loan_account_id = v_loan_id;
  return jsonb_build_object('ok', true, 'periods', v_periods, 'rating', round(coalesce(v_avg,0)));
end;
$$;

-- Borrower-level rating: average across every EMI+OD period on every
-- non-Bullet loan that borrower has ever had (matches "average of all
-- loans" as confirmed).
create or replace function public.get_borrower_credit_rating(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_borrower_id text := p->>'borrowerId';
  v_avg numeric;
  v_loan_count integer;
begin
  select avg(score), count(distinct loan_account_id) into v_avg, v_loan_count
    from credit_rating_periods where borrower_id = v_borrower_id;
  if v_avg is null then
    return jsonb_build_object('ok', true, 'rating', null, 'hasData', false);
  end if;
  return jsonb_build_object('ok', true, 'rating', round(v_avg), 'hasData', true, 'loanCount', v_loan_count);
end;
$$;


-- ============================================================================
-- SECTION 6 — Loan Closure (replaces Full Settlement semantics)
-- ============================================================================
-- Adds independent fine/penalty collect-vs-waive capture. Admin TYPES the
-- collected amount for each; waived is ALWAYS auto-derived server-side as
-- (total_due - collected) -- the frontend must never send a typed "waived"
-- value, only "fineCollected" / "penaltyCollected"; this function computes
-- and stores the corresponding waived amounts itself, so there is no path
-- for the two figures to disagree.
--
-- Whatever is actually collected (fine + penalty combined) is credited
-- 100% to Rajendra's profit pool, same as the existing pay_emi_fine /
-- full_settlement penalty logic -- this migration does not change WHERE
-- fine/penalty money goes, only that partial collection is now possible
-- and every rupee's destination is recorded explicitly in
-- loan_closure_breakdown for the plain-language popup to read back.
create or replace function public.close_loan(p jsonb)
returns jsonb language plpgsql as $$
declare
  la loan_accounts%rowtype;
  pos jsonb;
  v_principal numeric;
  v_dues numeric;
  v_fine_due numeric;
  v_penalty_due numeric;
  v_fine_collected numeric;
  v_fine_waived numeric;
  v_penalty_collected numeric;
  v_penalty_waived numeric;
  v_final_payable numeric;
  v_txn loan_transactions%rowtype;
  v_receipt text;
  v_settle_date date;
  v_profit_interest_base numeric;
  v_business_amount numeric;
  v_alloc_result jsonb;
  v_final_status text;
  v_breakdown_id uuid := gen_random_uuid();
  v_business_pool_id text;
  v_profit_pool_id text;
  v_profit_amount numeric := 0;
begin
  select * into la from loan_accounts where id = (p->>'loanAccountId')::uuid;
  if not found then return jsonb_build_object('error', 'Loan account not found'); end if;
  if la.status = 'CLOSED' then
    return jsonb_build_object('ok', true, 'skipped', 'Loan is already closed', 'closureDate', la.closure_date);
  end if;

  v_settle_date := coalesce((p->>'date')::date, current_date);

  if la.account_type = 'BULLET' and la.capitalized_at is null and v_settle_date >= la.maturity_date then
    perform capitalize_bullet_interest(la.id, v_settle_date);
    select * into la from loan_accounts where id = la.id;
  end if;

  pos := calculate_loan_position(jsonb_build_object('loanAccountId', la.id, 'asOf', v_settle_date));
  if pos ? 'error' then return pos; end if;

  v_principal := coalesce((pos->>'principalOutstanding')::numeric, 0);
  v_dues := coalesce((pos->>'interestPosition')::numeric, 0);
  v_fine_due := coalesce((pos->>'lateFine')::numeric, 0);
  v_penalty_due := coalesce((pos->>'preClosurePenalty')::numeric, 0);

  -- Admin types collected amounts; waived is ALWAYS server-derived.
  v_fine_collected := least(greatest(coalesce((p->>'fineCollected')::numeric, v_fine_due), 0), v_fine_due);
  v_fine_waived := round(v_fine_due - v_fine_collected, 2);
  v_penalty_collected := least(greatest(coalesce((p->>'penaltyCollected')::numeric, v_penalty_due), 0), v_penalty_due);
  v_penalty_waived := round(v_penalty_due - v_penalty_collected, 2);

  -- Final payable now includes only what is actually being collected for
  -- fine/penalty (not the full due amount) -- this is the fix for the
  -- reported mismatch, since the pool allocation and the displayed total
  -- now always describe the same real cash movement.
  v_final_payable := round(v_principal + v_dues + v_fine_collected + v_penalty_collected, 2);

  v_receipt := next_receipt_no();
  insert into loan_transactions (loan_account_id, borrower_id, txn_date, txn_type, amount,
    balance_before, interest_added, balance_after, remarks, receipt_no, payment_mode)
  values (la.id, la.borrower_id, v_settle_date, 'FULL_SETTLEMENT', v_final_payable,
    v_principal, v_dues, 0,
    format('Loan Closure: principal %s + dues %s + fine collected %s + penalty collected %s = %s',
      v_principal, v_dues, v_fine_collected, v_penalty_collected, v_final_payable),
    v_receipt, coalesce(p->>'paymentMode',''))
  returning * into v_txn;

  if la.account_type = 'EMI' then
    select coalesce(sum(interest_component), 0) into v_profit_interest_base
      from loan_emi_schedule where loan_account_id = la.id and status in ('PENDING', 'OVERDUE');
    update loan_emi_schedule set status = 'PAID', paid_txn_id = v_txn.id
      where loan_account_id = la.id and status in ('PENDING', 'OVERDUE');
    -- Fine handling: mark fine instances resolved to the extent collected/waived.
    if v_fine_due > 0 then
      if v_fine_collected > 0 then
        perform pay_emi_fine(jsonb_build_object('loanAccountId', la.id, 'date', v_settle_date, 'amount', v_fine_collected, 'remarks', 'Collected at Loan Closure'));
      end if;
      if v_fine_waived > 0 then
        perform waive_emi_fine(jsonb_build_object('loanAccountId', la.id, 'date', v_settle_date, 'amount', v_fine_waived, 'waivedBy', coalesce(p->>'waivedBy','ADMIN')));
      end if;
    end if;
  else
    v_profit_interest_base := v_dues;
  end if;

  if la.account_type = 'OVERDRAFT' then
    update loan_od_cycles set status = 'PAID', interest_paid = interest_amount, paid_txn_id = v_txn.id
      where loan_account_id = la.id and status <> 'PAID';
  end if;

  v_final_status := 'CLOSED';
  update loan_accounts set status = v_final_status, closure_date = v_settle_date where id = la.id;

  v_business_amount := (v_final_payable - v_profit_interest_base - v_fine_collected - v_penalty_collected)
    + apply_profit_share(la.id, least(v_profit_interest_base, v_final_payable), v_txn.id, v_settle_date);

  -- Penalty collected: 100% to Rajendra's profit pool (same treatment as
  -- the original full_settlement()). Fine collected is credited by
  -- pay_emi_fine() itself, called above -- crediting it again here would
  -- double-count it, so only the penalty portion is credited in this block.
  if v_penalty_collected > 0 then
    update pool_accounts set profit_balance = profit_balance + v_penalty_collected where id = 'POOL-RAJENDRA';
    insert into pool_allocations (source_type, source_id, pool_id, direction, amount, txn_date, remarks)
    values ('LOAN_PENALTY_PROFIT', v_txn.id, 'POOL-RAJENDRA', 'IN', v_penalty_collected, v_settle_date,
      'Pre-closure penalty collected at closure — ' || la.loan_no);
  end if;
  if (v_fine_collected + v_penalty_collected) > 0 then
    v_profit_pool_id := 'POOL-RAJENDRA';
  end if;

  if p ? 'poolAllocations' and v_business_amount > 0.005 then
    v_alloc_result := apply_pool_allocation('LOAN_REPAYMENT', v_txn.id, p->'poolAllocations', 'IN', v_business_amount, v_settle_date, 'Loan Closure - ' || la.loan_no);
    if v_alloc_result ? 'error' then return v_alloc_result; end if;
    v_business_pool_id := (p->'poolAllocations'->0->>'poolId');
  end if;

  perform recompute_credit_rating_for_loan(la.id);

  insert into loan_closure_breakdown (
    id, loan_account_id, loan_transaction_id, closure_date,
    principal_outstanding, interest_dues,
    fine_total_due, fine_collected, fine_waived,
    penalty_total_due, penalty_collected, penalty_waived,
    final_payable, business_pool_id, business_amount,
    profit_pool_id, profit_amount, fine_penalty_profit_pool_id, fine_penalty_profit_amount
  ) values (
    v_breakdown_id, la.id, v_txn.id, v_settle_date,
    v_principal, v_dues,
    v_fine_due, v_fine_collected, v_fine_waived,
    v_penalty_due, v_penalty_collected, v_penalty_waived,
    v_final_payable, v_business_pool_id, v_business_amount,
    'POOL-RAJENDRA', least(v_profit_interest_base, v_final_payable),
    'POOL-RAJENDRA', v_fine_collected + v_penalty_collected
  );

  perform log_audit('FULL_SETTLEMENT', 'LoanAccount', la.id::text, jsonb_build_object(
    'principal', v_principal, 'dues', v_dues,
    'fineCollected', v_fine_collected, 'fineWaived', v_fine_waived,
    'penaltyCollected', v_penalty_collected, 'penaltyWaived', v_penalty_waived,
    'finalPayable', v_final_payable, 'closureDate', v_settle_date
  ));

  return jsonb_build_object('ok', true, 'transaction', to_jsonb(v_txn), 'businessAmount', v_business_amount,
    'finalStatus', v_final_status, 'breakdownId', v_breakdown_id,
    'breakdown', jsonb_build_object(
      'principalOutstanding', v_principal, 'interestOrDues', v_dues,
      'fineTotalDue', v_fine_due, 'fineCollected', v_fine_collected, 'fineWaived', v_fine_waived,
      'penaltyTotalDue', v_penalty_due, 'penaltyCollected', v_penalty_collected, 'penaltyWaived', v_penalty_waived,
      'finalPayable', v_final_payable,
      'businessPoolId', v_business_pool_id, 'businessAmount', v_business_amount,
      'profitPoolId', 'POOL-RAJENDRA', 'finePenaltyProfitAmount', v_fine_collected + v_penalty_collected
    ));
end;
$$;

-- Read-only helper the frontend calls BEFORE showing the Loan Closure
-- modal, so it can render the plain-language preview (principal/dues/
-- fine/penalty due amounts) without side effects.
create or replace function public.get_loan_closure_preview(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_loan_id uuid := (p->>'loanAccountId')::uuid;
  v_as_of date := coalesce((p->>'asOf')::date, current_date);
  pos jsonb;
begin
  pos := calculate_loan_position(jsonb_build_object('loanAccountId', v_loan_id, 'asOf', v_as_of));
  return pos;
end;
$$;


-- ============================================================================
-- SECTION 7 — Loan Details Excel Report support data
-- ============================================================================
-- Returns one row per loan with every field the "Loan Details" export
-- needs (frontend builds the actual .xlsx/.xls file client-side via
-- SheetJS, using this as the data source). EMI amounts fill "emi1".."emi10"
-- for EMI loans; for Overdraft, the same 10 slots are reused for that
-- loan's first 10 billing-cycle interest amounts (provisional, per spec);
-- Bullet loans leave all 10 slots null.
create or replace function public.get_loan_details_report(p jsonb DEFAULT '{}'::jsonb)
returns jsonb language plpgsql as $$
begin
  return coalesce((
    select jsonb_agg(row_to_json(x))
    from (
      select
        bo.id as "borrowerNo",
        bo.name as "borrowerName",
        bo.father_name as "fatherHusbandName",
        bo.address as "address",
        la.bahi_no as "bahiNo",
        la.principal as "principal",
        la.roi as "roi",
        la.sanction_date as "sanctionDate",
        la.disbursement_date as "disbDate",
        (select emi_amount from loan_emi_schedule s where s.loan_account_id = la.id and s.installment_no = 1) as "emi1",
        (select emi_amount from loan_emi_schedule s where s.loan_account_id = la.id and s.installment_no = 2) as "emi2",
        (select emi_amount from loan_emi_schedule s where s.loan_account_id = la.id and s.installment_no = 3) as "emi3",
        (select emi_amount from loan_emi_schedule s where s.loan_account_id = la.id and s.installment_no = 4) as "emi4",
        (select emi_amount from loan_emi_schedule s where s.loan_account_id = la.id and s.installment_no = 5) as "emi5",
        (select emi_amount from loan_emi_schedule s where s.loan_account_id = la.id and s.installment_no = 6) as "emi6",
        (select emi_amount from loan_emi_schedule s where s.loan_account_id = la.id and s.installment_no = 7) as "emi7",
        (select emi_amount from loan_emi_schedule s where s.loan_account_id = la.id and s.installment_no = 8) as "emi8",
        (select emi_amount from loan_emi_schedule s where s.loan_account_id = la.id and s.installment_no = 9) as "emi9",
        (select emi_amount from loan_emi_schedule s where s.loan_account_id = la.id and s.installment_no = 10) as "emi10",
        (select interest_amount from loan_od_cycles c where c.loan_account_id = la.id and c.cycle_no = 1) as "od1",
        (select interest_amount from loan_od_cycles c where c.loan_account_id = la.id and c.cycle_no = 2) as "od2",
        (select interest_amount from loan_od_cycles c where c.loan_account_id = la.id and c.cycle_no = 3) as "od3",
        (select interest_amount from loan_od_cycles c where c.loan_account_id = la.id and c.cycle_no = 4) as "od4",
        (select interest_amount from loan_od_cycles c where c.loan_account_id = la.id and c.cycle_no = 5) as "od5",
        (select interest_amount from loan_od_cycles c where c.loan_account_id = la.id and c.cycle_no = 6) as "od6",
        (select interest_amount from loan_od_cycles c where c.loan_account_id = la.id and c.cycle_no = 7) as "od7",
        (select interest_amount from loan_od_cycles c where c.loan_account_id = la.id and c.cycle_no = 8) as "od8",
        (select interest_amount from loan_od_cycles c where c.loan_account_id = la.id and c.cycle_no = 9) as "od9",
        (select interest_amount from loan_od_cycles c where c.loan_account_id = la.id and c.cycle_no = 10) as "od10",
        la.account_type as "accountType",
        coalesce(pp.name, '') as "profitPerson",
        la.profit_share_pct as "profitPct",
        (calculate_loan_position(jsonb_build_object('loanAccountId', la.id))->>'currentPayable')::numeric as "totalAmount",
        la.status as "loanStatus",
        coalesce((calculate_loan_position(jsonb_build_object('loanAccountId', la.id))->>'lateFine')::numeric, 0)
          + coalesce((calculate_loan_position(jsonb_build_object('loanAccountId', la.id))->>'preClosurePenalty')::numeric, 0) as "penaltyFineDue"
      from loan_accounts la
      join borrowers bo on bo.id = la.borrower_id
      left join pool_accounts pp on pp.id = la.profit_share_pool_id
      order by la.loan_no
    ) x
  ), '[]'::jsonb);
end;
$$;


-- ============================================================================
-- SECTION 8 — get_all_data(): surface new fields to the frontend
-- ============================================================================
-- Adds bahiNo, sanctionDate, and a live creditRating figure onto each loan
-- account object, and a borrowerCreditRating map keyed by borrower id, so
-- the frontend can show these without extra round trips on every screen.
create or replace function public.get_all_data()
returns jsonb language plpgsql as $$
declare
  v_investors jsonb;
  v_borrowers jsonb;
  v_accounts jsonb;
  v_transactions jsonb;
  v_loan_accounts jsonb;
  v_loan_transactions jsonb;
  v_as_on timestamptz := now();
  v_borrower_ratings jsonb;
begin
  perform refresh_overdue_status();
  perform refresh_bullet_capitalization();
  perform recompute_all_credit_ratings();

  select coalesce(jsonb_agg(to_jsonb(i)), '[]'::jsonb) into v_investors from investors i;
  select coalesce(jsonb_agg(to_jsonb(b)), '[]'::jsonb) into v_borrowers from borrowers b;
  select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) into v_transactions from transactions t;
  select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) into v_loan_transactions from loan_transactions t;

  select coalesce(jsonb_agg(
    to_jsonb(a) || jsonb_build_object(
      'runningBalance', v.running_balance, 'lastEventDate', v.last_event_date,
      'daysSinceLastEvent', v.days_since_last_event, 'accruedInterest', v.accrued_interest,
      'currentValue', v.current_value
    )
  ), '[]'::jsonb) into v_accounts
  from accounts a cross join lateral compute_account_value(a.id, current_date) v;

  select coalesce(jsonb_agg(
    to_jsonb(la) || jsonb_build_object(
      'runningBalance', v.running_balance, 'lastEventDate', v.last_event_date,
      'daysSinceLastEvent', v.days_since_last_event, 'accruedInterest', v.accrued_interest,
      'currentValue', v.current_value,
      'emiSchedule', coalesce((select jsonb_agg(to_jsonb(s) order by s.installment_no) from loan_emi_schedule s where s.loan_account_id = la.id), '[]'::jsonb),
      'creditRating', (select round(avg(score)) from credit_rating_periods cp where cp.loan_account_id = la.id)
    )
  ), '[]'::jsonb) into v_loan_accounts
  from loan_accounts la cross join lateral compute_loan_value(la.id, current_date) v;

  select coalesce(jsonb_object_agg(borrower_id, rating), '{}'::jsonb) into v_borrower_ratings
  from (
    select borrower_id, round(avg(score)) as rating
    from credit_rating_periods group by borrower_id
  ) x;

  return jsonb_build_object(
    'ok', true, 'asOnDate', v_as_on,
    'investors', v_investors, 'accounts', v_accounts, 'transactions', v_transactions,
    'borrowers', v_borrowers, 'loanAccounts', v_loan_accounts, 'loanTransactions', v_loan_transactions,
    'borrowerCreditRatings', v_borrower_ratings
  );
end;
$$;

-- ============================================================================
-- End of v1.58 amendment batch.
-- ============================================================================
