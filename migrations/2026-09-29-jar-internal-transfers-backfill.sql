-- Backfill: reclassify Wise jar movements as internal transfers.
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
-- DATA-ONLY. No schema change. Run each step and read its output before the next.
--
-- WHY: jar moves shuffle money between two of our own Wise balances. Money INTO
-- a jar was imported as an ordinary expense ('Jar - X', 'Wise Transfer'), so
-- every sweep counted against Money Out; money OUT of a jar was dropped
-- entirely by the inbound importer (BALANCE_TO_BALANCE sits in internalTypesIn),
-- so it never reached the cash book at all. September therefore closed $2,390
-- below the real Wise balance.
--
-- AFTER THIS RUNS, with the matching index.html change deployed:
--   * these rows keep counting in the running balance and the opening/closing
--     carry (they are real movements of cash)
--   * they stop counting in Money In / Money Out, dashboard KPIs, the charts,
--     P&L, Tax & BAS, Accountant exports and the Expenses tab
--   * they render with a muted amount and an "Internal" tag in the cash book
--
-- ORDERING: the code tolerates BOTH the old 'WISE--nnnnnnn' and the new
-- 'WISE-nnnnnnn' reference formats in its duplicate check, so it does not
-- matter whether this SQL runs before or after the deploy. Re-running the Wise
-- import will not duplicate these rows either way.

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP A — SELECT the rows first. Confirm 10 rows and these exact ids before
-- running any UPDATE. Never update by filter alone.
-- ─────────────────────────────────────────────────────────────────────────────
select id, month, date, description, payment_type, reference, amount_in, amount_out
from transactions
where id in (
  '4fad7df0-3866-4263-b6ed-462cd0b0dd12',  -- 2026-08-04  Jar - Lita's Groceries   181.39
  '680ae5e1-012f-47ae-9f40-6fce02f1b7e5',  -- 2026-08-10  Jar - Lita's Groceries   125.00
  '8302a7b5-b471-4a89-91c3-b0923427b0c5',  -- 2026-08-17  Jar - Lita's Groceries   125.00
  '4d8e3c0d-fd48-4500-9b79-8866e6bfa6c5',  -- 2026-08-25  Jar - Lita's Groceries   125.00
  '4b53898c-f1ad-4dab-bbfd-cc0a9769009b',  -- 2026-08-30  Jar - AUD                125.00  ref WISE--5919661
  'a5b9b0d1-04f8-406f-b20d-2a408124beaf',  -- 2026-08-30  Jar - Side Account      2390.00
  '59adebc2-2afd-4acb-bde5-3ad431adea2b',  -- 2026-09-06  Jar - AUD                125.00  ref WISE--5942674
  '2cddcf8e-411f-4039-8ef3-a9fd97c8f034',  -- 2026-09-13  Jar - AUD                125.00  ref WISE--5979959
  'fbbc6107-e85d-420c-84d1-697536a89f92',  -- 2026-09-20  Jar - AUD                125.00  ref WISE--6012992
  '2ea80349-303e-4150-92c5-a56770b50db7'   -- 2026-09-27  Jar - AUD                125.00  ref WISE--6047008
)
order by date, reference;
-- Expect: 10 rows, all payment_type 'Wise Transfer', total amount_out 3571.39.

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP B — UPDATE those exact ids. Each statement names one id.
-- payment_type -> 'Internal Transfer', description -> plain language, and the
-- five double-dash references -> the corrected single-dash form.
--
-- NOTE ON THE FIVE 'AUD' ROWS: the Wise description is literally
-- "Moved 125.00 AUD to AUD" — the jar's real name is not in the payload at all.
-- Rather than write a description that reads like a currency conversion, these
-- become 'Transfer to [JAR NAME] (Jar)', matching WISE_DEFAULT_JAR_NAME in
-- index.html so future imports produce the identical wording. Substitute the
-- real jar name here and in that constant once it is known; nothing else
-- depends on the wording.
-- ─────────────────────────────────────────────────────────────────────────────
begin;

update transactions set payment_type='Internal Transfer',
       description='Transfer to Lita''s Groceries (Jar)'
 where id='4fad7df0-3866-4263-b6ed-462cd0b0dd12';

update transactions set payment_type='Internal Transfer',
       description='Transfer to Lita''s Groceries (Jar)'
 where id='680ae5e1-012f-47ae-9f40-6fce02f1b7e5';

update transactions set payment_type='Internal Transfer',
       description='Transfer to Lita''s Groceries (Jar)'
 where id='8302a7b5-b471-4a89-91c3-b0923427b0c5';

update transactions set payment_type='Internal Transfer',
       description='Transfer to Lita''s Groceries (Jar)'
 where id='4d8e3c0d-fd48-4500-9b79-8866e6bfa6c5';

update transactions set payment_type='Internal Transfer',
       description='Transfer to [JAR NAME] (Jar)',
       reference='WISE-5919661'
 where id='4b53898c-f1ad-4dab-bbfd-cc0a9769009b';

update transactions set payment_type='Internal Transfer',
       description='Transfer to Side Account (Jar)'
 where id='a5b9b0d1-04f8-406f-b20d-2a408124beaf';

update transactions set payment_type='Internal Transfer',
       description='Transfer to [JAR NAME] (Jar)',
       reference='WISE-5942674'
 where id='59adebc2-2afd-4acb-bde5-3ad431adea2b';

update transactions set payment_type='Internal Transfer',
       description='Transfer to [JAR NAME] (Jar)',
       reference='WISE-5979959'
 where id='2cddcf8e-411f-4039-8ef3-a9fd97c8f034';

update transactions set payment_type='Internal Transfer',
       description='Transfer to [JAR NAME] (Jar)',
       reference='WISE-6012992'
 where id='fbbc6107-e85d-420c-84d1-697536a89f92';

update transactions set payment_type='Internal Transfer',
       description='Transfer to [JAR NAME] (Jar)',
       reference='WISE-6047008'
 where id='2ea80349-303e-4150-92c5-a56770b50db7';

commit;
-- Expect: 10 rows updated (1 per statement).

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP C — the missing inbound. Guarded INSERT: the SELECT must return 0 rows
-- first. This is the $2,390 that came back OUT of the Side Account jar and was
-- never recorded — the other half of the 2026-08-30 outbound.
--
-- ⚠️ CHECK THE DATE BEFORE RUNNING. The importer assigns the UTC date from the
-- Wise payload (.slice(0,10)), so the stored date is the UTC one, not the
-- Melbourne one. 2026-09-20 below is the default. USE 2026-09-19 INSTEAD if the
-- Wise transaction time was before 10:00am AEST (i.e. before 00:00 UTC on the
-- 20th), because UTC was still the previous day at that moment. Either way the
-- month stays 'September', so none of the September figures below change.
-- ─────────────────────────────────────────────────────────────────────────────
select id, date, description, reference, amount_in
from transactions
where reference in ('WISE-07067382','WISE--07067382')
   or reference ilike '%6107067382%';
-- Expect: 0 rows. If anything comes back, STOP — the row already exists.

insert into transactions (month, date, description, payment_type, reference, amount_in, amount_out)
values ('September', '2026-09-20', 'Transfer from Side Account (Jar)',
        'Internal Transfer', 'WISE-07067382', 2390.00, 0);
-- Expect: 1 row inserted.

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP D — verify.
-- ─────────────────────────────────────────────────────────────────────────────
select id, month, date, description, payment_type, reference, amount_in, amount_out
from transactions
where payment_type = 'Internal Transfer'
order by date;
-- Expect: 11 rows — the 10 reclassified plus the new inbound.
-- Expect: no reference matching 'WISE--%' remains.

select
  round(sum(amount_in)  filter (where payment_type <> 'Internal Transfer'), 2) as sep_money_in,
  round(sum(amount_out) filter (where payment_type <> 'Internal Transfer'), 2) as sep_money_out,
  round(sum(amount_in) filter (where payment_type <> 'Internal Transfer')
      - sum(amount_out) filter (where payment_type <> 'Internal Transfer'), 2) as sep_net_operating
from transactions
where date between '2026-09-01' and '2026-09-30';
-- Expect: 22346.47 in, 22545.21 out, net -198.74.

select round(sum(amount_in) - sum(amount_out), 2) as sep_closing_balance
from transactions
where date >= '2026-01-01' and date <= '2026-09-30';
-- Expect: 8765.37 — matches the Wise statement for 1-29 Sep 2026.

select round(sum(amount_out) filter (where payment_type <> 'Internal Transfer'), 2) as aug_money_out,
       round(sum(amount_in) - sum(amount_out), 2) as aug_movement
from transactions
where date between '2026-08-01' and '2026-08-31';
-- Expect: 19281.98 money out (was 22353.37, down exactly 3071.39).
-- August's closing balance is unchanged at 7074.11 — internal transfers still
-- count in the balance, only in the operating totals do they disappear.

-- ─────────────────────────────────────────────────────────────────────────────
-- ROLLBACK (restores the pre-backfill state exactly)
-- ─────────────────────────────────────────────────────────────────────────────
-- begin;
-- delete from transactions where reference='WISE-07067382';
-- update transactions set payment_type='Wise Transfer', description='Jar - Lita''s Groceries' where id='4fad7df0-3866-4263-b6ed-462cd0b0dd12';
-- update transactions set payment_type='Wise Transfer', description='Jar - Lita''s Groceries' where id='680ae5e1-012f-47ae-9f40-6fce02f1b7e5';
-- update transactions set payment_type='Wise Transfer', description='Jar - Lita''s Groceries' where id='8302a7b5-b471-4a89-91c3-b0923427b0c5';
-- update transactions set payment_type='Wise Transfer', description='Jar - Lita''s Groceries' where id='4d8e3c0d-fd48-4500-9b79-8866e6bfa6c5';
-- update transactions set payment_type='Wise Transfer', description='Jar - AUD',          reference='WISE--5919661' where id='4b53898c-f1ad-4dab-bbfd-cc0a9769009b';
-- update transactions set payment_type='Wise Transfer', description='Jar - Side Account'                            where id='a5b9b0d1-04f8-406f-b20d-2a408124beaf';
-- update transactions set payment_type='Wise Transfer', description='Jar - AUD',          reference='WISE--5942674' where id='59adebc2-2afd-4acb-bde5-3ad431adea2b';
-- update transactions set payment_type='Wise Transfer', description='Jar - AUD',          reference='WISE--5979959' where id='2cddcf8e-411f-4039-8ef3-a9fd97c8f034';
-- update transactions set payment_type='Wise Transfer', description='Jar - AUD',          reference='WISE--6012992' where id='fbbc6107-e85d-420c-84d1-697536a89f92';
-- update transactions set payment_type='Wise Transfer', description='Jar - AUD',          reference='WISE--6047008' where id='2ea80349-303e-4150-92c5-a56770b50db7';
-- commit;
