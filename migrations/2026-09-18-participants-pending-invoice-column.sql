-- Add the participants.pending_invoice column the app already writes.
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
--
-- WHY: the invoice-generation path has written this column since it was built
-- (~line 7228, sb2.from('participants').update({pending_invoice:pendingInv})),
-- and clears it at ~line 8429 — but the column was never created. Both writes
-- are fire-and-forget .then(...) calls whose error branch only skips the
-- local-state update, so PostgREST's 42703 never surfaced and the failure went
-- unnoticed. Confirmed 2026-09-13 by an anon probe: ?select=pending_invoice
-- returns "column does not exist" while every other participants column
-- (budget_lines, invoice_files, archived_at, roster) returns 200.
--
-- WHAT IT COSTS TODAY: session-scoped state still works, because pt.pending_invoice
-- is set in memory and rememberPendingGenInvoice / _lastGenInvoice hold the
-- invoices generated this session. What is lost is persistence across a reload:
-- generate an invoice, reload before attaching it, and the pending link is gone.
-- The readers at ~lines 7540 and 8278 just see nothing.
--
-- SCHEMA ONLY — no code change ships with this. The call sites already assume
-- the column exists and are deliberately untouched; this makes the database
-- match what they have always been sending.
--
-- TYPE: jsonb, nullable, no default. The app stores an invoice descriptor
-- object and treats absent and null alike, so there is nothing to backfill:
-- existing rows correctly mean "no pending invoice".
--
-- Nothing in the app executes this. Until it runs, behaviour is exactly what it
-- is now — the writes keep failing silently and pending state stays
-- session-only.

alter table public.participants
  add column if not exists pending_invoice jsonb;

comment on column public.participants.pending_invoice is
  'Invoice generated but not yet attached to the participant, persisted so the link survives a page reload. Written and cleared by the invoice-generation path in public/index.html; null means none pending.';
