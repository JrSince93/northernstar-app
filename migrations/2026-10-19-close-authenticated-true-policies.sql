-- 2026-10-19-close-authenticated-true-policies.sql
--
-- WHY
-- Nine tables carry a policy "authenticated full access" with USING (true) /
-- WITH CHECK (true). Today that is harmless only because the sole auth user is
-- the admin. The moment any other login exists (first: the Hermes agent "ryan"),
-- that login could read and write all nine, including onboarding_submissions
-- and doc_signatures (names, DOBs, addresses, TFN/ABN, bank details).
--
-- WHAT
-- ALTER (not drop/recreate) each policy so it requires one of the three
-- existing app roles. admin / office_manager / accountant keep exactly the
-- access they have now; any other authenticated user (no staff row, or a role
-- such as 'ryan') gets nothing. anon policies are not touched, so the
-- onboarding / e-sign pages that submit as anon are unaffected.
--
-- Run BEFORE 2026-10-19-ryan-role-and-connecteam-columns.sql.
-- SAFE TO RE-RUN: alter policy is idempotent.

begin;

do $$
declare t text;
begin
  foreach t in array array[
    'dropdown_options','doc_signatures','dismissed_recurring_candidates',
    'shift_types','timesheet_name_map','schedule_blocks',
    'recurring_expenses','recurring_expense_instances','onboarding_submissions']
  loop
    execute format(
      'alter policy "authenticated full access" on public.%I
         using      (public.current_staff_role() = any (array[''admin'',''office_manager'',''accountant'']))
         with check (public.current_staff_role() = any (array[''admin'',''office_manager'',''accountant'']))', t);
  end loop;
end $$;

insert into public._migrations_applied (filename, applied_by, notes)
values ('2026-10-19-close-authenticated-true-policies.sql',
        'Claude Code via Supabase MCP, operator-authorised',
        'Nine "authenticated full access" policies now require admin/office_manager/accountant instead of true.')
on conflict (filename) do nothing;

commit;

-- VERIFY: expect 0 rows.
-- select tablename, policyname, qual, with_check from pg_policies
--  where schemaname in ('public','storage') and 'authenticated' = any(roles)
--    and (qual = 'true' or with_check = 'true');
--
-- ROLLBACK: same loop with using (true) with check (true).
