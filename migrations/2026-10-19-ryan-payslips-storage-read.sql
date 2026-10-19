-- 2026-10-19-ryan-payslips-storage-read.sql
--
-- WHY
-- Ryan must download the PDFs it is about to upload. The existing select
-- policy (payslip_object_visible, SECURITY INVOKER) can't serve Ryan: Ryan has
-- no pay_runs RLS access, so it would see nothing. This adds a separate,
-- read-only policy backed by a definer check.
--
-- WHAT
-- ryan_payslip_object_readable(name): true only for role 'ryan' AND an object
-- whose name equals the payslip_path of an eligible run not yet uploaded
-- (same ryan_payslip_eligible rule as ryan_pending_payslips, so restricted
-- employees and _regen files are excluded). One SELECT policy; no insert,
-- update or delete for Ryan (the existing insert policy needs admin/office_manager).
--
-- Requires 2026-10-19-ryan-payslip-functions.sql.

begin;

create or replace function public.ryan_payslip_object_readable(p_name text)
returns boolean
language sql stable security definer set search_path = ''
as $fn$
  select coalesce(public.current_staff_role() = 'ryan', false)
     and exists (
       select 1 from public.pay_runs pr
        where pr.payslip_path = p_name
          and pr.connecteam_uploaded_at is null
          and public.ryan_payslip_eligible(pr.id)
     )
$fn$;

revoke all on function public.ryan_payslip_object_readable(text) from public, anon;
grant execute on function public.ryan_payslip_object_readable(text) to authenticated;

drop policy if exists "payslips select ryan pending" on storage.objects;
create policy "payslips select ryan pending"
  on storage.objects for select to authenticated
  using (bucket_id = 'payslips' and public.ryan_payslip_object_readable(name));

insert into public._migrations_applied (filename, applied_by, notes)
values ('2026-10-19-ryan-payslips-storage-read.sql',
        'Claude Code via Supabase MCP, operator-authorised',
        'Read-only payslips policy for role ryan: pending, eligible, non-restricted runs only.')
on conflict (filename) do nothing;

commit;

-- ROLLBACK
-- drop policy if exists "payslips select ryan pending" on storage.objects;
-- drop function if exists public.ryan_payslip_object_readable(text);
-- delete from public._migrations_applied where filename='2026-10-19-ryan-payslips-storage-read.sql';
