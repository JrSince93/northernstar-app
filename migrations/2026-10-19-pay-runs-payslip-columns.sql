-- 2026-10-19-pay-runs-payslip-columns.sql
--
-- WHY
-- When a pay run becomes paid, the app will save a PDF of its payslip to the
-- private `payslips` Storage bucket (created by the NEXT migration,
-- 2026-10-19-payslips-bucket.sql). The PDF is the permanent record of what the
-- worker was paid. These columns record where that file is and when it was
-- saved, so the Payroll tab can show "download" instead of "save", and so the
-- Hermes agent (Ryan) can later find files to upload to Connecteam.
--
-- WHAT
-- 1. pay_runs.payslip_path         text, nullable. Object path inside the
--    `payslips` bucket, e.g. '{employee_id}/{period_end}_{pay_run_id}.pdf'.
--    Path only, never a URL; downloads mint 5-minute signed URLs.
-- 2. pay_runs.payslip_saved_at     timestamptz, nullable. When the app saved it.
-- 3. pay_runs.payslip_regenerated  boolean NOT NULL default false. true = the
--    file was produced later by a backfill from current code, not at the moment
--    the run was paid. Nothing sets it in this build; it exists so the backfill
--    (a separate, approved step) can mark its files.
--
-- No backfill: every existing row gets payslip_path/payslip_saved_at NULL
-- ("no file yet") and payslip_regenerated false. Adding a NOT NULL column with
-- a constant default is a metadata-only change in Postgres 11+, no table rewrite.
--
-- RLS: unchanged. The existing pay_runs policies (admin all; office_manager all
-- except restricted employees; accountant read) already cover these columns, so
-- the accountant can see them but cannot write them.
--
-- SCOPE: read/written only by the payslip save/download code in
-- public/index.html. No payroll calculation, Cash Book, Dashboard or invoice
-- code reads them.
--
-- SAFE TO RE-RUN: `add column if not exists`.

begin;

alter table public.pay_runs
  add column if not exists payslip_path        text,
  add column if not exists payslip_saved_at    timestamptz,
  add column if not exists payslip_regenerated boolean not null default false;

comment on column public.pay_runs.payslip_path is
  'Object path of this run''s payslip PDF in the private `payslips` bucket ({employee_id}/{period_end}_{pay_run_id}.pdf). Path only, never a URL. NULL = not saved yet.';
comment on column public.pay_runs.payslip_saved_at is
  'When the payslip PDF was saved to Storage. NULL = not saved yet.';
comment on column public.pay_runs.payslip_regenerated is
  'true = PDF produced later by a backfill from current code (file name carries a _regen suffix), not saved at the time the run was paid.';

insert into public._migrations_applied (filename, applied_by, notes)
values ('2026-10-19-pay-runs-payslip-columns.sql',
        'Claude Code via Supabase MCP, operator-authorised',
        'Added pay_runs.payslip_path, payslip_saved_at, payslip_regenerated.')
on conflict (filename) do nothing;

commit;

-- VERIFY (expected: 3 rows; text/YES, timestamp with time zone/YES, boolean/NO/false)
-- select column_name, data_type, is_nullable, column_default
--   from information_schema.columns
--  where table_schema='public' and table_name='pay_runs'
--    and column_name in ('payslip_path','payslip_saved_at','payslip_regenerated')
--  order by column_name;
-- select count(*) filter (where payslip_path is not null) as with_path,
--        count(*) filter (where payslip_regenerated) as regenerated
--   from public.pay_runs;   -- expected 0, 0
--
-- ROLLBACK (only before any payslip has been saved)
-- alter table public.pay_runs
--   drop column if exists payslip_path,
--   drop column if exists payslip_saved_at,
--   drop column if exists payslip_regenerated;
-- delete from public._migrations_applied where filename = '2026-10-19-pay-runs-payslip-columns.sql';
