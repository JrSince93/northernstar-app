-- 2026-10-13-wise-reference-unique-index.sql
--
-- WHY
-- On 2026-10-02 the Wise outbound importer inserted the same transfer twice,
-- 1 ms apart: transactions rows 6ebc4352-… and d3bf2665-…, both
-- reference 'WISE-07713285', both $2,600.00 out, dated 2026-10-02. $2,600 was
-- double-counted in Cash Book October, the Dashboard money-out KPI, P&L October
-- and the Accountant Q2 figures until the duplicate was deleted.
--
-- Cause: autoImportWiseExpenses decides what is already in the cash book by
-- reading the in-memory S.tx array, then inserts. The check resolves before the
-- insert lands, so two overlapping runs both pass it. S.tx is per-page state, so
-- a second browser tab cannot see the first tab's insert at all. The in-flight
-- guard added to index.html alongside this file stops one page racing itself; it
-- cannot stop two tabs. Only a database constraint can.
--
-- WHAT
-- A partial unique index over the reference format the importers write:
-- 'WISE-' followed by 6 to 8 digits. Both importers build it as
-- 'WISE-' + wiseRefSuffix(id), where wiseRefSuffix returns the last 8 digits of
-- the Wise transfer id. All 95 WISE- rows in production are 7 or 8 pure digits.
--
-- WHY THE {6,8} BOUND, and not a plain `reference like 'WISE-%'`
-- nextRefFor() hands out zero-padded 3-digit sequences ('WISE-001', 'WISE-002')
-- and the comment above it at index.html:1263 explicitly anticipates a custom
-- cash-book category whose auto-generated prefix happens to be WISE. Worse,
-- addTx writes a recurring series as several rows carrying the SAME reference,
-- so a recurring WISE-prefixed category would legitimately produce duplicates.
-- Bounding the index at 6+ digits keeps every importer reference covered while
-- leaving that whole sequence range (WISE-001 … WISE-99999) outside it.
--
-- No other code path writes a 'WISE-'-prefixed reference:
--   * reconcilePendingPayroll (index.html:8399) and manualMarkPayrollPaid
--     (:8432) write 'PAYROLL-<runid>'.
--   * confirmWisePayment and manualMarkPaid write inv.invoice_ref
--     ('INV-CF-20260719' and friends) — the payment_type is 'Wise Transfer' but
--     the reference never is.
--   * savePayRun and the timesheet importer write 'PAYROLL-PENDING-<runid>'.
--
-- PRECONDITION
-- The index cannot be created while a duplicate exists. Delete the extra row
-- first (d3bf2665-f49d-4f35-9e5e-9eb08b7aa3e9, the later-created and
-- unreferenced one of the pair) and confirm the PRECHECK below returns 0.
--
-- SAFE TO RE-RUN: `if not exists` on the index; the precheck is read-only.

begin;

-- PRECHECK — must return 0 rows. Any row here is a duplicate that has to be
-- resolved by hand before the index can be built.
select reference, count(*) as n, array_agg(id order by created_at) as ids
from public.transactions
where reference ~ '^WISE-[0-9]{6,8}$'
group by reference
having count(*) > 1;

create unique index if not exists transactions_wise_reference_uniq
  on public.transactions (reference)
  where reference ~ '^WISE-[0-9]{6,8}$';

comment on index public.transactions_wise_reference_uniq is
  'Stops the Wise importers double-inserting the same transfer when two runs overlap (two tabs, or a reload mid-sync). Scoped to the importer reference format only: nextRefFor() 3-digit sequences and recurring series that share a reference stay outside it. The importers treat 23505 from this index as "already imported" and carry on silently.';

commit;

-- VERIFY (run after commit)
--
-- Index exists, is unique, and carries the predicate:
--   select indexname, indexdef from pg_indexes
--   where schemaname='public' and tablename='transactions'
--     and indexname='transactions_wise_reference_uniq';
--
-- Still exactly one row per importer reference:
--   select count(*) as wise_rows,
--          count(distinct reference) as distinct_refs
--   from public.transactions where reference ~ '^WISE-[0-9]{6,8}$';
--   -- expect both 94 after the duplicate deletion (95 rows before it)
--
-- The sequence range is NOT covered, so a recurring WISE category still works:
--   select 'WISE-001' ~ '^WISE-[0-9]{6,8}$';   -- expect false
--   select 'WISE-07713285' ~ '^WISE-[0-9]{6,8}$'; -- expect true
--
-- LEDGER — run immediately after:
--   insert into public._migrations_applied (filename, applied_by, notes)
--   values ('2026-10-13-wise-reference-unique-index.sql', '<who ran it>',
--           '<precheck result, row counts, index predicate confirmed>');

-- ROLLBACK
--   drop index if exists public.transactions_wise_reference_uniq;
