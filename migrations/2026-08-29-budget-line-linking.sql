-- Direct budget-line linking for invoice payments
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
--
-- Why: attributeReceiptsToLines() currently matches a paid receipt to a budget
-- line purely by string-matching transactions.reference against BL_INV_PREFIXES.
-- A single mistyped/truncated invoice_ref at entry time silently sends the
-- payment to "Unattributed" in Reports. These columns carry the budget line's
-- identity end to end (invoice generation -> ledger -> cash book) so attribution
-- no longer depends on text at all for anything the app generates.
--
-- All columns are nullable: existing rows keep working via the prefix-matching
-- fallback, and the app tolerates these columns not existing yet.

alter table public.invoice_ledger
  add column if not exists budget_line_id text,
  add column if not exists rate_card      text;

alter table public.transactions
  add column if not exists budget_line_id text;

-- Attribution reads these per participant; the partial indexes keep the lookup
-- cheap without bloating the (mostly null) historical rows.
create index if not exists invoice_ledger_budget_line_id_idx
  on public.invoice_ledger (budget_line_id)
  where budget_line_id is not null;

create index if not exists transactions_budget_line_id_idx
  on public.transactions (budget_line_id)
  where budget_line_id is not null;

comment on column public.invoice_ledger.budget_line_id is
  'participants.budget_lines[].id this invoice was generated from. Null for manual/legacy entries, which fall back to BL_INV_PREFIXES matching on invoice_ref.';
comment on column public.invoice_ledger.rate_card is
  'Snapshot of the budget line rate_card (sil/core/core_combined/employment/community/custom) at generation time. Disambiguates core_combined merges; not used for matching.';
comment on column public.transactions.budget_line_id is
  'Copied from invoice_ledger.budget_line_id when the invoice is marked paid. Lets attributeReceiptsToLines() attribute without parsing reference.';
