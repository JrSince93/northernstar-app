-- 2026-10-19-payslips-bucket.sql
--
-- WHY
-- The app saves a PDF of each payslip when its pay run becomes paid. That file
-- is the permanent record of what the worker was paid, so it must be private,
-- readable only by staff who can already see the pay run in the app, and
-- impossible to overwrite or delete through the API.
-- Requires 2026-10-19-pay-runs-payslip-columns.sql (run it first).
--
-- WHAT
-- 1. Bucket `payslips`: private, application/pdf only, 2 MB per file.
-- 2. public.payslip_object_visible(name, require_paid) — SECURITY INVOKER.
--    Parses an object path of the form
--        {employee_id}/{period_end}_{pay_run_id}.pdf        (saved when paid)
--        {employee_id}/{period_end}_{pay_run_id}_regen.pdf  (later backfill)
--    and returns true only if the CALLER can see a pay_runs row with exactly
--    that id, employee_id and period_end (and, when require_paid, status 'paid').
--    Because it runs as the caller, the existing pay_runs RLS applies inside it:
--    the restricted-payroll rule (public.is_payroll_restricted_employee) is
--    enforced here without being copied. Change who can see a pay run and the
--    payslip files follow automatically. Anything that doesn't match the path
--    pattern is simply not visible; text comparison means a malformed path can
--    never raise a uuid/date cast error inside a policy.
-- 3. Storage policies on storage.objects for bucket `payslips`:
--      SELECT  admin / office_manager / accountant  AND the pay run is visible
--      INSERT  admin / office_manager               AND the pay run is visible AND paid
--    NO update policy and NO delete policy, for any role: a saved payslip can't
--    be replaced or removed through the API (the app also uploads with
--    upsert:false). Only the SQL editor / service_role can.
--
-- EFFECTIVE ACCESS (mirrors pay_runs exactly)
--   admin           read + save, every employee
--   office_manager  read + save, except the payroll-restricted employees
--   accountant      read only, every employee (same as its pay_runs read policy)
--   anon / no staff row   nothing
--
-- SAFE TO RE-RUN: bucket insert is `on conflict do nothing`, the function is
-- `create or replace`, and each policy is dropped-if-exists by its own name
-- before being created.

begin;

-- ── 1. Bucket ──────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payslips', 'payslips', false, 2097152, array['application/pdf'])
on conflict (id) do nothing;

-- ── 2. Visibility helper ───────────────────────────────────────────────────
create or replace function public.payslip_object_visible(p_name text, p_require_paid boolean default false)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $fn$
  with m as (
    select regexp_match(
             p_name,
             '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/'
          || '([0-9]{4}-[0-9]{2}-[0-9]{2})_'
          || '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(_regen)?\.pdf$'
           ) as g
  )
  select coalesce((
    select exists (
      select 1
        from public.pay_runs pr
       where pr.id::text          = m.g[3]
         and pr.employee_id::text = m.g[1]
         and to_char(pr.period_end, 'YYYY-MM-DD') = m.g[2]  -- not ::text: that depends on DateStyle
         and (not p_require_paid or pr.status = 'paid')
    )
    from m
    where m.g is not null
  ), false)
$fn$;

comment on function public.payslip_object_visible(text, boolean) is
  'Storage-policy helper for bucket payslips. SECURITY INVOKER: true only if the caller can see (via pay_runs RLS) the pay run named by the object path {employee_id}/{period_end}_{pay_run_id}[_regen].pdf; with require_paid, the run must also be paid.';

revoke all on function public.payslip_object_visible(text, boolean) from public;
revoke all on function public.payslip_object_visible(text, boolean) from anon;
grant execute on function public.payslip_object_visible(text, boolean) to authenticated;

-- ── 3. Storage policies ────────────────────────────────────────────────────
drop policy if exists "payslips select visible pay run" on storage.objects;
create policy "payslips select visible pay run"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'payslips'
    and public.current_staff_role() = any (array['admin','office_manager','accountant'])
    and public.payslip_object_visible(name)
  );

drop policy if exists "payslips insert admin or office_manager" on storage.objects;
create policy "payslips insert admin or office_manager"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'payslips'
    and public.current_staff_role() = any (array['admin','office_manager'])
    and public.payslip_object_visible(name, true)
  );

-- Deliberately NO update and NO delete policy on bucket payslips.

insert into public._migrations_applied (filename, applied_by, notes)
values ('2026-10-19-payslips-bucket.sql',
        'Moby (SQL editor)',
        'Private payslips bucket (pdf, 2 MB), payslip_object_visible() security invoker, select + insert policies only.')
on conflict (filename) do nothing;

commit;

-- VERIFY — one result table; every row's `ok` should be true.
-- (Run as postgres in the SQL editor, which bypasses RLS: the path checks
-- test parsing only. Role enforcement is checked separately as authenticated.)
select check_name, actual, expected, actual = expected as ok from (
  select 1 n, 'bucket private / 2 MB / pdf only' check_name,
         (select public::text||' / '||file_size_limit||' / '||array_to_string(allowed_mime_types, ',') from storage.buckets where id='payslips') actual,
         'false / 2097152 / application/pdf' expected
  union all select 2, 'payslips policies (cmd list)',
         (select string_agg(cmd, ',' order by cmd) from pg_policies where schemaname='storage' and tablename='objects' and policyname like 'payslips%'),
         'INSERT,SELECT'
  union all select 3, 'function security invoker + fixed search_path',
         (select (not prosecdef)::text||' / '||array_to_string(proconfig, ',') from pg_proc where proname='payslip_object_visible'),
         'true / search_path=""'
  union all select 4, 'EXECUTE: anon / authenticated',
         has_function_privilege('anon','public.payslip_object_visible(text,boolean)','execute')::text||' / '||
         has_function_privilege('authenticated','public.payslip_object_visible(text,boolean)','execute')::text,
         'false / true'
  union all select 5, 'real paid run path parses (require_paid)',
         (select public.payslip_object_visible(employee_id||'/'||to_char(period_end,'YYYY-MM-DD')||'_'||id||'.pdf', true)::text
            from public.pay_runs where status='paid' limit 1),
         'true'
  union all select 6, 'same run, _regen suffix parses',
         (select public.payslip_object_visible(employee_id||'/'||to_char(period_end,'YYYY-MM-DD')||'_'||id||'_regen.pdf')::text
            from public.pay_runs where status='paid' limit 1),
         'true'
  union all select 7, 'wrong period_end rejected',
         (select public.payslip_object_visible(employee_id||'/1999-01-01_'||id||'.pdf')::text from public.pay_runs limit 1),
         'false'
  union all select 8, 'junk / traversal / null rejected',
         public.payslip_object_visible('../etc/passwd')::text||' / '||public.payslip_object_visible(null)::text,
         'false / false'
  union all select 9, 'ledger row',
         (select count(*)::text from public._migrations_applied where filename='2026-10-19-payslips-bucket.sql'),
         '1'
) t order by n;
--
-- ROLLBACK (only while the bucket is empty)
-- drop policy if exists "payslips select visible pay run" on storage.objects;
-- drop policy if exists "payslips insert admin or office_manager" on storage.objects;
-- drop function if exists public.payslip_object_visible(text, boolean);
-- delete from storage.buckets where id='payslips';
-- delete from public._migrations_applied where filename='2026-10-19-payslips-bucket.sql';
