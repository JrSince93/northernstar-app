-- Recurring expenses that aren't due every month (Expenses tab)
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
--
-- For a bill like OVO electricity, due once a quarter: interval_months = 3 with
-- tracked_since = the date of the most recent (or next) due bill. Due months
-- step out from that anchor, so an anchor of 2026-08-12 is due Aug, Nov, Feb,
-- May and silent in between — no card and no pending slot in the other months.
--
-- tracked_since with no interval (or interval 1) currently does nothing: the
-- due-month check returns early for monthly expenses. The field is stored but
-- unread in that case.
--
-- Nothing in the app executes this. Until it runs, saving an interval expense
-- retries without these columns and warns via a toast, and every recurring
-- expense behaves as monthly behind the S._intervalColsMissing flag.

alter table public.recurring_expenses
  add column if not exists interval_months int,
  add column if not exists tracked_since   date;

alter table public.recurring_expenses
  drop constraint if exists recurring_expenses_interval_months_check;
alter table public.recurring_expenses
  add constraint recurring_expenses_interval_months_check
  check (interval_months is null or interval_months between 2 and 12);

comment on column public.recurring_expenses.interval_months is
  'Months between due dates. Null or 1 = due every month. Phased from tracked_since.';
comment on column public.recurring_expenses.tracked_since is
  'Anchor date for interval_months — the most recent or next due bill. Without it an interval expense falls back to monthly.';
