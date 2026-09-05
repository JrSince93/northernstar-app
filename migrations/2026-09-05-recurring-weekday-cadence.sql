-- Weekday-based cadence for recurring expenses (Expenses tab)
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
--
-- Companion to 2026-09-05-recurring-multi-occurrence.sql — run that one first,
-- since the expected occurrences still materialise as one instance per
-- occurrence_number.
--
-- When cadence_weekday is set, the expected number of occurrences in a month is
-- the real count of that weekday in that calendar month, overriding
-- occurrences_per_month. September 2026 has 4 Mondays, November 2026 has 5;
-- that difference is the point of the column.
--
-- Nothing in the app executes this. Until it runs, expCadenceWeekday() returns
-- null behind the S._cadenceColMissing flag, saving a weekday cadence retries
-- without the column and warns via a toast, and the tab behaves as if every
-- recurring expense were a flat count.

alter table public.recurring_expenses
  add column if not exists cadence_weekday int;

alter table public.recurring_expenses
  drop constraint if exists recurring_expenses_cadence_weekday_check;
alter table public.recurring_expenses
  add constraint recurring_expenses_cadence_weekday_check
  check (cadence_weekday is null or cadence_weekday between 0 and 6);

comment on column public.recurring_expenses.cadence_weekday is
  '0=Sunday..6=Saturday. When set, the expected occurrences for a month is the actual count of that weekday in that calendar month, overriding occurrences_per_month. Null means use occurrences_per_month.';
