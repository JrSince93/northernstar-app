-- Role-based access, Phase 1: staff roles + RLS on pay_runs, employees,
-- participants and transactions.
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
--
-- ROLES (public.staff.role)
--   admin          full access to everything.
--   office_manager full access, EXCEPT anything revealing the pay of the two
--                  payroll-restricted employees (see is_payroll_restricted_employee):
--                  their pay_runs rows, their employees rows (pay rates, TFN,
--                  bank details), and their payroll rows in transactions.
--   accountant     read-only pay_runs and transactions; no access at all to
--                  employees or participants.
--
-- A signed-in user with NO staff row gets nothing from these four tables, and
-- the app signs them out. That is why this seeds the existing admin login —
-- without that row the admin would be locked out the moment this runs.
--
-- WHY THE "Allow all" POLICIES ARE DROPPED: permissive policies are OR'd, so a
-- role policy has no effect while an "Allow all" to public still exists on the
-- same table. Dropping them also closes anon (embedded-key) access to these
-- four tables. Checked 2026-09-11: the live app queries them as `authenticated`;
-- the anon traffic in pg_stat_statements is the pre-Supabase-Auth app.
--
-- NOT TOUCHED: dropdown_options (Phase 2), and every other table.
-- migrations/2026-09-11-rls-lockdown.sql no longer covers these four tables —
-- its blanket authenticated policy would re-grant the accountant everything.
--
-- Safe to run before or after the matching index.html deploy: the client treats
-- a missing staff table as "admin" (no role enforcement exists yet then either).
--
-- ROLLBACK: bottom of file.

begin;

-- ── staff ────────────────────────────────────────────────────────────────────
create table if not exists public.staff (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null,
  role        text not null check (role in ('admin','office_manager','accountant')),
  employee_id uuid references public.employees(id) on delete set null,
  created_at  timestamptz not null default now()
);
comment on table public.staff is
  'One row per app login: its role, and optionally the employee record it belongs to. Managed from the SQL editor only — there are no insert/update policies, so nobody can change their own role from the app.';

alter table public.staff enable row level security;
create policy "staff read own row" on public.staff
  for select to authenticated using (id = auth.uid());

-- Existing login (admin@northernstarsupport.com). employee_id left null: set it
-- by hand if this login should be linked to an employee record.
insert into public.staff (id, name, role)
values ('77763d8e-6f1d-442d-b4b5-44cd61745776', 'Admin', 'admin')
on conflict (id) do nothing;

-- ── helpers ──────────────────────────────────────────────────────────────────
-- Caller's role, or null. SECURITY DEFINER so policies on other tables can read
-- staff without depending on staff's own RLS.
create or replace function public.current_staff_role() returns text
language sql stable security definer set search_path = '' as $$
  select role from public.staff where id = auth.uid()
$$;

-- The two employees whose pay the office manager must not see, pinned by id
-- (looked up 2026-09-11; the stored name is "Mohamed Falah Bashe", so a name
-- match on "Mohamed Bashe" would silently miss him).
create or replace function public.is_payroll_restricted_employee(emp uuid) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(emp in (
    '2703ae4a-4c46-4802-8fb6-882166a25d82',  -- Mohamed Omer
    '0a0b428e-b5fa-4808-8f17-aa4cfc89824e'   -- Mohamed Falah Bashe
  ), false)
$$;

-- Is this cash-book row a payroll payment to a restricted employee? Two routes,
-- because both exist in the data:
--   * reference PAYROLL-<8 hex> or PAYROLL-PENDING-<8 hex> → the pay run whose
--     id starts with those 8 characters (savePayRun / reconcilePendingPayroll);
--   * description "Payroll - <employee name>..." (catches hand-entered rows,
--     e.g. reference PAY-015).
-- SECURITY DEFINER so it sees the restricted pay_runs/employees rows the
-- office manager's own RLS hides — otherwise the lookup would find nothing.
create or replace function public.is_restricted_payroll_tx(ref text, descr text) returns boolean
language sql stable security definer set search_path = '' as $$
  select
    (coalesce(ref,'') ~* '^PAYROLL-(PENDING-)?[0-9a-f]{8}$' and exists (
       select 1 from public.pay_runs r
       where public.is_payroll_restricted_employee(r.employee_id)
         and r.id::text like lower(right(ref, 8)) || '%'))
    or exists (
       select 1 from public.employees e
       where public.is_payroll_restricted_employee(e.id)
         and lower(coalesce(descr,'')) like 'payroll - ' || lower(e.name) || '%')
$$;

revoke execute on function public.current_staff_role()                  from public, anon;
revoke execute on function public.is_payroll_restricted_employee(uuid)   from public, anon;
revoke execute on function public.is_restricted_payroll_tx(text, text)   from public, anon;
grant  execute on function public.current_staff_role()                  to authenticated;
grant  execute on function public.is_payroll_restricted_employee(uuid)   to authenticated;
grant  execute on function public.is_restricted_payroll_tx(text, text)   to authenticated;

-- ── pay_runs ─────────────────────────────────────────────────────────────────
drop policy if exists "Allow all" on public.pay_runs;
create policy "admin all" on public.pay_runs for all to authenticated
  using (public.current_staff_role() = 'admin')
  with check (public.current_staff_role() = 'admin');
create policy "office_manager all but restricted" on public.pay_runs for all to authenticated
  using (public.current_staff_role() = 'office_manager' and not public.is_payroll_restricted_employee(employee_id))
  with check (public.current_staff_role() = 'office_manager' and not public.is_payroll_restricted_employee(employee_id));
create policy "accountant read" on public.pay_runs for select to authenticated
  using (public.current_staff_role() = 'accountant');

-- ── employees ────────────────────────────────────────────────────────────────
drop policy if exists "Allow all" on public.employees;
create policy "admin all" on public.employees for all to authenticated
  using (public.current_staff_role() = 'admin')
  with check (public.current_staff_role() = 'admin');
create policy "office_manager all but restricted" on public.employees for all to authenticated
  using (public.current_staff_role() = 'office_manager' and not public.is_payroll_restricted_employee(id))
  with check (public.current_staff_role() = 'office_manager' and not public.is_payroll_restricted_employee(id));
-- accountant: no policy → no access.

-- ── participants ─────────────────────────────────────────────────────────────
drop policy if exists "Allow all" on public.participants;
create policy "admin and office_manager all" on public.participants for all to authenticated
  using (public.current_staff_role() in ('admin','office_manager'))
  with check (public.current_staff_role() in ('admin','office_manager'));
-- accountant: no policy → no access.

-- ── transactions ─────────────────────────────────────────────────────────────
drop policy if exists "Allow all" on public.transactions;
create policy "admin all" on public.transactions for all to authenticated
  using (public.current_staff_role() = 'admin')
  with check (public.current_staff_role() = 'admin');
create policy "office_manager all but restricted payroll" on public.transactions for all to authenticated
  using (public.current_staff_role() = 'office_manager' and not public.is_restricted_payroll_tx(reference, description))
  with check (public.current_staff_role() = 'office_manager' and not public.is_restricted_payroll_tx(reference, description));
create policy "accountant read" on public.transactions for select to authenticated
  using (public.current_staff_role() = 'accountant');

commit;

-- ── Adding a staff login later ───────────────────────────────────────────────
-- 1. Supabase dashboard → Authentication → Add user (email + password).
-- 2. insert into public.staff (id, name, role, employee_id)
--    values ('<auth user id>', '<name>', 'office_manager', null);

-- ── ROLLBACK ─────────────────────────────────────────────────────────────────
-- begin;
-- drop policy if exists "admin all" on public.pay_runs;
-- drop policy if exists "office_manager all but restricted" on public.pay_runs;
-- drop policy if exists "accountant read" on public.pay_runs;
-- drop policy if exists "admin all" on public.employees;
-- drop policy if exists "office_manager all but restricted" on public.employees;
-- drop policy if exists "admin and office_manager all" on public.participants;
-- drop policy if exists "admin all" on public.transactions;
-- drop policy if exists "office_manager all but restricted payroll" on public.transactions;
-- drop policy if exists "accountant read" on public.transactions;
-- create policy "Allow all" on public.pay_runs     for all to public using (true) with check (true);
-- create policy "Allow all" on public.employees    for all to public using (true) with check (true);
-- create policy "Allow all" on public.participants for all to public using (true) with check (true);
-- create policy "Allow all" on public.transactions for all to public using (true) with check (true);
-- drop function if exists public.is_restricted_payroll_tx(text, text);
-- drop function if exists public.is_payroll_restricted_employee(uuid);
-- drop function if exists public.current_staff_role();
-- drop table if exists public.staff;
-- commit;
