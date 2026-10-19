-- 2026-10-19-ryan-role-and-connecteam-columns.sql
--
-- WHY
-- The Hermes agent "Ryan" gets its own login with role 'ryan'. Ryan has NO
-- table policies anywhere: every pay_runs / employees / staff policy names a
-- specific role, so 'ryan' matches none of them. Everything Ryan can do goes
-- through ryan_* SECURITY DEFINER functions (next migration).
-- Two new columns record the Connecteam upload, written only by
-- ryan_mark_payslip_uploaded().
--
-- Requires 2026-10-19-close-authenticated-true-policies.sql (run it first),
-- otherwise a 'ryan' login could read/write nine tables via USING (true).
-- The web app already refuses an unknown role: loadStaffRole() returns
-- 'norole' when ROLE_TABS has no entry, so a ryan login is signed out there.

begin;

alter table public.staff drop constraint staff_role_check;
alter table public.staff add constraint staff_role_check
  check (role = any (array['admin','office_manager','accountant','ryan']));

alter table public.pay_runs
  add column if not exists connecteam_payslip_id  text,
  add column if not exists connecteam_uploaded_at timestamptz;

-- Both set together or neither.
alter table public.pay_runs add constraint pay_runs_connecteam_upload_pair
  check ((connecteam_payslip_id is null) = (connecteam_uploaded_at is null));

-- One Connecteam payslip can't be recorded against two pay runs.
create unique index if not exists pay_runs_connecteam_payslip_id_uniq
  on public.pay_runs (connecteam_payslip_id) where connecteam_payslip_id is not null;

insert into public._migrations_applied (filename, applied_by, notes)
values ('2026-10-19-ryan-role-and-connecteam-columns.sql',
        'Claude Code via Supabase MCP, operator-authorised',
        'staff role ryan; pay_runs.connecteam_payslip_id + connecteam_uploaded_at (paired check, unique id).')
on conflict (filename) do nothing;

commit;

-- ROLLBACK
-- alter table public.pay_runs drop constraint if exists pay_runs_connecteam_upload_pair;
-- drop index if exists public.pay_runs_connecteam_payslip_id_uniq;
-- alter table public.pay_runs drop column if exists connecteam_payslip_id, drop column if exists connecteam_uploaded_at;
-- alter table public.staff drop constraint staff_role_check;
-- alter table public.staff add constraint staff_role_check check (role = any (array['admin','office_manager','accountant']));
-- delete from public._migrations_applied where filename='2026-10-19-ryan-role-and-connecteam-columns.sql';
