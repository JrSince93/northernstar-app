-- Expense Tracker: participant/company allocation + recurring expense tracking
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
-- Nothing in the app executes this. All columns are nullable and every read
-- degrades gracefully, so the app works before and after this runs.

-- 1. Allocation columns on the existing cash book table
alter table public.transactions
  add column if not exists allocated_to  text,
  add column if not exists participant_id uuid references public.participants(id);

alter table public.transactions
  drop constraint if exists transactions_allocated_to_check;
alter table public.transactions
  add constraint transactions_allocated_to_check
  check (allocated_to is null or allocated_to in ('participant','company'));

create index if not exists transactions_allocated_to_idx
  on public.transactions (allocated_to)
  where allocated_to is not null;
create index if not exists transactions_participant_id_idx
  on public.transactions (participant_id)
  where participant_id is not null;

-- 2. Recurring expense definitions (rent, phone, internet, ...)
create table if not exists public.recurring_expenses (
  id                     uuid primary key default gen_random_uuid(),
  label                  text not null,
  default_allocated_to   text check (default_allocated_to is null or default_allocated_to in ('participant','company')),
  default_participant_id uuid references public.participants(id),
  expected_amount        numeric(12,2),
  expected_day_of_month  int check (expected_day_of_month is null or expected_day_of_month between 1 and 31),
  active                 boolean not null default true,
  created_at             timestamptz not null default now()
);

-- 3. One row per recurring expense per month, carrying that month's status
create table if not exists public.recurring_expense_instances (
  id                    uuid primary key default gen_random_uuid(),
  recurring_expense_id  uuid not null references public.recurring_expenses(id) on delete cascade,
  month                 text not null,                     -- 'YYYY-MM'
  transaction_id        uuid references public.transactions(id) on delete set null,
  status                text not null default 'pending' check (status in ('pending','paid')),
  created_at            timestamptz not null default now(),
  unique (recurring_expense_id, month)
);

create index if not exists rei_month_idx on public.recurring_expense_instances (month);
create index if not exists rei_transaction_idx
  on public.recurring_expense_instances (transaction_id)
  where transaction_id is not null;

comment on table public.recurring_expenses is
  'Recurring monthly expenses tracked on the Expenses tab. Isolated from Dashboard KPIs and Cash Book totals.';
comment on table public.recurring_expense_instances is
  'Per-month payment status for a recurring expense. transaction_id links the cash book row that paid it.';
comment on column public.transactions.allocated_to is
  'Expense allocation: participant | company | null (unallocated). Read only by the Expenses tab.';
