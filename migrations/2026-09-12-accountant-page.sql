-- Accountant page (Phase 2 of role-based access)
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
-- Run migrations/2026-09-11-staff-roles.sql FIRST — this depends on
-- public.current_staff_role() and the staff table.
--
-- Two things:
--   1. pay_runs.employee_name — the accountant has no access to `employees`,
--      so a pay run carried no usable name for them (the client fills
--      _empName from S.emps, which is empty under their RLS). Denormalised the
--      same way invoice_ledger.participant_name already is. savePayRun and the
--      timesheet importer write it; this backfills the existing rows.
--   2. invoice_ledger — the accountant needs to read it (it is the only place
--      invoice data lives that they can reach; the table carries
--      participant_name and nothing else participant-sensitive). SELECT only:
--      this page is read-only.
--
-- NOTE: migrations/2026-09-11-rls-lockdown.sql gives invoice_ledger a blanket
-- "authenticated full access" policy. That would let the accountant WRITE
-- invoices. This file replaces it with role-scoped policies, so run this after
-- the lockdown if you run both.

begin;

-- ── 1. employee_name on pay_runs ─────────────────────────────────────────────
alter table public.pay_runs add column if not exists employee_name text;
comment on column public.pay_runs.employee_name is
  'Employee name captured when the pay run was created. Denormalised so the accountant role, which cannot read public.employees, still gets named payroll rows. Kept in step by savePayRun / the timesheet importer; historical rows backfilled 2026-09-12.';

update public.pay_runs r
   set employee_name = e.name
  from public.employees e
 where e.id = r.employee_id
   and r.employee_name is distinct from e.name;

-- ── 2. invoice_ledger: role-scoped ───────────────────────────────────────────
drop policy if exists "Allow all" on public.invoice_ledger;
drop policy if exists "authenticated full access" on public.invoice_ledger;
create policy "admin and office_manager all" on public.invoice_ledger for all to authenticated
  using (public.current_staff_role() in ('admin','office_manager'))
  with check (public.current_staff_role() in ('admin','office_manager'));
create policy "accountant read" on public.invoice_ledger for select to authenticated
  using (public.current_staff_role() = 'accountant');

commit;

-- ── VERIFY ───────────────────────────────────────────────────────────────────
-- select count(*) filter (where employee_name is null) as unnamed_runs from public.pay_runs;
--   → 0 expected (every pay_runs row has an employee_id pointing at a live employee)

-- ── ROLLBACK ─────────────────────────────────────────────────────────────────
-- begin;
-- drop policy if exists "admin and office_manager all" on public.invoice_ledger;
-- drop policy if exists "accountant read" on public.invoice_ledger;
-- create policy "Allow all" on public.invoice_ledger for all to public using (true) with check (true);
-- alter table public.pay_runs drop column if exists employee_name;
-- commit;
