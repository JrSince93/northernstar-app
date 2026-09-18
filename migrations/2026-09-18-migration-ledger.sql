-- A queryable record of which migrations have actually been run.
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
--
-- WHY: this project has no `supabase_migrations` schema and no history table,
-- so the only record of what has been applied is the prose table in CLAUDE.md —
-- maintained by hand, and therefore able to drift from reality without anyone
-- noticing. It did. On 2026-09-18 that table still read "WRITTEN, NOT RUN" for
-- 2026-09-13-storage-bucket-roles while its policies were live in production,
-- applied at an unknown time by an unknown actor. The reverse has happened too:
-- 2026-08-29-budget-line-linking sat unapplied for two weeks while every later
-- migration went in, because nothing surfaced the gap.
--
-- This does NOT replace CLAUDE.md's table. The two answer different questions:
--   this ledger      did <file> run, when, and who ran it   (fact, queryable)
--   CLAUDE.md table  what it changed and how it was verified (judgement, prose)
-- Keep both. The ledger is the authoritative answer to "is X applied?".
--
-- DELIBERATELY MINIMAL: a table and an insert convention, not a framework.
-- Nothing in the app reads or writes it; no checksums, no ordering enforcement,
-- no "pending" state. A row means "this file was run against this database".
--
-- ACCESS: RLS on with no policies, and privileges revoked from anon and
-- authenticated. The anon key is embedded in public/index.html on a public site
-- (see 2026-09-11-rls-lockdown), so a new public-schema table must never be
-- readable by default. The SQL editor and service_role bypass RLS and so can
-- still read and write it; that is the only intended access path.

begin;

create table if not exists public._migrations_applied (
  filename   text primary key,
  applied_at timestamptz not null default now(),
  applied_by text,
  notes      text
);

comment on table public._migrations_applied is
  'Ledger of migrations actually run against this database. Insert a row immediately after running any file in migrations/. Authoritative for "is X applied?"; CLAUDE.md''s status table carries the meaning and verification detail.';
comment on column public._migrations_applied.filename is
  'Exact filename from migrations/, including the .sql extension.';
comment on column public._migrations_applied.applied_at is
  'When it was run. Backfilled rows are date-only precision (midnight UTC) and say so in notes.';
comment on column public._migrations_applied.applied_by is
  'Who ran it: the operator, or an agent session acting with explicit authorisation.';
comment on column public._migrations_applied.notes is
  'How it was verified, and any caveat about the recorded date.';

alter table public._migrations_applied enable row level security;
revoke all on public._migrations_applied from anon, authenticated;

-- ── Backfill ────────────────────────────────────────────────────────────────
-- Every migration CLAUDE.md's status table records as applied, as at
-- 2026-09-18. `on conflict do nothing` keeps this file re-runnable.
--
-- DATE HONESTY: only the 2026-09-12 and 2026-09-18 runs have dates anyone
-- actually recorded. The undated "Applied" rows use 2026-09-12, the date of the
-- anon schema probe that confirmed them — that is a "known applied by" date, not
-- an apply date, and each row's notes say so. Where the real date is unknown,
-- the notes say that rather than implying precision the record does not have.
insert into public._migrations_applied (filename, applied_at, applied_by, notes) values
  ('2026-08-29-budget-line-linking.sql',                 '2026-09-12'::timestamptz, 'operator',
   'Backfilled 2026-09-18. Written 29 Aug, not run until 12 Sep; the two-week gap is documented in CLAUDE.md. Confirmed by anon probe: budget_line_id and rate_card went from 42703 to 200.'),
  ('2026-09-04-expense-tracker.sql',                     '2026-09-12'::timestamptz, 'operator',
   'Backfilled 2026-09-18. Date is the 2026-09-12 anon schema probe that confirmed it, not the apply date, which was not recorded.'),
  ('2026-09-05-dismissed-recurring-candidates.sql',      '2026-09-12'::timestamptz, 'operator',
   'Backfilled 2026-09-18. Date is the 2026-09-12 confirmation probe, not the apply date. Table present.'),
  ('2026-09-05-recurring-multi-occurrence.sql',          '2026-09-12'::timestamptz, 'operator',
   'Backfilled 2026-09-18. Date is the 2026-09-12 confirmation probe. PARTIAL VERIFICATION: columns confirmed, but the unique-constraint swap to (recurring_expense_id, month, occurrence_number) is not visible over PostgREST and was never checked.'),
  ('2026-09-05-recurring-weekday-cadence.sql',           '2026-09-12'::timestamptz, 'operator',
   'Backfilled 2026-09-18. Date is the 2026-09-12 confirmation probe. cadence_weekday present.'),
  ('2026-09-07-recurring-interval-months.sql',           '2026-09-12'::timestamptz, 'operator',
   'Backfilled 2026-09-18. Date is the 2026-09-12 confirmation probe. interval_months and tracked_since present.'),
  ('2026-09-07-transaction-notes-attachments.sql',       '2026-09-12'::timestamptz, 'operator',
   'Backfilled 2026-09-18. Date is the 2026-09-12 confirmation probe. note and attachment_path present.'),
  ('2026-09-09-participant-archive.sql',                 '2026-09-12'::timestamptz, 'operator',
   'Backfilled 2026-09-18. Date is the 2026-09-12 confirmation probe. participants.archived_at present.'),
  ('2026-09-11-invoices-bucket.sql',                     '2026-09-13'::timestamptz, 'operator',
   'Backfilled 2026-09-18. Date is the 2026-09-13 pg_policies confirmation, not the apply date. Bucket exists with the 5 MB limit; its three original policies have since been replaced by 2026-09-13-storage-bucket-roles.'),
  ('2026-09-11-staff-roles.sql',                         '2026-09-12'::timestamptz, 'operator',
   'Backfilled 2026-09-18. Operator-run 2026-09-12; public.staff went from 404 PGRST205 to 200.'),
  ('2026-09-11-rls-lockdown.sql',                        '2026-09-12'::timestamptz, 'operator',
   'Backfilled 2026-09-18. Operator-run 2026-09-12; transactions, employees, participants, pay_runs and invoice_ledger returned rows to the bare anon key before and [] after.'),
  ('2026-09-12-accountant-page.sql',                     '2026-09-12'::timestamptz, 'operator',
   'Backfilled 2026-09-18. Operator-run 2026-09-12, after staff-roles and the RLS lockdown. NOT independently verified: its invoice_ledger policy replacement is indistinguishable from the lockdown''s over an anon probe.'),
  ('2026-09-13-storage-bucket-roles.sql',                '2026-09-18'::timestamptz, 'unknown',
   'Backfilled 2026-09-18, TRUE APPLY DATE UNKNOWN. Found already live on 2026-09-18 while CLAUDE.md still said WRITTEN, NOT RUN; no record exists of who ran it or when, and applied_at here is the confirmation date only. Verified via pg_policies: all 5 role-scoped policies present and gated on current_staff_role(); admin sees both buckets, a user with no staff row sees neither. Do not re-run the file as-is — it would fail with 42710 duplicate_object.'),
  ('2026-09-14-lock-onboarding-tables.sql',              '2026-09-18'::timestamptz, 'unknown',
   'Backfilled 2026-09-18, TRUE APPLY DATE UNKNOWN. Same shape as 2026-09-13-storage-bucket-roles: found already in effect, and it had no row in the CLAUDE.md table at all, so applied_at here is the confirmation date only. Verified two ways: pg_policies shows RLS on both tables with exactly the two policies this file creates ("anon can submit", INSERT only with no USING clause, and "authenticated full access", ALL using true), and a live read as the anon role returns 0 rows from both onboarding_submissions and doc_signatures. CAVEAT: the table-level SELECT grant to anon still exists. This file never revokes grants and that grant is the default on every public table, so protection rests on RLS plus the absence of an anon SELECT policy. Open follow-ups named in the file itself: the OAIC notifiable-data-breach assessment for the already-exposed records, and replacing anon read-back with a SECURITY DEFINER token function.'),
  ('2026-09-15-ndis-2026-27-non-sil-rates.sql',          '2026-09-18'::timestamptz, 'Claude Code session via MCP, operator-authorised',
   'UPDATE returned 2 rows (Abdi bl-legacy, Lita bl-1783273601383); re-running the migration''s own dry-run check afterwards reported 0 remaining changes.'),
  ('2026-09-18-schedule-block-split-times.sql',          '2026-09-18'::timestamptz, 'Claude Code session via MCP, operator-authorised',
   'Verified after the run: flat_start, flat_end, active_start, active_end all present on schedule_blocks as nullable time without time zone.'),
  ('2026-09-18-participants-pending-invoice-column.sql', '2026-09-18'::timestamptz, 'Claude Code session via MCP, operator-authorised',
   'Verified after the run: participants.pending_invoice present as nullable jsonb with its comment applied; both rows null, nothing to backfill.'),
  ('2026-09-18-migration-ledger.sql',                    now(),                     'operator',
   'This file. Records itself on the way in.')
on conflict (filename) do nothing;

commit;

-- ── NOTE ON 2026-09-14-lock-onboarding-tables.sql ───────────────────────────
-- It IS backfilled above, but it was the one file with no row in CLAUDE.md's
-- status table at all, so its state had to be established from the database
-- rather than read off the docs. Checked 2026-09-18, read-only:
--
--   select policyname, cmd, roles, qual, with_check
--     from pg_policies
--    where schemaname = 'public'
--      and tablename in ('onboarding_submissions', 'doc_signatures')
--    order by tablename, cmd;
--
-- Result matched the file statement for statement — RLS on, exactly its two
-- policies per table, no anon SELECT anywhere — and a live read as the anon
-- role returned 0 rows from both tables. The anon exposure it was written to
-- close is closed.
--
-- Residual, deliberately NOT changed here: anon still holds the table-level
-- SELECT grant on both (and on every other public table — it is the Supabase
-- default). Inert while RLS is on with no anon SELECT policy, but it means one
-- accidental policy is all that stands between those 18 rows and the public
-- internet. A `revoke select on public.<table> from anon` would make that
-- defence in depth. That is a decision for the operator, not a side effect of a
-- ledger migration.

-- ── VERIFY ──────────────────────────────────────────────────────────────────
-- select filename, applied_at::date, applied_by from public._migrations_applied
--  order by filename;   -- expect 18 rows: 17 backfilled plus this file itself
--
-- That is every file in migrations/ as at 2026-09-18, with none left out.
-- After adding any new migration, compare `ls migrations/` against this query;
-- a file with no row is unknown, not unapplied.

-- ── ROLLBACK ────────────────────────────────────────────────────────────────
-- drop table if exists public._migrations_applied;
