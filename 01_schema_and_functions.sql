-- ============================================================================
-- FinSphere — Supabase schema + business logic
-- Ported from AppsScript.gs.txt (Google Sheets backend) to Postgres.
-- Run this entire file once in the Supabase SQL Editor on a fresh project.
-- ============================================================================

-- ---------- Migrating an EXISTING database (V28 → V29) ----------
-- If you already ran this file before, do NOT re-run the whole thing —
-- "create table" will fail because the tables already exist. Instead, run
-- just this block once in the Supabase SQL Editor to add the new optional
-- email columns, then re-run the "add_investor" / "edit_investor" /
-- "add_borrower" / "edit_borrower" function definitions further down
-- (safe to re-run — they use "create or replace function").
--
--   alter table investors add column if not exists email text default '';
--   alter table borrowers add column if not exists email text default '';
--
-- A brand-new project can skip this block and just run the file top to
-- bottom as before — the columns below already include it.

-- ---------- Tables ----------

create table investors (
  id text primary key,                -- e.g. 'INVST01'
  name text not null,
  father_name text default '',
  address text default '',
  mobile text,
  email text default '',
  photo text default '',
  remarks text default '',
  status text not null default 'ACTIVE',
  created_at timestamptz not null default now()
);

create table accounts (
  id uuid primary key default gen_random_uuid(),
  account_no text not null,           -- e.g. 'INVST01-001'
  investor_id text not null references investors(id),
  opening_date date not null,
  opening_amount numeric not null,
  roi numeric not null,               -- annual interest rate, percent
  status text not null default 'ACTIVE',
  created_at timestamptz not null default now()
);

create table transactions (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references accounts(id),
  investor_id text not null references investors(id),
  txn_date date not null,
  txn_type text not null,             -- INVESTMENT | TOPUP | WITHDRAWAL | FULL_SETTLEMENT
  amount numeric not null,
  balance_before numeric not null default 0,
  interest_added numeric not null default 0,
  balance_after numeric not null default 0,
  remarks text default '',
  receipt_no text default '',
  payment_mode text default '',
  cheque_no text default '',
  cheque_date date,
  drawn_on_bank text default '',
  txn_ref_no text default '',
  narration text default '',
  credit_account_no text default '',
  credit_account_name text default '',
  created_at timestamptz not null default now()
);

create table borrowers (
  id text primary key,                -- e.g. 'BRW01'
  name text not null,
  father_name text default '',
  address text default '',
  mobile text,
  email text default '',
  photo text default '',
  remarks text default '',
  loan_amount numeric not null default 0,   -- legacy single-figure field, kept for old data; superseded by loan_accounts
  loan_date date default current_date,      -- legacy, see above
  "references" jsonb not null default '[]'::jsonb,   -- array of guarantor profiles
  status text not null default 'ACTIVE',
  created_at timestamptz not null default now()
);

-- ---------- Loan Module ----------
-- Mirrors the investor accounts/transactions pattern, but for money the
-- business has LENT OUT to a borrower rather than money invested with it.
-- A borrower can have several loan_accounts open at once, each independently
-- BULLET (interest accrues daily on outstanding principal, repay any time,
-- partial or full — same math as the investor side) or EMI (fixed tenure,
-- reducing-balance amortization, equal monthly installment computed from
-- principal/roi/tenure).
create table loan_accounts (
  id uuid primary key default gen_random_uuid(),
  loan_no text not null,                -- e.g. 'L-1'
  borrower_id text not null references borrowers(id),
  account_type text not null,           -- BULLET | EMI | OVERDRAFT
  principal numeric not null,           -- for OVERDRAFT this is the initial draw, not the limit
  roi numeric not null,                 -- annual interest rate, percent
  disbursement_date date not null,
  tenure_months integer,                -- EMI only
  emi_amount numeric,                   -- EMI only, computed at creation
  status text not null default 'ACTIVE', -- ACTIVE | CLOSED | OVERDUE
  sanctioned_limit numeric,             -- OVERDRAFT only: the credit ceiling that draws cannot exceed
  maturity_date date,                   -- BULLET: disbursement + 12 months, set at creation
  capitalized_at timestamptz,           -- BULLET: when unpaid interest was capitalized into principal at maturity (once only, null until it happens)
  capitalization_pre_amount numeric,    -- BULLET: principal just before capitalization
  capitalization_post_amount numeric,   -- BULLET: principal just after capitalization (pre + accumulated interest)
  closure_date date,                    -- set when the loan is fully settled/closed
  fine_waived_amount numeric,           -- EMI: late-fine amount waived at settlement, if any (never overwrites/deletes the original fine — see loan_transactions.txn_type = 'FULL_SETTLEMENT' breakdown)
  fine_waived_by text,                  -- ADMIN who authorized the waiver
  fine_waived_at timestamptz,
  created_at timestamptz not null default now()
);

create table loan_transactions (
  id uuid primary key default gen_random_uuid(),
  loan_account_id uuid not null references loan_accounts(id),
  borrower_id text not null references borrowers(id),
  txn_date date not null,
  txn_type text not null,             -- DISBURSEMENT | DRAW | REPAYMENT | FULL_SETTLEMENT | INTEREST_CAPITALIZATION
  amount numeric not null,
  balance_before numeric not null default 0,
  interest_added numeric not null default 0,
  balance_after numeric not null default 0,
  remarks text default '',
  receipt_no text default '',
  payment_mode text default '',
  created_at timestamptz not null default now()
);

-- One row per scheduled installment for an EMI loan account, generated once
-- at loan creation so the schedule can be shown/printed immediately and each
-- installment can later be marked paid against an actual loan_transactions
-- repayment. Not used for BULLET accounts.
create table loan_emi_schedule (
  id uuid primary key default gen_random_uuid(),
  loan_account_id uuid not null references loan_accounts(id),
  installment_no integer not null,
  due_date date not null,             -- informational only; EMI due dates are flexible per Prashant, not enforced
  emi_amount numeric not null,
  principal_component numeric not null,
  interest_component numeric not null,
  closing_balance numeric not null,
  status text not null default 'PENDING',  -- PENDING | PAID | OVERDUE
  paid_txn_id uuid references loan_transactions(id),
  created_at timestamptz not null default now()
);


create table audit_log (
  id uuid primary key default gen_random_uuid(),
  action text not null,
  entity text not null,
  entity_id text not null,
  details jsonb,
  created_at timestamptz not null default now()
);

create table counters (
  name text primary key,
  value integer not null default 0
);
insert into counters (name, value) values ('investor', 0), ('borrower', 0), ('receipt', 0);

create index on accounts (investor_id);
create index on transactions (account_id);
create index on transactions (investor_id);

-- ---------- Row Level Security ----------
-- Simple model matching the current app: anyone holding the anon public key
-- (i.e. anyone with the app link) can read and write. Security here comes
-- from not sharing the link/keys publicly, same as an Apps Script "Anyone
-- with the link" deployment today — not from per-user auth.

alter table investors enable row level security;
alter table accounts enable row level security;
alter table transactions enable row level security;
alter table borrowers enable row level security;
alter table audit_log enable row level security;
alter table counters enable row level security;

create policy "public read/write investors" on investors for all using (true) with check (true);
create policy "public read/write accounts" on accounts for all using (true) with check (true);
create policy "public read/write transactions" on transactions for all using (true) with check (true);
create policy "public read/write borrowers" on borrowers for all using (true) with check (true);
create policy "public read/write audit_log" on audit_log for all using (true) with check (true);
create policy "public read/write counters" on counters for all using (true) with check (true);

-- ============================================================================
-- Business logic — ported 1:1 from the Apps Script interest engine
-- ============================================================================

-- days = whole days between startDate (exclusive) and endDate (inclusive)
create or replace function days_between(start_date date, end_date date)
returns integer language sql immutable as $$
  select greatest((end_date - start_date)::integer, 0);
$$;

create or replace function calc_interest(balance numeric, roi_percent numeric, days integer)
returns numeric language sql immutable as $$
  select (balance * roi_percent * days) / 36500.0;
$$;

-- Next sequence number from the counters table (atomic under concurrent calls)
create or replace function next_counter(counter_name text)
returns integer language plpgsql as $$
declare
  next_val integer;
begin
  update counters set value = value + 1 where name = counter_name
  returning value into next_val;
  if next_val is null then
    insert into counters (name, value) values (counter_name, 1);
    next_val := 1;
  end if;
  return next_val;
end;
$$;

-- Finds the lowest positive integer NOT currently in use as a numeric
-- suffix on the given prefix within the given table/column — i.e. true
-- gap-filling ID allocation, not a strictly-incrementing counter. Per
-- Prashant's explicit numbering rule: when B-2 is deleted, the next new
-- borrower becomes B-2 again (any deleted number is immediately reusable,
-- regardless of whether it ever had activity), not B-4. Used for borrowers
-- (B-#), investors (I-#), and loan accounts (L-#).
--
-- Deliberately a simple "try 1, 2, 3... until free" loop rather than a
-- clever set-based query — record counts here are small (a lending
-- business's borrower/investor/loan lists), so a straightforward loop that
-- is obviously correct beats a fast query that's hard to verify.
-- p_table/p_column are trusted internal literals only (never
-- user-supplied), passed from the three ID-generating functions below.
create or replace function next_available_number(p_table text, p_column text, p_prefix text)
returns integer language plpgsql as $$
declare
  candidate integer := 1;
  exists_already boolean;
begin
  loop
    execute format('select exists(select 1 from %I where %I = %L)', p_table, p_column, p_prefix || '-' || candidate)
      into exists_already;
    exit when not exists_already;
    candidate := candidate + 1;
  end loop;
  return candidate;
end;
$$;

create or replace function log_audit(p_action text, p_entity text, p_entity_id text, p_details jsonb)
returns void language sql as $$
  insert into audit_log (id, action, entity, entity_id, details)
  values (gen_random_uuid(), p_action, p_entity, p_entity_id, p_details);
$$;

-- Computes current running balance and accrued interest as of a date,
-- using the account's LAST transaction regardless of date (live dashboard
-- view — mirrors computeAccountValue in the Apps Script).
create or replace function compute_account_value(p_account_id uuid, p_as_on date default current_date)
returns table(running_balance numeric, last_event_date date, days_since_last_event integer,
              accrued_interest numeric, current_value numeric)
language plpgsql as $$
declare
  acc accounts%rowtype;
  last_txn transactions%rowtype;
  v_balance numeric := 0;
  v_last_date date;
  v_days integer;
  v_interest numeric;
begin
  select * into acc from accounts where id = p_account_id;
  if not found then
    raise exception 'Account not found';
  end if;

  select * into last_txn from transactions
    where account_id = p_account_id
    order by txn_date desc, created_at desc
    limit 1;

  if found then
    v_balance := last_txn.balance_after;
    v_last_date := last_txn.txn_date;
  else
    v_balance := 0;
    v_last_date := acc.opening_date;
  end if;

  v_days := days_between(v_last_date, p_as_on);
  v_interest := calc_interest(v_balance, acc.roi, v_days);

  return query select v_balance, v_last_date, v_days, v_interest, (v_balance + v_interest);
end;
$$;

-- ---------- Investor operations ----------

create or replace function add_investor(p jsonb)
returns jsonb language plpgsql as $$
declare
  seq integer;
  new_id text;
  rec investors%rowtype;
begin
  seq := next_available_number('investors', 'id', 'I');
  new_id := 'I-' || seq;

  insert into investors (id, name, father_name, address, mobile, email, photo, remarks, status)
  values (new_id, p->>'name', coalesce(p->>'fatherName',''), coalesce(p->>'address',''),
          p->>'mobile', coalesce(p->>'email',''), coalesce(p->>'photo',''), coalesce(p->>'remarks',''), 'ACTIVE')
  returning * into rec;

  perform log_audit('CREATE', 'Investor', new_id, to_jsonb(rec));
  return jsonb_build_object('ok', true, 'investor', to_jsonb(rec));
end;
$$;

create or replace function edit_investor(p jsonb)
returns jsonb language plpgsql as $$
declare
  rec investors%rowtype;
begin
  update investors set
    name = coalesce(p->>'name', name),
    father_name = coalesce(p->>'fatherName', father_name),
    address = coalesce(p->>'address', address),
    mobile = coalesce(p->>'mobile', mobile),
    email = coalesce(p->>'email', email),
    photo = coalesce(p->>'photo', photo),
    remarks = coalesce(p->>'remarks', remarks)
  where id = p->>'id'
  returning * into rec;

  if not found then return jsonb_build_object('error', 'Investor not found'); end if;
  perform log_audit('EDIT', 'Investor', p->>'id', p);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function set_investor_status(p jsonb)
returns jsonb language plpgsql as $$
begin
  update investors set status = p->>'status' where id = p->>'id';
  if not found then return jsonb_build_object('error', 'Investor not found'); end if;
  perform log_audit('STATUS_CHANGE', 'Investor', p->>'id', p);
  return jsonb_build_object('ok', true);
end;
$$;

-- Always allowed, matching current behaviour: deletes the investor master
-- record only. Accounts/transactions remain as orphaned historical rows.
create or replace function delete_investor(p jsonb)
returns jsonb language plpgsql as $$
declare
  deleted investors%rowtype;
begin
  -- Cascade-delete everything under this investor first. This matters more
  -- than it did before: investor IDs (I-1, I-2...) are now reusable once
  -- freed, so a deleted investor's accounts/transactions must be fully
  -- gone, not just orphaned, or a brand-new investor later given the same
  -- ID would appear to inherit someone else's financial history.
  delete from transactions where investor_id = p->>'id';
  delete from accounts where investor_id = p->>'id';
  delete from investors where id = p->>'id' returning * into deleted;
  if not found then return jsonb_build_object('error', 'Investor not found'); end if;
  perform log_audit('DELETE', 'Investor', p->>'id', to_jsonb(deleted));
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------- Borrower operations ----------

create or replace function add_borrower(p jsonb)
returns jsonb language plpgsql as $$
declare
  seq integer;
  new_id text;
  rec borrowers%rowtype;
begin
  seq := next_available_number('borrowers', 'id', 'B');
  new_id := 'B-' || seq;

  insert into borrowers (id, name, father_name, address, mobile, email, photo, remarks, loan_amount, loan_date, "references", status)
  values (new_id, p->>'name', coalesce(p->>'fatherName',''), coalesce(p->>'address',''),
          p->>'mobile', coalesce(p->>'email',''), coalesce(p->>'photo',''), coalesce(p->>'remarks',''),
          coalesce((p->>'loanAmount')::numeric, 0), coalesce((p->>'loanDate')::date, current_date),
          coalesce(p->'references', '[]'::jsonb), 'ACTIVE')
  returning * into rec;

  perform log_audit('CREATE', 'Borrower', new_id, to_jsonb(rec));
  return jsonb_build_object('ok', true, 'borrower', to_jsonb(rec));
end;
$$;

create or replace function edit_borrower(p jsonb)
returns jsonb language plpgsql as $$
declare
  rec borrowers%rowtype;
begin
  update borrowers set
    name = coalesce(p->>'name', name),
    father_name = coalesce(p->>'fatherName', father_name),
    address = coalesce(p->>'address', address),
    mobile = coalesce(p->>'mobile', mobile),
    email = coalesce(p->>'email', email),
    remarks = coalesce(p->>'remarks', remarks),
    loan_amount = coalesce((p->>'loanAmount')::numeric, loan_amount),
    loan_date = coalesce((p->>'loanDate')::date, loan_date),
    "references" = coalesce(p->'references', "references")
  where id = p->>'id'
  returning * into rec;

  if not found then return jsonb_build_object('error', 'Borrower not found'); end if;
  perform log_audit('EDIT', 'Borrower', p->>'id', p);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function set_borrower_status(p jsonb)
returns jsonb language plpgsql as $$
begin
  update borrowers set status = p->>'status' where id = p->>'id';
  if not found then return jsonb_build_object('error', 'Borrower not found'); end if;
  perform log_audit('STATUS_CHANGE', 'Borrower', p->>'id', p);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function delete_borrower(p jsonb)
returns jsonb language plpgsql as $$
declare
  deleted borrowers%rowtype;
  la record;
begin
  -- Same reasoning as delete_investor: borrower IDs (B-1, B-2...) are now
  -- reusable once freed, so every dependent record — each loan account,
  -- its transactions, and its EMI schedule — must be fully removed first.
  for la in select id from loan_accounts where borrower_id = p->>'id' loop
    delete from loan_emi_schedule where loan_account_id = la.id;
    delete from loan_transactions where loan_account_id = la.id;
  end loop;
  delete from loan_accounts where borrower_id = p->>'id';
  delete from borrowers where id = p->>'id' returning * into deleted;
  if not found then return jsonb_build_object('error', 'Borrower not found'); end if;
  perform log_audit('DELETE', 'Borrower', p->>'id', to_jsonb(deleted));
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------- Investment / Account operations ----------

create or replace function next_receipt_no()
returns text language plpgsql as $$
declare
  seq integer;
begin
  seq := next_counter('receipt');
  return 'TPF-' || lpad(seq::text, 4, '0');
end;
$$;

-- p: investorId, amount, date, roi, remarks, topUpAccountId (optional),
--    paymentMode, chequeNo, chequeDate, drawnOnBank, txnRefNo, narration,
--    creditAccountNo, creditAccountName
create or replace function add_investment(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_investor investors%rowtype;
  v_account accounts%rowtype;
  v_txn transactions%rowtype;
  v_val record;
  v_add_amount numeric;
  v_new_balance numeric;
  v_receipt text;
  v_seq integer;
  v_account_no text;
begin
  select * into v_investor from investors where id = p->>'investorId';
  if not found then return jsonb_build_object('error', 'Investor not found'); end if;

  v_receipt := next_receipt_no();

  -- ---- Top-up mode ----
  if p ? 'topUpAccountId' and p->>'topUpAccountId' is not null and p->>'topUpAccountId' <> '' then
    select * into v_account from accounts where id = (p->>'topUpAccountId')::uuid;
    if not found then return jsonb_build_object('error', 'Account to top up was not found'); end if;
    if v_account.status = 'CLOSED' then return jsonb_build_object('error', 'Cannot add funds to a closed account'); end if;
    if v_account.investor_id <> p->>'investorId' then return jsonb_build_object('error', 'Account does not belong to this investor'); end if;

    select * into v_val from compute_account_value(v_account.id, (p->>'date')::date);
    v_add_amount := (p->>'amount')::numeric;
    v_new_balance := v_val.current_value + v_add_amount;

    insert into transactions (account_id, investor_id, txn_date, txn_type, amount,
      balance_before, interest_added, balance_after, remarks, receipt_no, payment_mode,
      cheque_no, cheque_date, drawn_on_bank, txn_ref_no, narration, credit_account_no, credit_account_name)
    values (v_account.id, p->>'investorId', (p->>'date')::date, 'TOPUP', v_add_amount,
      v_val.running_balance, v_val.accrued_interest, v_new_balance, coalesce(p->>'remarks',''),
      v_receipt, coalesce(p->>'paymentMode',''), coalesce(p->>'chequeNo',''),
      nullif(p->>'chequeDate','')::date, coalesce(p->>'drawnOnBank',''), coalesce(p->>'txnRefNo',''),
      coalesce(p->>'narration',''), coalesce(p->>'creditAccountNo',''), coalesce(p->>'creditAccountName',''))
    returning * into v_txn;

    perform log_audit('TOPUP', 'Account', v_account.id::text, to_jsonb(v_txn));
    return jsonb_build_object('ok', true, 'account', to_jsonb(v_account), 'transaction', to_jsonb(v_txn), 'topUp', true);
  end if;

  -- ---- New account mode ----
  select count(*) into v_seq from accounts where investor_id = p->>'investorId';
  v_account_no := (p->>'investorId') || '-' || lpad((v_seq + 1)::text, 3, '0');

  insert into accounts (account_no, investor_id, opening_date, opening_amount, roi, status)
  values (v_account_no, p->>'investorId', (p->>'date')::date, (p->>'amount')::numeric, (p->>'roi')::numeric, 'ACTIVE')
  returning * into v_account;

  insert into transactions (account_id, investor_id, txn_date, txn_type, amount,
    balance_before, interest_added, balance_after, remarks, receipt_no, payment_mode,
    cheque_no, cheque_date, drawn_on_bank, txn_ref_no, narration, credit_account_no, credit_account_name)
  values (v_account.id, p->>'investorId', (p->>'date')::date, 'INVESTMENT', (p->>'amount')::numeric,
    0, 0, (p->>'amount')::numeric, coalesce(p->>'remarks',''),
    v_receipt, coalesce(p->>'paymentMode',''), coalesce(p->>'chequeNo',''),
    nullif(p->>'chequeDate','')::date, coalesce(p->>'drawnOnBank',''), coalesce(p->>'txnRefNo',''),
    coalesce(p->>'narration',''), coalesce(p->>'creditAccountNo',''), coalesce(p->>'creditAccountName',''))
  returning * into v_txn;

  perform log_audit('CREATE', 'Account', v_account.id::text, to_jsonb(v_account));
  return jsonb_build_object('ok', true, 'account', to_jsonb(v_account), 'transaction', to_jsonb(v_txn), 'topUp', false);
end;
$$;

-- ---------- Recalculation engine ----------
-- Replays ALL of an account's transactions in chronological order and
-- rewrites balance_before / interest_added / balance_after for each.
-- Ported 1:1 from recalculateAccount in AppsScript.gs.txt.
create or replace function recalculate_account(p_account_id uuid)
returns jsonb language plpgsql as $$
declare
  acc accounts%rowtype;
  t transactions%rowtype;
  v_balance numeric := 0;
  v_last_date date;
  v_final_status text := 'ACTIVE';
  v_days integer;
  v_interest numeric;
  v_balance_before numeric;
  v_balance_after numeric;
begin
  select * into acc from accounts where id = p_account_id;
  if not found then return jsonb_build_object('error', 'Account not found for recalculation'); end if;

  v_last_date := acc.opening_date;

  for t in
    select * from transactions where account_id = p_account_id
    order by txn_date asc, created_at asc
  loop
    v_days := days_between(v_last_date, t.txn_date);
    v_interest := calc_interest(v_balance, acc.roi, v_days);
    v_balance_before := v_balance + v_interest;

    if t.txn_type = 'INVESTMENT' then
      v_balance_after := t.amount;
      v_final_status := 'ACTIVE';
    elsif t.txn_type = 'TOPUP' then
      v_balance_after := v_balance_before + t.amount;
      v_final_status := 'ACTIVE';
    elsif t.txn_type = 'FULL_SETTLEMENT' then
      v_balance_after := 0;
      v_final_status := 'CLOSED';
    else -- WITHDRAWAL
      v_balance_after := v_balance_before - t.amount;
      v_final_status := 'ACTIVE';
    end if;

    update transactions set
      balance_before = case when t.txn_type = 'INVESTMENT' then 0 else v_balance_before end,
      interest_added = case when t.txn_type = 'INVESTMENT' then 0 else v_interest end,
      balance_after = v_balance_after
    where id = t.id;

    v_balance := v_balance_after;
    v_last_date := t.txn_date;
  end loop;

  update accounts set status = v_final_status where id = p_account_id;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------- Edit / delete a transaction ----------
-- ROI is intentionally not editable here — it belongs to the account.
create or replace function edit_transaction(p jsonb)
returns jsonb language plpgsql as $$
declare
  t transactions%rowtype;
  recalc jsonb;
begin
  select * into t from transactions where id = (p->>'id')::uuid;
  if not found then return jsonb_build_object('error', 'Transaction not found'); end if;

  if p ? 'amount' and (p->>'amount')::numeric <= 0 then
    return jsonb_build_object('error', 'Amount must be greater than zero');
  end if;

  update transactions set
    txn_date = coalesce((p->>'txnDate')::date, txn_date),
    amount = coalesce((p->>'amount')::numeric, amount),
    remarks = coalesce(p->>'remarks', remarks),
    payment_mode = coalesce(p->>'paymentMode', payment_mode),
    cheque_no = coalesce(p->>'chequeNo', cheque_no),
    cheque_date = coalesce(nullif(p->>'chequeDate','')::date, cheque_date),
    drawn_on_bank = coalesce(p->>'drawnOnBank', drawn_on_bank),
    txn_ref_no = coalesce(p->>'txnRefNo', txn_ref_no),
    narration = coalesce(p->>'narration', narration),
    credit_account_no = coalesce(p->>'creditAccountNo', credit_account_no),
    credit_account_name = coalesce(p->>'creditAccountName', credit_account_name)
  where id = (p->>'id')::uuid;

  recalc := recalculate_account(t.account_id);
  if recalc ? 'error' then return recalc; end if;

  perform log_audit('EDIT', 'Transaction', p->>'id', p);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function delete_transaction(p jsonb)
returns jsonb language plpgsql as $$
declare
  deleted transactions%rowtype;
  recalc jsonb;
begin
  delete from transactions where id = (p->>'id')::uuid returning * into deleted;
  if not found then return jsonb_build_object('error', 'Transaction not found'); end if;

  recalc := recalculate_account(deleted.account_id);
  if recalc ? 'error' then return recalc; end if;

  perform log_audit('DELETE', 'Transaction', p->>'id', to_jsonb(deleted));
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function delete_account(p jsonb)
returns jsonb language plpgsql as $$
declare
  deleted accounts%rowtype;
begin
  delete from accounts where id = (p->>'id')::uuid returning * into deleted;
  if not found then return jsonb_build_object('error', 'Account not found'); end if;
  perform log_audit('DELETE', 'Account', (p->>'id'), to_jsonb(deleted));
  return jsonb_build_object('ok', true);
end;
$$;

-- p: accountId, date, amount, remarks, fullSettlement (optional bool)
create or replace function withdraw(p jsonb)
returns jsonb language plpgsql as $$
declare
  acc accounts%rowtype;
  v_val record;
  v_amount numeric;
  v_balance_after numeric;
  v_is_full boolean;
  v_txn transactions%rowtype;
begin
  select * into acc from accounts where id = (p->>'accountId')::uuid;
  if not found then return jsonb_build_object('error', 'Account not found'); end if;
  if acc.status = 'CLOSED' then return jsonb_build_object('error', 'Account is already closed'); end if;

  select * into v_val from compute_account_value(acc.id, (p->>'date')::date);

  v_amount := (p->>'amount')::numeric;
  if v_amount <= 0 then return jsonb_build_object('error', 'Withdrawal amount must be greater than zero'); end if;
  if v_amount > v_val.current_value + 0.01 then
    return jsonb_build_object('error', 'Withdrawal amount exceeds available value (Rs. ' || round(v_val.current_value,2)::text || ')');
  end if;

  v_balance_after := v_val.current_value - v_amount;
  v_is_full := coalesce((p->>'fullSettlement')::boolean, false) or v_balance_after < 0.01;

  insert into transactions (account_id, investor_id, txn_date, txn_type, amount,
    balance_before, interest_added, balance_after, remarks)
  values (acc.id, acc.investor_id, (p->>'date')::date,
    case when v_is_full then 'FULL_SETTLEMENT' else 'WITHDRAWAL' end,
    v_amount, v_val.running_balance, v_val.accrued_interest,
    case when v_is_full then 0 else v_balance_after end, coalesce(p->>'remarks',''))
  returning * into v_txn;

  if v_is_full then
    update accounts set status = 'CLOSED' where id = acc.id;
  end if;

  perform log_audit(case when v_is_full then 'FULL_SETTLEMENT' else 'WITHDRAWAL' end,
    'Account', acc.id::text, to_jsonb(v_txn));

  return jsonb_build_object('ok', true, 'transaction', to_jsonb(v_txn), 'accountClosed', v_is_full);
end;
$$;

-- ---------- Loan Module: EMI amortization ----------
-- Standard reducing-balance EMI: EMI = P * r * (1+r)^n / ((1+r)^n - 1),
-- where r is the MONTHLY rate (annual roi / 12 / 100) and n is tenure in
-- months. Falls back to a simple principal/n split if roi is zero.
-- Flat / add-on interest EMI, per Prashant's actual lending method (NOT
-- bank-style reducing-balance): total interest is calculated once, upfront,
-- on the full principal for the whole tenure, then divided evenly across
-- all months alongside the principal. Every month's EMI is therefore
-- identical in both amount AND in its principal/interest split — unlike a
-- reducing-balance loan where the split shifts each month.
-- Example: Rs 10,000 at 36% p.a. for 10 months
--   interest = 10,000 * 0.36 * (10/12) = Rs 3,000
--   total payable = Rs 13,000 -> EMI = Rs 1,300/month
create or replace function calc_emi_amount(p_principal numeric, p_roi_annual numeric, p_tenure_months integer)
returns numeric language plpgsql immutable as $$
declare
  total_interest numeric;
  total_payable numeric;
begin
  if p_tenure_months is null or p_tenure_months <= 0 then
    raise exception 'Tenure must be a positive number of months';
  end if;
  if p_roi_annual is null or p_roi_annual = 0 then
    return round(p_principal / p_tenure_months, 2);
  end if;
  total_interest := p_principal * (p_roi_annual / 100.0) * (p_tenure_months / 12.0);
  total_payable := p_principal + total_interest;
  return round(total_payable / p_tenure_months, 2);
end;
$$;

-- Builds the full month-by-month amortization schedule for an EMI loan and
-- inserts it into loan_emi_schedule. Called once, right after the loan
-- account is created, so the schedule can be shown/printed immediately.
create or replace function generate_emi_schedule(p_loan_account_id uuid)
returns void language plpgsql as $$
declare
  la loan_accounts%rowtype;
  total_interest numeric;
  interest_part numeric;
  principal_part numeric;
  balance numeric;
  running_principal numeric := 0;
  i integer;
begin
  select * into la from loan_accounts where id = p_loan_account_id;
  if not found then raise exception 'Loan account not found'; end if;
  if la.account_type <> 'EMI' then raise exception 'Schedule only applies to EMI loans'; end if;

  delete from loan_emi_schedule where loan_account_id = p_loan_account_id;

  -- Flat / add-on interest: the same principal and interest amount recurs
  -- every month (not a shrinking interest / growing principal split like a
  -- reducing-balance loan) — this matches how the EMI amount itself is
  -- computed in calc_emi_amount. Due dates and per-installment PENDING/
  -- PAID/OVERDUE status are still tracked per installment as before.
  total_interest := la.principal * (la.roi / 100.0) * (la.tenure_months / 12.0);
  interest_part := round(total_interest / la.tenure_months, 2);
  principal_part := round(la.principal / la.tenure_months, 2);
  balance := la.principal;

  for i in 1..la.tenure_months loop
    running_principal := running_principal + principal_part;
    -- Last installment absorbs any rounding remainder so the schedule
    -- closes exactly to zero, same safeguard as before.
    if i = la.tenure_months then
      principal_part := la.principal - (running_principal - principal_part);
    end if;
    balance := round(balance - principal_part, 2);

    insert into loan_emi_schedule (loan_account_id, installment_no, due_date, emi_amount,
      principal_component, interest_component, closing_balance, status)
    values (p_loan_account_id, i, (la.disbursement_date + (i || ' months')::interval)::date,
      la.emi_amount, principal_part, interest_part, greatest(balance, 0), 'PENDING');
  end loop;
end;
$$;

-- ---------- Loan Module: account operations ----------

create or replace function add_loan_account(p jsonb)
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
  v_emi numeric;
  v_receipt text;
  v_sanctioned_limit numeric;
  v_maturity_date date;
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
  v_sanctioned_limit := null;
  v_maturity_date := null;

  if v_account_type = 'OVERDRAFT' then
    v_sanctioned_limit := (p->>'sanctionedLimit')::numeric;
    if v_sanctioned_limit is null or v_sanctioned_limit <= 0 then
      return jsonb_build_object('error', 'Sanctioned limit must be greater than zero for an Overdraft account');
    end if;
    -- The initial draw can be zero — an OD facility may be opened with
    -- nothing drawn yet, unlike Bullet/EMI which always disburse the full
    -- principal immediately.
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
    v_emi := calc_emi_amount(v_principal, v_roi, v_tenure);
  end if;

  if v_account_type = 'BULLET' then
    v_maturity_date := ((p->>'disbursementDate')::date + interval '12 months')::date;
  end if;

  v_loan_no := 'L-' || next_available_number('loan_accounts', 'loan_no', 'L');

  insert into loan_accounts (loan_no, borrower_id, account_type, principal, roi,
    disbursement_date, tenure_months, emi_amount, status, sanctioned_limit, maturity_date)
  values (v_loan_no, p->>'borrowerId', v_account_type, v_principal, v_roi,
    (p->>'disbursementDate')::date, v_tenure, v_emi, 'ACTIVE', v_sanctioned_limit, v_maturity_date)
  returning * into v_loan;

  if v_account_type = 'EMI' then
    perform generate_emi_schedule(v_loan.id);
  end if;

  -- Overdraft with a zero initial draw has nothing to disburse yet — skip
  -- the transaction row entirely rather than record a meaningless Rs 0
  -- disbursement.
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

-- Records a normal repayment against a loan account (BULLET, EMI, or
-- OVERDRAFT). This is deliberately NOT how a loan gets closed anymore —
-- per the spec, Full Settlement is its own explicit action (see
-- full_settlement below) with its own fine/penalty/waiver breakdown, not
-- an automatic side effect of a repayment happening to zero the balance.
-- A repayment that brings an EMI/Bullet loan to Rs 0 simply leaves it
-- ACTIVE with nothing outstanding; an Overdraft at Rs 0 stays open and
-- ready for further draws, exactly like a real bank OD facility.
create or replace function repay_loan(p jsonb)
returns jsonb language plpgsql as $$
declare
  la loan_accounts%rowtype;
  v_val record;
  v_amount numeric;
  v_balance_after numeric;
  v_txn loan_transactions%rowtype;
  v_receipt text;
  v_remaining numeric;
  sched loan_emi_schedule%rowtype;
begin
  select * into la from loan_accounts where id = (p->>'loanAccountId')::uuid;
  if not found then return jsonb_build_object('error', 'Loan account not found'); end if;
  if la.status = 'CLOSED' then return jsonb_build_object('error', 'This loan is closed and cannot accept further repayment.'); end if;

  select * into v_val from compute_loan_value(la.id, (p->>'date')::date);

  v_amount := (p->>'amount')::numeric;
  if v_amount <= 0 then return jsonb_build_object('error', 'Repayment amount must be greater than zero'); end if;
  if v_amount > v_val.current_value + 0.01 then
    return jsonb_build_object('error', 'Repayment amount exceeds outstanding balance (Rs. ' || round(v_val.current_value,2)::text || '). Use Full Settlement to close this loan instead.');
  end if;

  v_balance_after := round(v_val.current_value - v_amount, 2);
  v_receipt := next_receipt_no();

  insert into loan_transactions (loan_account_id, borrower_id, txn_date, txn_type, amount,
    balance_before, interest_added, balance_after, remarks, receipt_no, payment_mode)
  values (la.id, la.borrower_id, (p->>'date')::date, 'REPAYMENT',
    v_amount, v_val.running_balance, v_val.accrued_interest, v_balance_after,
    coalesce(p->>'remarks',''), v_receipt, coalesce(p->>'paymentMode',''))
  returning * into v_txn;

  if la.account_type = 'EMI' then
    v_remaining := v_amount;
    for sched in
      select * from loan_emi_schedule
      where loan_account_id = la.id and status in ('PENDING', 'OVERDUE')
      order by installment_no asc
    loop
      exit when v_remaining < sched.emi_amount - 0.01;
      update loan_emi_schedule set status = 'PAID', paid_txn_id = v_txn.id where id = sched.id;
      v_remaining := v_remaining - sched.emi_amount;
    end loop;
  end if;

  perform log_audit('REPAYMENT', 'LoanAccount', la.id::text, to_jsonb(v_txn));

  return jsonb_build_object('ok', true, 'transaction', to_jsonb(v_txn));
end;
$$;

-- Records a fresh draw on an Overdraft account, up to the sanctioned
-- limit. Rejects the draw if it would push outstanding above the limit —
-- the whole point of a sanctioned limit is that it can't be exceeded.
create or replace function draw_on_overdraft(p jsonb)
returns jsonb language plpgsql as $$
declare
  la loan_accounts%rowtype;
  v_val record;
  v_amount numeric;
  v_receipt text;
  v_txn loan_transactions%rowtype;
begin
  select * into la from loan_accounts where id = (p->>'loanAccountId')::uuid;
  if not found then return jsonb_build_object('error', 'Loan account not found'); end if;
  if la.account_type <> 'OVERDRAFT' then return jsonb_build_object('error', 'Draws only apply to Overdraft accounts'); end if;
  if la.status = 'CLOSED' then return jsonb_build_object('error', 'This Overdraft account is closed.'); end if;

  v_amount := (p->>'amount')::numeric;
  if v_amount <= 0 then return jsonb_build_object('error', 'Draw amount must be greater than zero'); end if;

  select * into v_val from compute_loan_value(la.id, (p->>'date')::date);
  if v_val.current_value + v_amount > la.sanctioned_limit + 0.01 then
    return jsonb_build_object('error', 'This draw would exceed the sanctioned limit of Rs. ' || round(la.sanctioned_limit,2)::text ||
      ' (available: Rs. ' || round(greatest(la.sanctioned_limit - v_val.current_value, 0), 2)::text || ')');
  end if;

  v_receipt := next_receipt_no();
  insert into loan_transactions (loan_account_id, borrower_id, txn_date, txn_type, amount,
    balance_before, interest_added, balance_after, remarks, receipt_no, payment_mode)
  values (la.id, la.borrower_id, (p->>'date')::date, 'DRAW', v_amount,
    v_val.running_balance, v_val.accrued_interest, round(v_val.current_value + v_amount, 2),
    coalesce(p->>'remarks',''), v_receipt, coalesce(p->>'paymentMode',''))
  returning * into v_txn;

  perform log_audit('DRAW', 'LoanAccount', la.id::text, to_jsonb(v_txn));
  return jsonb_build_object('ok', true, 'transaction', to_jsonb(v_txn));
end;
$$;

-- Live outstanding balance for a loan account (BULLET/OVERDRAFT: daily
-- interest on the balance; EMI: no daily accrual, balance only moves via
-- recorded transactions).
create or replace function compute_loan_value(p_loan_account_id uuid, p_as_on date default current_date)
returns table(running_balance numeric, last_event_date date, days_since_last_event integer,
              accrued_interest numeric, current_value numeric)
language plpgsql as $$
declare
  la loan_accounts%rowtype;
  last_txn loan_transactions%rowtype;
  v_balance numeric := 0;
  v_last_date date;
  v_days integer;
  v_interest numeric;
begin
  select * into la from loan_accounts where id = p_loan_account_id;
  if not found then raise exception 'Loan account not found'; end if;

  select * into last_txn from loan_transactions
    where loan_account_id = p_loan_account_id
    order by txn_date desc, created_at desc
    limit 1;

  if found then
    v_balance := last_txn.balance_after;
    v_last_date := last_txn.txn_date;
  else
    v_balance := la.principal;
    v_last_date := la.disbursement_date;
  end if;

  v_days := days_between(v_last_date, p_as_on);
  v_interest := case when la.account_type in ('BULLET', 'OVERDRAFT') then calc_interest(v_balance, la.roi, v_days) else 0 end;

  return query select v_balance, v_last_date, v_days, v_interest, (v_balance + v_interest);
end;
$$;

-- ---------- Centralized loan position engine ----------
-- Single source of truth for everything overdue/fine/penalty/payable
-- related. Every screen (Dashboard, Loan Profile, Reports, Statement PDF,
-- Full Settlement) calls this rather than recalculating its own copy —
-- per Prashant's explicit requirement that no screen may reimplement this
-- math independently.
--
-- Returns different fields populated depending on account_type:
--   BULLET:    principal_outstanding, interest_position, maturity_date,
--              days_overdue, pre_closure_penalty, current_payable
--   EMI:       principal_outstanding, emis_paid, emis_pending,
--              emis_overdue, late_fine, next_emi_due_date,
--              pre_closure_penalty, current_payable
--   OVERDRAFT: principal_outstanding (amount actually drawn),
--              interest_position, sanctioned_limit, available_limit,
--              current_payable (no maturity/fine/penalty concept — a
--              revolving facility, not a term loan)
create or replace function calculate_loan_position(p jsonb)
returns jsonb language plpgsql as $$
declare
  p_loan_account_id uuid := (p->>'loanAccountId')::uuid;
  p_as_of date := coalesce((p->>'asOf')::date, current_date);
  la loan_accounts%rowtype;
  val record;
  v_result jsonb;
  v_emis_paid integer := 0;
  v_emis_pending integer := 0;
  v_emis_overdue integer := 0;
  v_late_fine numeric := 0;
  v_next_due date;
  v_days_overdue integer := 0;
  v_pre_closure_penalty numeric := 0;
  sched loan_emi_schedule%rowtype;
  v_oldest_overdue_due date;
begin
  select * into la from loan_accounts where id = p_loan_account_id;
  if not found then return jsonb_build_object('error', 'Loan account not found'); end if;

  select * into val from compute_loan_value(p_loan_account_id, p_as_of);

  if la.status = 'CLOSED' then
    -- A closed loan's position is frozen at zero — it can never accrue
    -- further interest or fine, per the spec's explicit requirement.
    return jsonb_build_object(
      'accountType', la.account_type, 'status', 'CLOSED',
      'principalOutstanding', 0, 'currentPayable', 0,
      'closureDate', la.closure_date
    );
  end if;

  if la.account_type = 'EMI' then
    for sched in select * from loan_emi_schedule where loan_account_id = p_loan_account_id order by installment_no asc loop
      if sched.status = 'PAID' then
        v_emis_paid := v_emis_paid + 1;
      elsif sched.due_date < p_as_of then
        v_emis_overdue := v_emis_overdue + 1;
        v_late_fine := v_late_fine + (days_between(sched.due_date, p_as_of) * 50);
        if v_oldest_overdue_due is null or sched.due_date < v_oldest_overdue_due then
          v_oldest_overdue_due := sched.due_date;
        end if;
      else
        v_emis_pending := v_emis_pending + 1;
        if v_next_due is null or sched.due_date < v_next_due then v_next_due := sched.due_date; end if;
      end if;
    end loop;
    if v_oldest_overdue_due is not null then
      v_days_overdue := days_between(v_oldest_overdue_due, p_as_of);
    end if;
    -- Pre-closure penalty applies to EMI too if closed before the
    -- schedule's final due date (its "maturity").
    if exists (select 1 from loan_emi_schedule where loan_account_id = p_loan_account_id and due_date > p_as_of) then
      v_pre_closure_penalty := round(val.current_value * 0.03, 2);
    end if;

    v_result := jsonb_build_object(
      'accountType', 'EMI', 'status', la.status,
      'principalOutstanding', val.current_value,
      'emisPaid', v_emis_paid, 'emisPending', v_emis_pending, 'emisOverdue', v_emis_overdue,
      'lateFine', round(v_late_fine, 2), 'daysOverdue', v_days_overdue,
      'nextEmiDueDate', v_next_due,
      'preClosurePenalty', v_pre_closure_penalty,
      'currentPayable', round(val.current_value + v_late_fine + v_pre_closure_penalty, 2)
    );

  elsif la.account_type = 'BULLET' then
    if p_as_of < la.maturity_date then
      v_pre_closure_penalty := round(val.running_balance * 0.03, 2);
    end if;
    if p_as_of > la.maturity_date then
      v_days_overdue := days_between(la.maturity_date, p_as_of);
    end if;
    v_result := jsonb_build_object(
      'accountType', 'BULLET', 'status', la.status,
      'principalOutstanding', val.running_balance,
      'interestPosition', val.accrued_interest,
      'maturityDate', la.maturity_date,
      'daysOverdue', v_days_overdue,
      'preClosurePenalty', v_pre_closure_penalty,
      'currentPayable', round(val.current_value + v_pre_closure_penalty, 2)
    );

  else -- OVERDRAFT
    v_result := jsonb_build_object(
      'accountType', 'OVERDRAFT', 'status', la.status,
      'principalOutstanding', val.running_balance,
      'interestPosition', val.accrued_interest,
      'sanctionedLimit', la.sanctioned_limit,
      'availableLimit', greatest(coalesce(la.sanctioned_limit,0) - val.running_balance, 0),
      'currentPayable', val.current_value
    );
  end if;

  return v_result;
end;
$$;

-- Records a repayment against a loan account (BULLET or EMI). For EMI loans,
-- also marks the oldest PENDING/OVERDUE schedule row(s) as PAID up to the
-- amount received.
-- Capitalizes unpaid accumulated interest into principal for a Bullet loan
-- that has passed its maturity date without being settled — a one-time
-- event per Prashant's explicit requirement ("must never re-capitalize on
-- refresh/reopen"). Idempotent via the capitalized_at guard: once set, this
-- function is a no-op on any subsequent call for the same loan account.
-- Records an INTEREST_CAPITALIZATION transaction so the event is visible
-- in the transaction history, and logs it to the audit trail with the
-- before/after principal values.
create or replace function capitalize_bullet_interest(p_loan_account_id uuid, p_as_of date default current_date)
returns jsonb language plpgsql as $$
declare
  la loan_accounts%rowtype;
  val record;
  v_txn loan_transactions%rowtype;
  v_receipt text;
begin
  select * into la from loan_accounts where id = p_loan_account_id;
  if not found then return jsonb_build_object('error', 'Loan account not found'); end if;
  if la.account_type <> 'BULLET' then return jsonb_build_object('error', 'Capitalization only applies to Bullet loans'); end if;
  if la.status = 'CLOSED' then return jsonb_build_object('ok', true, 'skipped', 'Loan is closed'); end if;
  if la.capitalized_at is not null then return jsonb_build_object('ok', true, 'skipped', 'Already capitalized'); end if;
  if p_as_of < la.maturity_date then return jsonb_build_object('ok', true, 'skipped', 'Not yet at maturity'); end if;

  select * into val from compute_loan_value(p_loan_account_id, la.maturity_date);
  if val.accrued_interest <= 0 then
    -- Nothing to capitalize (loan was already fully paid down by maturity),
    -- but still mark capitalized_at so this check is skipped on future calls.
    update loan_accounts set capitalized_at = now(),
      capitalization_pre_amount = val.running_balance, capitalization_post_amount = val.running_balance
      where id = p_loan_account_id;
    return jsonb_build_object('ok', true, 'skipped', 'No accrued interest to capitalize');
  end if;

  v_receipt := next_receipt_no();
  insert into loan_transactions (loan_account_id, borrower_id, txn_date, txn_type, amount,
    balance_before, interest_added, balance_after, remarks, receipt_no)
  values (la.id, la.borrower_id, la.maturity_date, 'INTEREST_CAPITALIZATION', val.accrued_interest,
    val.running_balance, val.accrued_interest, val.running_balance + val.accrued_interest,
    'Unpaid interest capitalized into principal at maturity', v_receipt)
  returning * into v_txn;

  update loan_accounts set
    capitalized_at = now(),
    capitalization_pre_amount = val.running_balance,
    capitalization_post_amount = val.running_balance + val.accrued_interest
    where id = p_loan_account_id;

  perform log_audit('INTEREST_CAPITALIZATION', 'LoanAccount', p_loan_account_id::text,
    jsonb_build_object('preAmount', val.running_balance, 'postAmount', val.running_balance + val.accrued_interest, 'maturityDate', la.maturity_date));

  return jsonb_build_object('ok', true, 'transaction', to_jsonb(v_txn));
end;
$$;

-- Sweeps all active Bullet loans past their maturity date and capitalizes
-- each one that hasn't been capitalized yet. Safe to call on every data
-- load (like refresh_overdue_status) since capitalize_bullet_interest is
-- itself idempotent.
create or replace function refresh_bullet_capitalization()
returns void language plpgsql as $$
declare
  la record;
begin
  for la in
    select id from loan_accounts
    where account_type = 'BULLET' and status <> 'CLOSED'
      and capitalized_at is null and maturity_date <= current_date
  loop
    perform capitalize_bullet_interest(la.id, current_date);
  end loop;
end;
$$;

-- Full Settlement: the ONE deliberate way a loan account gets closed, per
-- the spec. Computes Final Payable = Principal Outstanding + Interest/EMI
-- Dues + Late Fine + Pre-closure Penalty − Fine Waiver, using
-- calculate_loan_position as the single source of truth for every term in
-- that formula (never recalculated independently here). Records one
-- authoritative FULL_SETTLEMENT transaction with the full breakdown
-- stored in its remarks/audit entry, sets status to CLOSED and stamps
-- closure_date, and is idempotent: calling it again on an already-CLOSED
-- loan is a no-op rather than a duplicate financial event.
--
-- Fine waiver is optional and ADMIN-only (enforced by the caller passing
-- p->>'waivedBy' only when the signed-in role is ADMIN — the database
-- layer trusts the app's role check here, consistent with how the rest of
-- this schema handles ADMIN/USER; see the Fund Management spec's note
-- that a stronger DB-level authorization layer is recommended before
-- heavier multi-user production use). A waiver never deletes or reduces
-- the originally-computed fine figure — it is recorded alongside it.
create or replace function full_settlement(p jsonb)
returns jsonb language plpgsql as $$
declare
  la loan_accounts%rowtype;
  pos jsonb;
  v_principal numeric;
  v_dues numeric;
  v_fine numeric;
  v_penalty numeric;
  v_waiver numeric;
  v_final_payable numeric;
  v_txn loan_transactions%rowtype;
  v_receipt text;
  v_settle_date date;
begin
  select * into la from loan_accounts where id = (p->>'loanAccountId')::uuid;
  if not found then return jsonb_build_object('error', 'Loan account not found'); end if;
  if la.status = 'CLOSED' then
    return jsonb_build_object('ok', true, 'skipped', 'Loan is already closed', 'closureDate', la.closure_date);
  end if;

  v_settle_date := coalesce((p->>'date')::date, current_date);

  -- Bullet loans past maturity must be capitalized first, so the
  -- principal this settlement is based on already reflects that — same
  -- ordering the dashboard/profile views rely on.
  if la.account_type = 'BULLET' and la.capitalized_at is null and v_settle_date >= la.maturity_date then
    perform capitalize_bullet_interest(la.id, v_settle_date);
    select * into la from loan_accounts where id = la.id;
  end if;

  pos := calculate_loan_position(jsonb_build_object('loanAccountId', la.id, 'asOf', v_settle_date));
  if pos ? 'error' then return pos; end if;

  v_principal := coalesce((pos->>'principalOutstanding')::numeric, 0);
  v_dues := coalesce((pos->>'interestPosition')::numeric, 0);
  v_fine := coalesce((pos->>'lateFine')::numeric, 0);
  v_penalty := coalesce((pos->>'preClosurePenalty')::numeric, 0);

  v_waiver := 0;
  if p->>'waivedBy' is not null and v_fine > 0 then
    v_waiver := least(coalesce((p->>'waiveAmount')::numeric, v_fine), v_fine);
  end if;

  v_final_payable := round(v_principal + v_dues + v_fine + v_penalty - v_waiver, 2);

  v_receipt := next_receipt_no();
  insert into loan_transactions (loan_account_id, borrower_id, txn_date, txn_type, amount,
    balance_before, interest_added, balance_after, remarks, receipt_no, payment_mode)
  values (la.id, la.borrower_id, v_settle_date, 'FULL_SETTLEMENT', v_final_payable,
    v_principal, v_dues, 0,
    format('Full settlement: principal %s + dues %s + fine %s + penalty %s - waiver %s = %s',
      v_principal, v_dues, v_fine, v_penalty, v_waiver, v_final_payable),
    v_receipt, coalesce(p->>'paymentMode',''))
  returning * into v_txn;

  update loan_accounts set
    status = 'CLOSED',
    closure_date = v_settle_date,
    fine_waived_amount = case when v_waiver > 0 then v_waiver else fine_waived_amount end,
    fine_waived_by = case when v_waiver > 0 then p->>'waivedBy' else fine_waived_by end,
    fine_waived_at = case when v_waiver > 0 then now() else fine_waived_at end
    where id = la.id;

  if la.account_type = 'EMI' then
    update loan_emi_schedule set status = 'PAID', paid_txn_id = v_txn.id
      where loan_account_id = la.id and status in ('PENDING', 'OVERDUE');
  end if;

  perform log_audit('FULL_SETTLEMENT', 'LoanAccount', la.id::text, jsonb_build_object(
    'principal', v_principal, 'dues', v_dues, 'lateFine', v_fine, 'preClosurePenalty', v_penalty,
    'waivedAmount', v_waiver, 'waivedBy', p->>'waivedBy', 'finalPayable', v_final_payable, 'closureDate', v_settle_date
  ));

  return jsonb_build_object('ok', true, 'transaction', to_jsonb(v_txn), 'breakdown', jsonb_build_object(
    'principalOutstanding', v_principal, 'interestOrDues', v_dues, 'lateFine', v_fine,
    'preClosurePenalty', v_penalty, 'fineWaived', v_waiver, 'finalPayable', v_final_payable
  ));
end;
$$;

-- Flags EMI installments whose due_date has passed with no payment as
-- OVERDUE, and reflects that on the parent loan account. Call this once
-- when the app loads (cheap: only touches rows that need it) rather than on
-- every read, since it performs writes.
create or replace function refresh_overdue_status()
returns void language plpgsql as $$
begin
  update loan_emi_schedule set status = 'OVERDUE'
    where status = 'PENDING' and due_date < current_date;

  update loan_accounts la set status = 'OVERDUE'
    where la.status = 'ACTIVE'
    and exists (select 1 from loan_emi_schedule s where s.loan_account_id = la.id and s.status = 'OVERDUE');
end;
$$;

-- Recomputes balance_after for every transaction on a loan account, in
-- date order, and re-derives the account's status (ACTIVE/CLOSED) from
-- whether the last transaction was a full settlement. Mirrors
-- recalculate_account on the investor side. Needed whenever a loan
-- transaction is deleted (an erroneously-recorded EMI payment, say) so
-- every later balance stays correct instead of going stale.
create or replace function recalculate_loan_account(p_loan_account_id uuid)
returns jsonb language plpgsql as $$
declare
  la loan_accounts%rowtype;
  t loan_transactions%rowtype;
  v_balance numeric := 0;
  v_final_status text := 'ACTIVE';
  v_balance_before numeric;
  v_balance_after numeric;
  v_has_txns boolean := false;
begin
  select * into la from loan_accounts where id = p_loan_account_id;
  if not found then return jsonb_build_object('error', 'Loan account not found for recalculation'); end if;

  for t in
    select * from loan_transactions where loan_account_id = p_loan_account_id
    order by txn_date asc, created_at asc
  loop
    v_has_txns := true;
    v_balance_before := v_balance;

    if t.txn_type = 'DISBURSEMENT' then
      v_balance_after := t.amount;
      v_final_status := 'ACTIVE';
    elsif t.txn_type = 'FULL_SETTLEMENT' then
      v_balance_after := 0;
      v_final_status := 'CLOSED';
    else -- REPAYMENT
      v_balance_after := v_balance_before - t.amount;
      v_final_status := 'ACTIVE';
    end if;

    update loan_transactions set
      balance_before = v_balance_before,
      balance_after = v_balance_after
    where id = t.id;

    v_balance := v_balance_after;
  end loop;

  -- No transactions left at all (the disbursement itself was deleted,
  -- which callers should prevent, but guard anyway) — leave status as-is
  -- rather than guessing.
  if v_has_txns then
    -- Re-derive OVERDUE from the schedule rather than overwriting it, since
    -- refresh_overdue_status() already owns that logic and runs on every
    -- data load.
    update loan_accounts set status = v_final_status
      where id = p_loan_account_id and status <> 'OVERDUE';
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- Deletes a single loan transaction (a wrongly-recorded EMI payment, for
-- example), recalculates every later balance on that loan account, and —
-- if the deleted transaction was the one that marked an EMI installment
-- PAID — resets that installment back to PENDING so its number is free to
-- be used again by the next real payment, per Prashant's numbering rule.
-- Disbursement transactions cannot be deleted this way; delete the whole
-- loan account instead if a loan was created in error.
create or replace function delete_loan_transaction(p jsonb)
returns jsonb language plpgsql as $$
declare
  deleted loan_transactions%rowtype;
  recalc jsonb;
begin
  select * into deleted from loan_transactions where id = (p->>'id')::uuid;
  if not found then return jsonb_build_object('error', 'Transaction not found'); end if;
  if deleted.txn_type = 'DISBURSEMENT' then
    return jsonb_build_object('error', 'The disbursement transaction cannot be deleted on its own — delete the whole loan account instead.');
  end if;

  -- Free up the EMI installment number this payment was covering, if any,
  -- before deleting the transaction (the paid_txn_id FK would otherwise
  -- dangle briefly, which is harmless but tidier to clear first).
  update loan_emi_schedule set status = 'PENDING', paid_txn_id = null
    where paid_txn_id = deleted.id;

  delete from loan_transactions where id = (p->>'id')::uuid;

  recalc := recalculate_loan_account(deleted.loan_account_id);
  if recalc ? 'error' then return recalc; end if;

  perform log_audit('DELETE', 'LoanTransaction', p->>'id', to_jsonb(deleted));
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function delete_loan_account(p jsonb)
returns jsonb language plpgsql as $$
begin
  delete from loan_emi_schedule where loan_account_id = (p->>'loanAccountId')::uuid;
  delete from loan_transactions where loan_account_id = (p->>'loanAccountId')::uuid;
  delete from loan_accounts where id = (p->>'loanAccountId')::uuid;
  perform log_audit('DELETE', 'LoanAccount', p->>'loanAccountId', p);
  return jsonb_build_object('ok', true);
end;
$$;

-- Quick-edit for a loan account from the compact list view. Deliberately
-- narrow in scope: principal, account type, and tenure are NOT editable
-- here because they're baked into the already-generated EMI schedule and
-- disbursement transaction — changing them after the fact would silently
-- desynchronize the schedule from reality. ROI and remarks are safe to
-- edit inline since they don't retroactively invalidate anything already
-- recorded.
create or replace function edit_loan_account(p jsonb)
returns jsonb language plpgsql as $$
declare
  rec loan_accounts%rowtype;
begin
  update loan_accounts set
    roi = coalesce((p->>'roi')::numeric, roi)
  where id = (p->>'id')::uuid
  returning * into rec;

  if not found then return jsonb_build_object('error', 'Loan account not found'); end if;
  perform log_audit('EDIT', 'LoanAccount', p->>'id', p);
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------- Aggregate fetch for the frontend ----------
-- Mirrors getAllData() — one call returns everything the dashboard needs,
-- with each account's live current value computed.
create or replace function get_all_data()
returns jsonb language plpgsql as $$
declare
  v_investors jsonb;
  v_borrowers jsonb;
  v_accounts jsonb;
  v_transactions jsonb;
  v_loan_accounts jsonb;
  v_loan_transactions jsonb;
  v_as_on timestamptz := now();
begin
  perform refresh_overdue_status();
  perform refresh_bullet_capitalization();

  select coalesce(jsonb_agg(to_jsonb(i)), '[]'::jsonb) into v_investors from investors i;
  select coalesce(jsonb_agg(to_jsonb(b)), '[]'::jsonb) into v_borrowers from borrowers b;
  select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) into v_transactions from transactions t;
  select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) into v_loan_transactions from loan_transactions t;

  select coalesce(jsonb_agg(
    to_jsonb(a) || jsonb_build_object(
      'runningBalance', v.running_balance,
      'lastEventDate', v.last_event_date,
      'daysSinceLastEvent', v.days_since_last_event,
      'accruedInterest', v.accrued_interest,
      'currentValue', v.current_value
    )
  ), '[]'::jsonb) into v_accounts
  from accounts a
  cross join lateral compute_account_value(a.id, current_date) v;

  select coalesce(jsonb_agg(
    to_jsonb(la) || jsonb_build_object(
      'runningBalance', v.running_balance,
      'lastEventDate', v.last_event_date,
      'daysSinceLastEvent', v.days_since_last_event,
      'accruedInterest', v.accrued_interest,
      'currentValue', v.current_value,
      'emiSchedule', coalesce((
        select jsonb_agg(to_jsonb(s) order by s.installment_no)
        from loan_emi_schedule s
        where s.loan_account_id = la.id
      ), '[]'::jsonb)
    )
  ), '[]'::jsonb) into v_loan_accounts
  from loan_accounts la
  cross join lateral compute_loan_value(la.id, current_date) v;

  return jsonb_build_object(
    'ok', true,
    'asOnDate', v_as_on,
    'investors', v_investors,
    'accounts', v_accounts,
    'transactions', v_transactions,
    'borrowers', v_borrowers,
    'loanAccounts', v_loan_accounts,
    'loanTransactions', v_loan_transactions
  );
end;
$$;

-- ---------- As-on-date reporting ----------
-- Mirrors computeAccountValueAsOf + getReportAsOf: replays only transactions
-- up to a cutoff date, for a true historical position (not the live value).
create or replace function compute_account_value_as_of(p_account_id uuid, p_as_on date)
returns table(running_balance numeric, last_event_date date, days_since_last_event integer,
              accrued_interest numeric, current_value numeric, status_as_of text, existed boolean)
language plpgsql as $$
declare
  acc accounts%rowtype;
  t transactions%rowtype;
  v_balance numeric := 0;
  v_last_date date;
  v_closed boolean := false;
  v_days integer;
  v_interest numeric;
begin
  select * into acc from accounts where id = p_account_id;
  if not found then raise exception 'Account not found'; end if;

  if acc.opening_date > p_as_on then
    return query select 0::numeric, acc.opening_date, 0, 0::numeric, 0::numeric, 'ACTIVE'::text, false;
    return;
  end if;

  v_last_date := acc.opening_date;

  for t in
    select * from transactions
    where account_id = p_account_id and txn_date <= p_as_on
    order by txn_date asc, created_at asc
  loop
    v_balance := t.balance_after;
    v_last_date := t.txn_date;
    if t.txn_type = 'FULL_SETTLEMENT' then v_closed := true; end if;
  end loop;

  v_days := days_between(v_last_date, p_as_on);
  v_interest := case when v_closed then 0 else calc_interest(v_balance, acc.roi, v_days) end;

  return query select v_balance, v_last_date, v_days, v_interest, (v_balance + v_interest),
    (case when v_closed then 'CLOSED' else 'ACTIVE' end), true;
end;
$$;

-- payload: { asOnDate: date, investorId: optional }
create or replace function get_report_as_of(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_as_on date := coalesce((p->>'asOnDate')::date, current_date);
  v_investor_id text := p->>'investorId';
  inv investors%rowtype;
  acc accounts%rowtype;
  v_val record;
  v_report jsonb := '[]'::jsonb;
  v_inv_accounts jsonb;
  v_inv_bal numeric;
  v_inv_int numeric;
  v_inv_val numeric;
  v_grand_balance numeric := 0;
  v_grand_interest numeric := 0;
  v_grand_value numeric := 0;
begin
  for inv in
    select * from investors
    where (v_investor_id is null or id = v_investor_id)
  loop
    v_inv_accounts := '[]'::jsonb;
    v_inv_bal := 0; v_inv_int := 0; v_inv_val := 0;

    for acc in select * from accounts where investor_id = inv.id loop
      select * into v_val from compute_account_value_as_of(acc.id, v_as_on);
      if v_val.existed then
        v_inv_accounts := v_inv_accounts || jsonb_build_object(
          'id', acc.id, 'accountNo', acc.account_no, 'investorId', acc.investor_id,
          'openingDate', acc.opening_date, 'openingAmount', acc.opening_amount, 'roi', acc.roi,
          'runningBalance', v_val.running_balance, 'lastEventDate', v_val.last_event_date,
          'daysSinceLastEvent', v_val.days_since_last_event, 'accruedInterest', v_val.accrued_interest,
          'currentValue', v_val.current_value, 'statusAsOf', v_val.status_as_of
        );
        v_inv_bal := v_inv_bal + v_val.running_balance;
        v_inv_int := v_inv_int + v_val.accrued_interest;
        v_inv_val := v_inv_val + v_val.current_value;
      end if;
    end loop;

    v_report := v_report || jsonb_build_object(
      'investor', to_jsonb(inv),
      'accounts', v_inv_accounts,
      'totals', jsonb_build_object(
        'runningBalance', v_inv_bal,
        'accruedInterest', v_inv_int,
        'currentValue', v_inv_val
      )
    );
    v_grand_balance := v_grand_balance + v_inv_bal;
    v_grand_interest := v_grand_interest + v_inv_int;
    v_grand_value := v_grand_value + v_inv_val;
  end loop;

  return jsonb_build_object(
    'ok', true, 'asOnDate', v_as_on, 'report', v_report,
    'grandTotals', jsonb_build_object(
      'runningBalance', v_grand_balance, 'accruedInterest', v_grand_interest, 'currentValue', v_grand_value
    )
  );
end;
$$;
