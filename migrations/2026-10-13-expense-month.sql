-- 2026-10-13-expense-month.sql
--
-- WHY
-- An expense sometimes belongs to a different month than the one it was paid in.
-- The case that prompted this: rent of $2,600.00 to PDH Trust Account left the
-- Wise account on 2026-10-02 (reference WISE-07713285) but is September 2026
-- rent. Until now the Expenses tab filed every transaction under its own date,
-- so September showed the rent unpaid and October showed two months of it.
--
-- WHAT
-- 1. transactions.expense_month — nullable date, the first of the month the row
--    belongs to for EXPENSES-TAB purposes. NULL means "use the transaction
--    date", which is why there is no backfill and no default: every existing row
--    keeps behaving exactly as it does today.
-- 2. public.move_expense_month(uuid, date) — sets that column AND transfers the
--    linked recurring_expense_instances row to the target month, in one
--    transaction, under row locks.
--
-- SCOPE — this column is read ONLY by the Expenses tab, via expTxMonthKey /
-- expTxInMonth in public/index.html. The Cash Book, Dashboard KPIs and charts,
-- Reports P&L, Tax & BAS, the NDIS budget tracker, the Accountant page,
-- downloadTaxPackage, Wise invoice matching and the Wise import dedupe all stay
-- on the real transaction date. It is also deliberately absent from every INSERT
-- field list in the app, so no importer can ever set or clear it.
--
-- WHY A FUNCTION AND NOT THREE CLIENT CALLS
-- A move is three writes: release the source instance, claim the target
-- instance, stamp the transaction. PostgREST gives the client no transaction, so
-- doing it client-side can leave a transaction moved with its instance still
-- marked paid in the old month. The unique constraint
-- (recurring_expense_id, month, occurrence_number) also means the naive
-- "re-stamp the source instance's month" approach fails with 23505 whenever the
-- target month's row already exists -- which it usually does, because
-- ensureRecurringInstances() creates each month's row lazily as the operator
-- views that month.
--
-- SECURITY INVOKER: RLS still applies, so a role with read-only access to
-- transactions (accountant) gets a policy violation rather than a silent write.
--
-- SAFE TO RE-RUN: `add column if not exists` and `create or replace function`.

begin;

-- ── 1. The column ───────────────────────────────────────────────────────────

alter table public.transactions
  add column if not exists expense_month date;

comment on column public.transactions.expense_month is
  'First day of the month this expense belongs to on the Expenses tab, when that differs from the paid date. NULL = use transactions.date. Read only by the Expenses tab (expTxMonthKey / expTxInMonth); never by the Cash Book, Dashboard, P&L, Tax & BAS, NDIS budget tracker, Accountant page or Wise matching, which all use the real date. Written only by public.move_expense_month().';

-- ── 2. The move ─────────────────────────────────────────────────────────────

create or replace function public.move_expense_month(
  p_tx_id        uuid,
  p_target_month date
)
returns table (
  tx_id                       uuid,
  expense_month               date,
  source_instance_id          uuid,
  source_month                text,
  target_instance_id          uuid,
  target_month                text,
  target_occurrence_number    integer,
  target_recurring_expense_id uuid
)
language plpgsql
security invoker
as $fn$
declare
  v_tx_date      date;
  v_paid_month   date;
  v_target       date;
  v_window_min   date;
  v_window_max   date;
  v_target_key   text;
  v_src_id       uuid;
  v_src_month    text;
  v_re_id        uuid;
  v_tgt_id       uuid;
  v_tgt_occ      integer;
  v_month_rows   integer;
  v_new_em       date;
begin
  -- Lock the transaction first. This is what serialises two tabs moving the same
  -- row: the second call blocks here, then re-reads the committed state.
  select t.date into v_tx_date
  from public.transactions t
  where t.id = p_tx_id
  for update;

  if not found then
    raise exception 'Transaction not found';
  end if;

  if v_tx_date is null then
    raise exception 'This transaction has no date, so it cannot be moved to another month';
  end if;

  v_paid_month := date_trunc('month', v_tx_date)::date;

  -- NULL target = "Reset to paid date": the transaction goes back to being filed
  -- under its own date, and expense_month is cleared rather than set.
  if p_target_month is null then
    v_target  := v_paid_month;
    v_new_em  := null;
  else
    v_target  := date_trunc('month', p_target_month)::date;
    v_new_em  := v_target;
  end if;

  -- Window: 3 months back, 1 month forward of the PAID month. Enforced here and
  -- not only in the UI, so a hand-made RPC call cannot park a transaction in an
  -- arbitrary period and quietly distort a closed quarter.
  v_window_min := (v_paid_month - interval '3 months')::date;
  v_window_max := (v_paid_month + interval '1 month')::date;

  if v_target < v_window_min or v_target > v_window_max then
    raise exception 'Target month % is outside the allowed window (% to %)',
      to_char(v_target, 'Mon YYYY'),
      to_char(v_window_min, 'Mon YYYY'),
      to_char(v_window_max, 'Mon YYYY');
  end if;

  v_target_key := to_char(v_target, 'YYYY-MM');

  -- The instance this transaction currently settles, if any. Locked so a
  -- concurrent match/unlink cannot interleave with the transfer.
  select i.id, i.month, i.recurring_expense_id
    into v_src_id, v_src_month, v_re_id
  from public.recurring_expense_instances i
  where i.transaction_id = p_tx_id
  order by i.month, i.occurrence_number
  limit 1
  for update;

  -- Not linked to a recurring expense: the column is the whole job.
  if v_src_id is null then
    update public.transactions t
       set expense_month = v_new_em
     where t.id = p_tx_id;

    return query select p_tx_id, v_new_em,
                        null::uuid, null::text,
                        null::uuid, null::text, null::integer, null::uuid;
    return;
  end if;

  -- Already filed in the target month: stamp the column, leave instances alone.
  if v_src_month = v_target_key then
    update public.transactions t
       set expense_month = v_new_em
     where t.id = p_tx_id;

    return query select p_tx_id, v_new_em,
                        null::uuid, null::text,
                        v_src_id, v_src_month, null::integer, v_re_id;
    return;
  end if;

  -- Target slot: lowest-numbered pending occurrence in the target month for the
  -- same recurring expense.
  select i.id, i.occurrence_number
    into v_tgt_id, v_tgt_occ
  from public.recurring_expense_instances i
  where i.recurring_expense_id = v_re_id
    and i.month  = v_target_key
    and i.status = 'pending'
    and i.transaction_id is null
  order by i.occurrence_number
  limit 1
  for update;

  if v_tgt_id is null then
    -- No pending slot. Either the month has no rows yet (create one), or every
    -- occurrence is already settled (refuse — never two paid rows for a month).
    select count(*) into v_month_rows
    from public.recurring_expense_instances i
    where i.recurring_expense_id = v_re_id
      and i.month = v_target_key;

    if v_month_rows > 0 then
      raise exception '% already has this recurring expense marked paid — unlink it there first',
        to_char(v_target, 'Mon YYYY');
    end if;

    insert into public.recurring_expense_instances
      (recurring_expense_id, month, occurrence_number, status, transaction_id)
    values (v_re_id, v_target_key, 1, 'pending', null)
    returning id, occurrence_number into v_tgt_id, v_tgt_occ;
  end if;

  -- Release the month it is leaving, so that month reads unpaid rather than
  -- losing its card entirely.
  update public.recurring_expense_instances i
     set transaction_id = null,
         status         = 'pending'
   where i.id = v_src_id;

  -- Claim the target month.
  update public.recurring_expense_instances i
     set transaction_id = p_tx_id,
         status         = 'paid'
   where i.id = v_tgt_id;

  update public.transactions t
     set expense_month = v_new_em
   where t.id = p_tx_id;

  return query select p_tx_id, v_new_em,
                      v_src_id, v_src_month,
                      v_tgt_id, v_target_key, v_tgt_occ, v_re_id;
end;
$fn$;

comment on function public.move_expense_month(uuid, date) is
  'Files an expense under a different month on the Expenses tab, moving any linked recurring_expense_instances row with it, in one transaction under row locks. p_target_month NULL resets to the paid date. Refuses a target outside 3 months back / 1 month forward of the paid month, and refuses a target month whose occurrences are all already paid.';

revoke all on function public.move_expense_month(uuid, date) from public;
-- Supabase's default privileges in `public` grant EXECUTE on every new function
-- directly to anon, so revoking from PUBLIC alone leaves anon able to call it.
revoke all on function public.move_expense_month(uuid, date) from anon;
grant execute on function public.move_expense_month(uuid, date) to authenticated;

commit;

-- VERIFY (run after commit)
--
-- Column exists, nullable, no default, nothing backfilled:
--   select column_name, data_type, is_nullable, column_default
--   from information_schema.columns
--   where table_schema='public' and table_name='transactions'
--     and column_name='expense_month';
--   -- expect: date / YES / null
--   select count(*) as should_be_zero from public.transactions
--   where expense_month is not null;
--
-- Function exists with the right security and grants:
--   select p.proname, p.prosecdef as security_definer,
--          pg_get_function_identity_arguments(p.oid) as args
--   from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--   where n.nspname='public' and p.proname='move_expense_month';
--   -- expect: security_definer = false, args = 'uuid, date'
--   select grantee, privilege_type from information_schema.role_routine_grants
--   where routine_schema='public' and routine_name='move_expense_month';
--   -- expect: authenticated / EXECUTE, and no PUBLIC row
--
-- Window guard refuses an out-of-range target (expect an exception, no change):
--   select public.move_expense_month(
--     '6ebc4352-14f2-4533-b0a3-34e334a9e3bd'::uuid, '2026-01-01'::date);
--
-- LEDGER — run immediately after:
--   insert into public._migrations_applied (filename, applied_by, notes)
--   values ('2026-10-13-expense-month.sql', '<who ran it>',
--           '<column type/nullability, function secdef+grants, window guard raised>');

-- ROLLBACK
--   drop function if exists public.move_expense_month(uuid, date);
--   alter table public.transactions drop column if exists expense_month;
--   -- dropping the column discards every month override that has been set.
