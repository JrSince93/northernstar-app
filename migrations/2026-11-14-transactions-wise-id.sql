-- 2026-11-14-transactions-wise-id.sql
--
-- WHY
-- Duplicate cash-book rows for one Wise transaction have been fixed by hand at
-- least six times since July 2026 (outbound transfers, a State Trustees deposit,
-- invoice confirmation, the $2,600 PDH transfer WISE-07713285, jar transfers,
-- and the 1 Nov activities-fallback import). Each fix patched one code path.
-- The only database guard, transactions_wise_reference_uniq (2026-10-13), covers
-- `reference ~ '^WISE-[0-9]{6,8}$'` and nothing else: a deposit converted into
-- an NDIS Payment row (INV- reference), a PAYROLL- row, a short id like
-- WISE-343, and every manual entry carry no Wise identity the database can see.
-- And `reference` holds only the last 8 digits of the id, so it is not a
-- reliable key anyway.
--
-- WHAT
-- 1. transactions.wise_id: the FULL Wise id, normalised to every digit after
--    the last hyphen, untruncated. 'TRANSFER-2433035637' (statement endpoint)
--    and '2433035637' (activities fallback) are the same transaction and both
--    give '2433035637'. index.html's wiseIdFull() must produce exactly what the
--    expression below produces. A CHECK keeps it digits-only.
-- 2. Backfill: the 22 INV- payment rows, from invoice_ledger.wise_transfer_id,
--    the only full ids in the database. Each maps 1:1 (verified 2026-11-14:
--    22 matches, 22 distinct rows, 22 distinct ids).
--    NOT backfilled, because the database doesn't hold their full id:
--      - 126 WISE- importer rows (only the last 7-8 digits). The 65 inside the
--        importers' 90-day window self-heal: the next statement sync fills
--        wise_id when a row matches by suffix and amount. The 61 older rows are
--        never seen by an importer again and stay covered by the reference index.
--      - 58 PAYROLL- rows: no id stored, and same-amount same-day pairs exist.
--        reconcilePendingPayroll sets wise_id from now on.
-- 3. transactions_wise_id_uniq: unique on wise_id where not null.
-- 4. invoice_ledger_wise_transfer_uniq: unique on the same normalised
--    expression of wise_transfer_id, so one Wise transfer can pay at most one
--    invoice whichever id format was stored.
--
-- The reference index from 2026-10-13 stays: it still protects the old rows.
--
-- The app degrades gracefully before this runs: every writer sends wise_id as
-- an optional column and drops it (and only it) on PGRST204.
--
-- The Supabase MCP declines DDL, so this is run in the SQL editor.

begin;

-- 0. prechecks: nothing may already violate the new indexes
do $$ begin
  if exists (select 1 from public.invoice_ledger where wise_transfer_id is not null
             group by regexp_replace(regexp_replace(wise_transfer_id,'^.*-',''),'\D','','g') having count(*)>1)
    then raise exception 'precheck: one Wise transfer is linked to two invoices'; end if;
  if exists (select 1 from public.invoice_ledger where wise_transfer_id is not null
             and regexp_replace(regexp_replace(wise_transfer_id,'^.*-',''),'\D','','g') = '')
    then raise exception 'precheck: wise_transfer_id with no digits'; end if;
end $$;

-- 1. column
alter table public.transactions add column wise_id text;
alter table public.transactions add constraint transactions_wise_id_digits check (wise_id ~ '^[0-9]+$');
comment on column public.transactions.wise_id is
  'Full Wise transaction id: every digit after the last hyphen, untruncated. One Wise transaction, one row.';

-- 2. backfill the 22 invoice-payment rows
do $$ declare n int; begin
  update public.transactions t
     set wise_id = regexp_replace(regexp_replace(l.wise_transfer_id,'^.*-',''),'\D','','g')
    from public.invoice_ledger l
   where t.reference = l.invoice_ref and l.status = 'paid' and l.wise_transfer_id is not null
     and abs(t.amount_in - coalesce(l.payment_amount, l.amount)) < 0.005;
  get diagnostics n = row_count;
  if n <> 22 then raise exception 'backfill hit % rows, expected 22', n; end if;
end $$;

-- 3-4. indexes
create unique index transactions_wise_id_uniq on public.transactions (wise_id) where wise_id is not null;
create unique index invoice_ledger_wise_transfer_uniq on public.invoice_ledger
  ((regexp_replace(regexp_replace(wise_transfer_id,'^.*-',''),'\D','','g'))) where wise_transfer_id is not null;

insert into public._migrations_applied (filename, applied_by, notes)
values ('2026-11-14-transactions-wise-id.sql', 'Moby (SQL editor)',
        'wise_id column + check, 22 INV rows backfilled from invoice_ledger, two partial unique indexes');
commit;

-- VERIFY (expected: 22 | 22 | 2 | 1)
select (select count(*) from public.transactions where wise_id is not null) backfilled,
       (select count(distinct wise_id) from public.transactions where wise_id is not null) distinct_ids,
       (select count(*) from pg_indexes where indexname in ('transactions_wise_id_uniq','invoice_ledger_wise_transfer_uniq')) new_indexes,
       (select count(*) from public._migrations_applied where filename = '2026-11-14-transactions-wise-id.sql') ledger_row;

-- ROLLBACK (only if needed; removes the column and both indexes)
-- begin;
-- drop index if exists public.invoice_ledger_wise_transfer_uniq;
-- drop index if exists public.transactions_wise_id_uniq;
-- alter table public.transactions drop column if exists wise_id;
-- delete from public._migrations_applied where filename = '2026-11-14-transactions-wise-id.sql';
-- commit;
