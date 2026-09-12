-- RLS lockdown: the dashboard's own tables become signed-in-only (Auth Phase 3)
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
--
-- WHY: the anon key is embedded in public/index.html, so anyone who views the
-- page source holds it. Before this runs, that key alone can read and write:
--   * "Allow all" policies to role public on invoice_ledger, dropdown_options,
--     dismissed_recurring_candidates
--   * RLS disabled outright on recurring_expenses, recurring_expense_instances
--
-- pay_runs, employees, participants and transactions are NOT in this file:
-- migrations/2026-09-11-staff-roles.sql gives them role-based policies. A
-- blanket "authenticated full access" here would be OR'd with those and hand
-- the accountant role everything back. Never add them here.
--
-- SAFE FOR THE DASHBOARD: checkAuth/doLogin only call loadAll() once a Supabase
-- Auth session exists, so every query the app makes runs as `authenticated`.
-- This copies the policy schedule_blocks / shift_types / timesheet_name_map
-- already use.
--
-- DELIBERATELY NOT TOUCHED: onboarding_submissions, doc_signatures,
-- agreement_drafts and the onboarding-docs / executed-contracts /
-- sign-documents buckets. Nothing in this repo reads them; they serve the
-- anon-facing onboarding and e-sign pages, which live elsewhere.
--
-- BEFORE RUNNING: confirm those other pages never read or write any table
-- below with the anon key (e.g. an onboarding portal inserting into
-- employees). If one does, it breaks the moment this runs.
--
-- VERIFY AFTER: sign in, load every tab, save one record. Then, signed out,
-- this should return [] rather than rows:
--   curl "https://bhqjsqwbsbhjuhjwxwcp.supabase.co/rest/v1/invoice_ledger?select=id&limit=1" \
--     -H "apikey: <anon key>"
--
-- ROLLBACK: the block at the bottom restores the previous open policies.

begin;

-- Drop the open policies
drop policy if exists "Allow all" on public.invoice_ledger;
drop policy if exists "Allow all" on public.dropdown_options;
drop policy if exists "dismissed_recurring_candidates full access" on public.dismissed_recurring_candidates;

-- RLS on for the two tables that never had it
alter table public.recurring_expenses          enable row level security;
alter table public.recurring_expense_instances enable row level security;

-- Signed-in-only full access, same as schedule_blocks
create policy "authenticated full access" on public.invoice_ledger                for all to authenticated using (true) with check (true);
create policy "authenticated full access" on public.dropdown_options               for all to authenticated using (true) with check (true);
create policy "authenticated full access" on public.dismissed_recurring_candidates for all to authenticated using (true) with check (true);
create policy "authenticated full access" on public.recurring_expenses             for all to authenticated using (true) with check (true);
create policy "authenticated full access" on public.recurring_expense_instances    for all to authenticated using (true) with check (true);

commit;

-- ── ROLLBACK (run only if the dashboard breaks) ──────────────────────────────
-- begin;
-- drop policy if exists "authenticated full access" on public.invoice_ledger;
-- drop policy if exists "authenticated full access" on public.dropdown_options;
-- drop policy if exists "authenticated full access" on public.dismissed_recurring_candidates;
-- drop policy if exists "authenticated full access" on public.recurring_expenses;
-- drop policy if exists "authenticated full access" on public.recurring_expense_instances;
-- create policy "Allow all" on public.invoice_ledger  for all to public using (true) with check (true);
-- create policy "Allow all" on public.dropdown_options for all to public using (true) with check (true);
-- create policy "dismissed_recurring_candidates full access" on public.dismissed_recurring_candidates for all to public using (true) with check (true);
-- alter table public.recurring_expenses          disable row level security;
-- alter table public.recurring_expense_instances disable row level security;
-- commit;
