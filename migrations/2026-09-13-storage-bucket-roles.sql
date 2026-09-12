-- Scope the invoices and tx-attachments buckets by staff role.
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
--
-- WHY: both buckets currently grant plain `authenticated`, so any signed-in
-- user reaches every object in them regardless of role. That contradicts the
-- table-level RLS from migrations/2026-09-11-staff-roles.sql, where the
-- accountant is read-only. Concretely, today an accountant login can delete
-- from the invoices bucket — a write it has on no table.
--
-- AFTER THIS RUNS:
--   admin, office_manager   read + write (exactly the operations the app
--                           performs: see "operations" below)
--   accountant              read only
--   anyone with no staff row  nothing — current_staff_role() returns null and
--                           every policy below fails closed
--
-- OPERATIONS — deliberately per-operation, NOT `for all`:
--   invoices          select, insert, delete
--   tx-attachments    select, insert
-- That is precisely what public/index.html does today (both uploads pass
-- `upsert:false`, so neither needs UPDATE; nothing moves or copies objects;
-- receipts are never deleted). `for all` would hand admin/office_manager an
-- UPDATE on both buckets and a DELETE on tx-attachments that no code path
-- uses — and CLAUDE.md calls out tx-attachments as deliberately having no
-- update/delete policy. Add those when a replace/remove feature is built, not
-- speculatively here.
--
-- NOT TOUCHED — the anon-facing onboarding/e-sign buckets, which belong to
-- pages outside this repo. Leave all six of these alone:
--   anon_insert_executed_contracts, anon_read_executed_contracts,
--   anon_insert_onboarding_docs,    anon_read_onboarding_docs,
--   sign-documents anon insert,     sign-documents anon select,
--   sign-documents anon update
-- (`participant-documents` has no policies at all, so only the service role
-- reaches it. That is the pre-existing state; this migration does not change
-- it.)
--
-- current_staff_role() comes from migrations/2026-09-11-staff-roles.sql. It is
-- SECURITY DEFINER and granted to `authenticated`, so these policies can read
-- a caller's role without depending on the staff table's own RLS.
--
-- ROLLBACK: bottom of file. Restores the five original policies verbatim.

begin;

-- ── invoices ─────────────────────────────────────────────────────────────────
-- Was: "invoices select" / "invoices insert" / "invoices delete", each
-- `to authenticated` with only a bucket_id check and no role condition.
drop policy if exists "invoices select" on storage.objects;
drop policy if exists "invoices insert" on storage.objects;
drop policy if exists "invoices delete" on storage.objects;

create policy "invoices select any staff role" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'invoices'
    and public.current_staff_role() in ('admin','office_manager','accountant')
  );

create policy "invoices insert admin or office_manager" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'invoices'
    and public.current_staff_role() in ('admin','office_manager')
  );

create policy "invoices delete admin or office_manager" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'invoices'
    and public.current_staff_role() in ('admin','office_manager')
  );

-- ── tx-attachments ───────────────────────────────────────────────────────────
-- Was: "tx-attachments select" / "tx-attachments insert", same shape.
--
-- The accountant MUST keep select here: downloadTaxPackage() on the Expenses
-- tab signs a URL for every receipt in the year, and `expenses` is in
-- ROLE_TABS.accountant. Revoking it would not raise an error — each receipt
-- would silently count as `failed` and drop out of the ZIP.
drop policy if exists "tx-attachments select" on storage.objects;
drop policy if exists "tx-attachments insert" on storage.objects;

create policy "tx-attachments select any staff role" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'tx-attachments'
    and public.current_staff_role() in ('admin','office_manager','accountant')
  );

create policy "tx-attachments insert admin or office_manager" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'tx-attachments'
    and public.current_staff_role() in ('admin','office_manager')
  );

commit;

-- ── VERIFY ───────────────────────────────────────────────────────────────────
-- Expect 12 rows again: the 7 anon onboarding policies untouched, and the 5
-- below replacing the 5 that were dropped. Every row for these two buckets
-- should now mention current_staff_role().
--
-- select policyname, cmd, roles, qual, with_check
--   from pg_policies
--  where schemaname = 'storage' and tablename = 'objects'
--  order by policyname;
--
-- Functional check, signed in as each role (the app, not the SQL editor — the
-- SQL editor runs as the table owner and bypasses RLS):
--   admin / office_manager  Participants → open an invoice PDF, upload one,
--                           delete one; Expenses → attach a receipt, view it.
--   accountant              Expenses → "Download tax package" must still
--                           include receipts; no upload or delete control is
--                           rendered for this role anywhere.

-- ── ROLLBACK ─────────────────────────────────────────────────────────────────
-- begin;
-- drop policy if exists "invoices select any staff role" on storage.objects;
-- drop policy if exists "invoices insert admin or office_manager" on storage.objects;
-- drop policy if exists "invoices delete admin or office_manager" on storage.objects;
-- drop policy if exists "tx-attachments select any staff role" on storage.objects;
-- drop policy if exists "tx-attachments insert admin or office_manager" on storage.objects;
-- create policy "invoices select" on storage.objects
--   for select to authenticated using (bucket_id = 'invoices');
-- create policy "invoices insert" on storage.objects
--   for insert to authenticated with check (bucket_id = 'invoices');
-- create policy "invoices delete" on storage.objects
--   for delete to authenticated using (bucket_id = 'invoices');
-- create policy "tx-attachments select" on storage.objects
--   for select to authenticated using (bucket_id = 'tx-attachments');
-- create policy "tx-attachments insert" on storage.objects
--   for insert to authenticated with check (bucket_id = 'tx-attachments');
-- commit;
