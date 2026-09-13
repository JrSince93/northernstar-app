-- URGENT: revoke anon SELECT on onboarding_submissions and doc_signatures.
-- Run in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp). Run it now.
--
-- WHAT IS WRONG
--   Both tables are readable with the anon key alone. Verified 2026-09-14 by
--   querying them with the key embedded verbatim in public/index.html, which
--   Netlify serves publicly. robots.txt only asks crawlers not to index; it is
--   not access control. Anyone who opens the site and views source can read:
--
--     onboarding_submissions  18 rows  full_name, dob, address, phone, email,
--                                      work_right, emergency_contact,
--                                      tax_or_abn, bank_name, bsb,
--                                      account_number, super_info,
--                                      employee_signature, countersign_token
--     doc_signatures           1 row   sender/recipient names and emails,
--                                      signatures, sign_token, file paths
--
--   The files themselves are NOT exposed: signed_file_url is not an
--   /object/public/ path and an anonymous HEAD returns 400. Storage is holding.
--   This is a row-level exposure only.
--
--   2026-09-11-rls-lockdown.sql deliberately skipped these two, on the grounds
--   that the anon-facing onboarding and e-sign pages need them. Those pages
--   need anon to INSERT a submission. They do not need anon to SELECT every
--   submission ever made.
--
-- WHAT THIS DOES
--   Keeps `authenticated` exactly as it is today (full access), so nothing in
--   the staff dashboard changes. Drops every other policy on the two tables and
--   gives anon INSERT only. Surgical: the only capability removed is the one
--   causing the exposure.
--
-- ⚠️ WHAT THIS WILL BREAK, AND HOW TO SPOT IT
--   PostgREST can only return an inserted row if a SELECT policy allows it. So
--   if the onboarding or e-sign page does:
--
--       await sb.from('onboarding_submissions').insert(row).select()
--
--   the row is still written, but the response errors and the page reports a
--   failure. The fix there is to drop the trailing `.select()` (or send
--   `Prefer: return=minimal`) — the insert itself is unaffected.
--
--   Any anon read-back — a confirmation screen, or the countersign/sign screen
--   fetching a row by token — stops working. That is intended for now. The
--   correct replacement is a SECURITY DEFINER function taking the token and
--   returning only the matching row, so the token grants one row rather than
--   the table. That is the follow-up, not this file.
--
-- ROLLBACK is at the bottom. It restores the exposure — only use it if the
-- onboarding form cannot accept submissions at all, and re-run this after.

begin;

-- RLS must actually be on, or policies are decorative. Harmless if already set.
alter table public.onboarding_submissions enable row level security;
alter table public.doc_signatures        enable row level security;

-- Drop every existing policy on both tables by name, whatever they are called.
-- Done dynamically so this does not depend on a name lookup first — the
-- exposure should not wait on a round trip.
do $$
declare
  t text;
  p record;
begin
  foreach t in array array['onboarding_submissions','doc_signatures'] loop
    for p in
      select policyname from pg_policies
       where schemaname = 'public' and tablename = t
    loop
      execute format('drop policy %I on public.%I', p.policyname, t);
      raise notice 'dropped policy % on %', p.policyname, t;
    end loop;
  end loop;
end $$;

-- ── anon: submit only ────────────────────────────────────────────────────────
-- No USING clause anywhere for anon, so there is no readable path at all.
create policy "anon can submit" on public.onboarding_submissions
  for insert to anon with check (true);

create policy "anon can submit" on public.doc_signatures
  for insert to anon with check (true);

-- ── authenticated: unchanged from today ──────────────────────────────────────
-- Deliberately still `for all ... using (true)`: this file is about closing the
-- anon hole, not about scoping staff access. Scoping these by role is a
-- separate piece of work, alongside the other Security Advisor warnings.
create policy "authenticated full access" on public.onboarding_submissions
  for all to authenticated using (true) with check (true);

create policy "authenticated full access" on public.doc_signatures
  for all to authenticated using (true) with check (true);

commit;

-- ── VERIFY (in the SQL editor) ───────────────────────────────────────────────
-- Expect: anon appears only on the INSERT rows, and no anon row has a `qual`.
--
-- select tablename, policyname, roles, cmd, qual, with_check
--   from pg_policies
--  where schemaname = 'public'
--    and tablename in ('onboarding_submissions','doc_signatures')
--  order by tablename, cmd;
--
-- ── VERIFY (from outside, which is the test that actually matters) ───────────
-- Both must return [] rather than rows:
--
--   curl "https://bhqjsqwbsbhjuhjwxwcp.supabase.co/rest/v1/onboarding_submissions?select=id&limit=1" \
--     -H "apikey: <anon key>"
--   curl "https://bhqjsqwbsbhjuhjwxwcp.supabase.co/rest/v1/doc_signatures?select=id&limit=1" \
--     -H "apikey: <anon key>"
--
-- ── AFTER RUNNING ───────────────────────────────────────────────────────────
-- 1. Submit a test onboarding form end to end. If it reports an error, check
--    the browser console for a SELECT/permission error on the insert — that is
--    the `.insert().select()` case above, not a failed write. Confirm in the
--    dashboard whether the row actually landed before assuming it did not.
-- 2. Consider whether the 18 already-exposed records meet the OAIC notifiable
--    data breach threshold. Bank details and TFNs for identifiable individuals,
--    reachable without authentication, is the kind of thing that scheme exists
--    for. That is a question for someone qualified, not for this file.
-- 3. Rotate anything the exposure could have leaked that is rotatable. The bank
--    details and TFNs are not — which is what makes step 2 the real question.
--
-- ── ROLLBACK (restores the exposure — see the warning above) ─────────────────
-- begin;
-- drop policy if exists "anon can submit" on public.onboarding_submissions;
-- drop policy if exists "anon can submit" on public.doc_signatures;
-- create policy "Allow all" on public.onboarding_submissions for all to public using (true) with check (true);
-- create policy "Allow all" on public.doc_signatures        for all to public using (true) with check (true);
-- commit;
