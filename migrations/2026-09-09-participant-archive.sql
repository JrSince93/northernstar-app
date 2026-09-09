-- Archive a participant without deleting their history
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
--
-- Archiving is a non-destructive alternative to Delete. Setting archived_at
-- does two things and nothing else:
--   1. removes the participant from the NDIS Budget Tracker aggregate and its
--      per-participant rows in Reports;
--   2. collapses their Participants-tab card to a read-only row showing name,
--      archive date and total invoiced.
--
-- No transaction, invoice, budget line or receipt is altered. Unarchiving is
-- setting the column back to null, and everything returns.
--
-- Note archiving is NOT a guard against new activity: an archived participant
-- still appears in invoice generation and in the Expenses allocation pickers,
-- deliberately, so past spend can still be attributed to someone who has left.
--
-- Nothing in the app executes this. Until it runs, the Archive button fails
-- with a toast pointing here and the participant is left untouched.

alter table public.participants
  add column if not exists archived_at timestamptz;

comment on column public.participants.archived_at is
  'When set, the participant is excluded from the NDIS Budget Tracker aggregate and collapses to a read-only card on the Participants tab. Purely a display flag — no history is altered.';
