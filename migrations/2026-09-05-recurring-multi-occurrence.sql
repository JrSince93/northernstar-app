-- Recurring expenses charged several times a month (Expenses tab)
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
--
-- Lets one recurring expense carry N slots per month instead of one, so a bill
-- charged (say) four times a month gets four instances, each matched to its own
-- cash book payment in date order.
--
-- BEFORE RUNNING: confirm the existing unique constraint's real name with
--   \d public.recurring_expense_instances
-- The DROP below uses Postgres's default name for a `unique (recurring_expense_id,
-- month)` declared inline at CREATE TABLE time. If yours differs, the DROP
-- silently does nothing and the ADD then fails against the old constraint.
--
-- Nothing in the app executes this. Until it runs the tab degrades to one
-- occurrence a month: expOccurrences() returns 1 while S._occurrenceColsMissing
-- is set, and the "Charged how many times a month?" field saves as 1 with a
-- toast explaining why.

-- 1. How many times a month the expense is charged
alter table public.recurring_expenses
  add column if not exists occurrences_per_month int not null default 1;

alter table public.recurring_expenses
  drop constraint if exists recurring_expenses_occurrences_per_month_check;
alter table public.recurring_expenses
  add constraint recurring_expenses_occurrences_per_month_check
  check (occurrences_per_month between 1 and 31);

-- 2. Which of that month's occurrences an instance represents (1..N)
alter table public.recurring_expense_instances
  add column if not exists occurrence_number int not null default 1;

-- 3. Uniqueness moves from one-per-month to one-per-occurrence
alter table public.recurring_expense_instances
  drop constraint if exists recurring_expense_instances_recurring_expense_id_month_key;
alter table public.recurring_expense_instances
  add constraint recurring_expense_instances_re_month_occ_key
  unique (recurring_expense_id, month, occurrence_number);

comment on column public.recurring_expenses.occurrences_per_month is
  'How many separate payments this expense is expected to produce each month (1-31). Drives how many instances ensureRecurringInstances() creates.';
comment on column public.recurring_expense_instances.occurrence_number is
  'Which occurrence within the month this row is, 1..occurrences_per_month. The auto-matcher fills them in transaction date order, earliest first.';
