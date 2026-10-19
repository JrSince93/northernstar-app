-- 2026-10-19-ryan-payslip-functions.sql
--
-- WHY
-- Ryan's whole payslip surface: list what's waiting, mark one uploaded.
-- Pattern for every future Ryan capability: one ryan_* SECURITY DEFINER
-- function, search_path '', guarded by current_staff_role() = 'ryan', EXECUTE
-- revoked from public/anon. Never a table policy for 'ryan'.
--
-- ELIGIBLE RUN (one definition, ryan_payslip_eligible, used everywhere):
--   status 'paid', payslip_path set, payslip_regenerated false,
--   payslip_saved_at on/after 19 Oct 2026 00:00 Melbourne, not a
--   payroll-restricted employee (public.is_payroll_restricted_employee).
-- payslip_saved_at, not paid_date: paid_date is set at insert to the planned
-- pay Friday, so it says nothing about when the run was actually paid.
--
-- Requires 2026-10-19-ryan-role-and-connecteam-columns.sql.
-- SAFE TO RE-RUN: create or replace + revoke/grant.

begin;

-- Internal: no EXECUTE for anyone but the owner; called only from the
-- definer functions below (which run as owner).
create or replace function public.ryan_payslip_eligible(p_pay_run_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $fn$
  select exists (
    select 1 from public.pay_runs pr
     where pr.id = p_pay_run_id
       and pr.status = 'paid'
       and pr.payslip_path is not null
       and pr.payslip_regenerated = false
       and pr.payslip_saved_at >= timestamptz '2026-10-19 00:00:00 Australia/Melbourne'
       and not public.is_payroll_restricted_employee(pr.employee_id)
  )
$fn$;

create or replace function public.ryan_pending_payslips()
returns table (pay_run_id uuid, employee_id uuid, employee_name text, employee_email text,
               period_start date, period_end date, net_pay numeric, payslip_path text)
language plpgsql stable security definer set search_path = ''
as $fn$
begin
  if public.current_staff_role() is distinct from 'ryan' then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return query
    select pr.id, pr.employee_id, e.name, e.email,
           pr.period_start, pr.period_end, pr.net_pay, pr.payslip_path
      from public.pay_runs pr
      join public.employees e on e.id = pr.employee_id
     where pr.connecteam_uploaded_at is null
       and public.ryan_payslip_eligible(pr.id)
     order by pr.payslip_saved_at, pr.id;
end
$fn$;

-- Returns 'marked', or 'already_marked' when called again with the same id
-- (safe retry). Anything else raises one generic error, so Ryan can't tell a
-- restricted, unpaid or nonexistent run apart.
create or replace function public.ryan_mark_payslip_uploaded(p_pay_run_id uuid, p_connecteam_payslip_id text)
returns text
language plpgsql volatile security definer set search_path = ''
as $fn$
declare
  v_id text := nullif(btrim(p_connecteam_payslip_id), '');
  v_existing text;
begin
  if public.current_staff_role() is distinct from 'ryan' then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_pay_run_id is null or v_id is null or length(v_id) > 200 then
    raise exception 'pay_run_id and connecteam_payslip_id are required' using errcode = '22023';
  end if;

  update public.pay_runs pr
     set connecteam_payslip_id = v_id, connecteam_uploaded_at = now()
   where pr.id = p_pay_run_id
     and pr.connecteam_payslip_id is null
     and pr.connecteam_uploaded_at is null
     and public.ryan_payslip_eligible(pr.id);
  if found then return 'marked'; end if;

  select pr.connecteam_payslip_id into v_existing
    from public.pay_runs pr
   where pr.id = p_pay_run_id and public.ryan_payslip_eligible(pr.id);
  if v_existing = v_id then return 'already_marked'; end if;

  raise exception 'pay run not eligible, or already marked with a different Connecteam id'
    using errcode = 'P0001';
end
$fn$;

revoke all on function public.ryan_payslip_eligible(uuid) from public, anon, authenticated;
revoke all on function public.ryan_pending_payslips() from public, anon;
revoke all on function public.ryan_mark_payslip_uploaded(uuid, text) from public, anon;
grant execute on function public.ryan_pending_payslips() to authenticated;
grant execute on function public.ryan_mark_payslip_uploaded(uuid, text) to authenticated;

insert into public._migrations_applied (filename, applied_by, notes)
values ('2026-10-19-ryan-payslip-functions.sql',
        'Claude Code via Supabase MCP, operator-authorised',
        'ryan_payslip_eligible (owner-only), ryan_pending_payslips(), ryan_mark_payslip_uploaded(uuid,text); definer, role-guarded.')
on conflict (filename) do nothing;

commit;

-- ROLLBACK
-- drop function if exists public.ryan_mark_payslip_uploaded(uuid, text);
-- drop function if exists public.ryan_pending_payslips();
-- drop function if exists public.ryan_payslip_eligible(uuid);
-- delete from public._migrations_applied where filename='2026-10-19-ryan-payslip-functions.sql';
