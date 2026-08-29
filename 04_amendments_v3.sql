-- ============================================================================
-- FinSphere — Amendment Batch v3 (v1.59)
-- Run this AFTER 03_amendments_v2.sql. Safe to re-run.
--
-- Covers:
--   1. approve_agent_repayment() now takes an admin-chosen pool allocation
--      (matches every other repayment path) instead of posting blind
--   2. get_borrower_credit_rating_detail() — powers the "why this score"
--      plain-English incident list shown when tapping the Borrower
--      Profile's credit rating gauge
-- ============================================================================

-- ============================================================================
-- SECTION 9 — Agent-Collected Repayments: full approval with pool choice
-- ============================================================================
-- Rewrites approve_agent_repayment() to accept an admin-chosen
-- poolAllocations array (forwarded straight to repay_loan(), same as a
-- normal admin-entered repayment) instead of posting with no pool choice
-- at all. Returns repay_loan()'s full result (including businessAmount /
-- interestBase) so the frontend can show the same Cred-style credit
-- breakdown popup used everywhere else.
create or replace function public.approve_agent_repayment(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_request_id uuid := (p->>'id')::uuid;
  rec agent_pending_repayments%rowtype;
  v_result jsonb;
begin
  select * into rec from agent_pending_repayments where id = v_request_id and status = 'PENDING';
  if not found then return jsonb_build_object('error', 'Request not found or already decided'); end if;

  v_result := repay_loan(jsonb_build_object(
    'loanAccountId', rec.loan_account_id,
    'date', rec.txn_date,
    'amount', rec.amount,
    'paymentMode', rec.payment_mode,
    'remarks', coalesce(nullif(rec.remarks,''), 'Collected by field agent') || ' (agent-collected, approved)',
    'poolAllocations', p->'poolAllocations'
  ));
  if v_result ? 'error' then return v_result; end if;

  update agent_pending_repayments set
    status = 'APPROVED',
    decided_at = now(),
    resulting_transaction_id = (v_result->'transaction'->>'id')::uuid
  where id = v_request_id;

  return jsonb_build_object('ok', true, 'transaction', v_result->'transaction',
    'businessAmount', v_result->'businessAmount', 'interestBase', v_result->'interestBase');
end;
$$;

-- Borrower-level "why this score" detail: returns every late-paid period
-- (not still-pending ones) as a plain incident, worst-first, plus a
-- simple on-time/total tally, for the Borrower Profile gauge's popup.
create or replace function public.get_borrower_credit_rating_detail(p jsonb)
returns jsonb language plpgsql as $$
declare
  v_borrower_id text := p->>'borrowerId';
  v_avg numeric;
  v_on_time integer;
  v_total integer;
  v_incidents jsonb;
begin
  select avg(score), count(*) filter (where score = 10), count(*)
    into v_avg, v_on_time, v_total
    from credit_rating_periods where borrower_id = v_borrower_id;

  if v_avg is null then
    return jsonb_build_object('ok', true, 'hasData', false, 'rating', null, 'lateIncidents', '[]'::jsonb, 'onTimeCount', 0, 'totalPeriods', 0);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'loanNo', la.loan_no, 'accountType', cp.account_type,
      'monthLabel', to_char(cp.due_date, 'Mon YYYY'),
      'daysLate', days_between(cp.due_date, cp.paid_date)
    ) order by days_between(cp.due_date, cp.paid_date) desc), '[]'::jsonb)
    into v_incidents
    from credit_rating_periods cp
    join loan_accounts la on la.id = cp.loan_account_id
    where cp.borrower_id = v_borrower_id and cp.paid_date is not null and cp.score < 10;

  return jsonb_build_object('ok', true, 'hasData', true, 'rating', round(v_avg),
    'lateIncidents', v_incidents, 'onTimeCount', v_on_time, 'totalPeriods', v_total);
end;
$$;
