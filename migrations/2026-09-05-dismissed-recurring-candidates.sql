-- Dismissed "Suggested recurring expenses" candidates (Expenses tab)
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
--
-- Companion to 2026-09-04-expense-tracker.sql. detectRecurringCandidates()
-- suggests cash book expenses that repeat across 2+ months; dismissing one
-- stores its signature here so it does not come back.
--
-- Signature format: '<normalised label>|<amount to 2dp>'. It is compared with
-- the same loose label/amount helpers the auto-matcher uses (expLooseMatch +
-- expAmountMatches, 5% tolerance) rather than by string equality, so a later
-- month nudging the group's average by a few cents cannot resurrect a
-- dismissal.
--
-- Nothing in the app executes this. Until it runs the Expenses tab still works:
-- suggestions render as normal and only the Dismiss button is disabled, via the
-- S._dismissedCandTableMissing degradation flag set in loadAll().

create table if not exists public.dismissed_recurring_candidates (
  id         uuid primary key default gen_random_uuid(),
  signature  text not null,
  created_at timestamptz not null default now()
);

create index if not exists drc_signature_idx
  on public.dismissed_recurring_candidates (signature);

comment on table public.dismissed_recurring_candidates is
  'Suggested recurring expenses the operator dismissed. signature is "<normalised label>|<amount to 2dp>", compared with the same loose label/amount rules as the auto-matcher. Read only by the Expenses tab.';
