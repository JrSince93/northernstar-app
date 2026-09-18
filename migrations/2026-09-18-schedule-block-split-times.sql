-- Persist the flat/active clock times entered on a sleepover shift block.
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
--
-- WHY: saveScheduleBlock() stored only the derived durations, flat_hours and
-- active_hours. openScheduleBlockForm() therefore had to rebuild the four time
-- inputs on every reopen by inferring them from the block's outer start_time /
-- end_time plus those hours — flat anchored to the shift start, active anchored
-- to the shift end. Any split that did not sit exactly against those outer
-- bounds (say a 22:00-06:00 shift whose active window is 01:00-02:00) was
-- silently rewritten the next time the form opened. The durations survived; the
-- actual window did not.
--
-- AFTER THIS RUNS: the entered times round-trip verbatim. flat_hours and
-- active_hours keep their current meaning and are still computed by
-- syncFlatActiveSplitFromInputs(), because resolveBlockRate(), the shift-card
-- summary and the pay-run split all read those — this migration adds detail
-- beside them, it does not replace them.
--
-- TYPE: `time` to match schedule_blocks.start_time / end_time, which are
-- already `time without time zone`. Nullable, no default: null means "never
-- entered" and is exactly what makes the app fall back to the old inference.
--
-- BEFORE IT RUNS, nothing breaks. saveScheduleBlock() upserts through
-- upsertScheduleBlockWithColumnFallback(), which strips any column PostgREST
-- reports as unknown (PGRST204 "Could not find the '<col>' column of
-- 'schedule_blocks'") and retries, so the shift still saves with its hours and
-- the operator gets a toast naming the missing columns. Blocks written that way
-- keep null times and keep rendering from the inference path.
--
-- BACKFILL: deliberately none. The pre-existing rows' true windows were never
-- recorded, so any backfill would just persist the same guess the inference
-- already makes at render time — but as though it were operator-entered data.
-- Leaving them null keeps "we don't know" honest and reversible.

alter table public.schedule_blocks
  add column if not exists flat_start   time,
  add column if not exists flat_end     time,
  add column if not exists active_start time,
  add column if not exists active_end   time;

comment on column public.schedule_blocks.flat_start is
  'Start of the flat (inactive/sleepover) window, as entered in the shift form. Null for blocks saved before 2026-09-18, which fall back to inference from start_time + flat_hours.';
comment on column public.schedule_blocks.flat_end is
  'End of the flat (inactive/sleepover) window, as entered in the shift form. Null means infer.';
comment on column public.schedule_blocks.active_start is
  'Start of the active-support window within the shift, as entered in the shift form. Null means infer.';
comment on column public.schedule_blocks.active_end is
  'End of the active-support window within the shift, as entered in the shift form. Null means infer.';
