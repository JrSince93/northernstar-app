# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this app is

Northern Star Support Services — a private financial operations dashboard for an Australian NDIS (National Disability Insurance Scheme) disability support provider (Falaax Group Pty Ltd, ABN 22 671 393 070, Melbourne). It manages cash book entries, employee payroll (PAYG + superannuation + SCHADS sleepover rules), NDIS participant records with multi-budget-line plans and budget tracking, weekly schedule blocks, Connecteam timesheet Excel import, NDIS invoice generation (PDF + NDIA myplace bulk-payment CSV), expense allocation and recurring-expense tracking, and Wise banking reconciliation.

## Architecture

This is a **zero-build, single-file SPA** deployed on Netlify:

- `public/index.html` — The entire application: ~9,900 lines of HTML + CSS + vanilla JS in one file. No framework, no bundler, no npm.
- `netlify/functions/wise.js` — A serverless function that proxies authenticated requests to `api.wise.com` (keeps `WISE_API_TOKEN` off the client). Allowed path prefixes: `v1/profiles`, `v3/profiles`, `v4/profiles`, `v1/borderless-accounts`. The `path` query param is passed through verbatim (may include its own query string). Add `?debug=1` to dump the first response item to Netlify function logs.
- `netlify.toml` — Publishes `public/`, serves functions from `netlify/functions/`.
- `public/robots.txt` — `Disallow: /` (site is private; noindex).
- `migrations/*.sql` — Schema changes, run **manually** in the Supabase SQL editor. Nothing in the app executes them; every migration is written so the app degrades gracefully before it runs. Named `YYYY-MM-DD-description.sql`.

External libs are CDN-loaded: **Chart.js 4.4.1**, **@supabase/supabase-js@2**, and **SheetJS (xlsx) 0.18.5** (used by the Excel timesheet importer). pdf.js has been removed — the importer no longer reads PDFs.

The root also holds `*.md` build/fix prompt files — Claude Code work orders. Check whether each has already been applied to `index.html` before re-doing it (several already are; see "Status of build docs" below).

**These files are untracked by git** (only `CLAUDE.md`, `netlify.toml`, `netlify/functions/wise.js`, `public/*` and `migrations/*.sql` are tracked). Deleting one is unrecoverable — there is no commit to restore it from, and a spec has been lost this way before. Never delete a work order after applying it; leave it in place and record its status below.

## Running locally

Open `public/index.html` directly in a browser, or serve it with any static file server:

```bash
npx serve public
# or
python3 -m http.server 8080 --directory public
```

The Wise serverless function requires Netlify CLI for local testing:

```bash
npm install -g netlify-cli
WISE_API_TOKEN=<token> netlify dev
```

There is no build step, no `npm install`, no test suite.

## Deployment

Push to `main`. Netlify auto-deploys — `public/` is the publish directory. Live at northernstarcontrolcenter.netlify.app. The Wise API token must be set as a Netlify environment variable: `WISE_API_TOKEN`.

## Backend: Supabase

All data lives in Supabase (project `bhqjsqwbsbhjuhjwxwcp`). The anon key and project URL are embedded as `SURL`/`SKEY` (~line 996). The Supabase client is `sb2`.

**Tables:**
- `transactions` — cash book. Also carries `allocated_to` (`participant` | `company` | null) and `participant_id`, both **read only by the Expenses tab**.
- `employees`
- `pay_runs` — has `status` and `wise_status` fields; new runs insert with `status:'processed'`, `wise_status:'pending'`
- `participants` — includes `ndis_plan` (JSONB, legacy single-plan overrides) and `budget_lines` (JSONB array, current multi-line model). Save code degrades gracefully if those columns are missing.
- `dropdown_options`
- `invoice_ledger` — includes `wise_transfer_id` for payment matching
- `schedule_blocks` — the current weekly-schedule model: `participant_id`, `start_time`, `end_time`, `shift_kind`, `days_of_week`, `tolerance_mins`, `rate_mode`, `hourly_rate_source`, `manual_hourly_rate`, `flat_rate_source`, `manual_flat_rate`, `flat_hours`, `assigned_employee_ids`, `active`
- `shift_types` — **legacy**, superseded by `schedule_blocks`. Still loaded for old payslip compatibility; do not build new features on it.
- `timesheet_name_map` — maps Connecteam employee/participant name strings to app records
- `recurring_expenses` — recurring monthly expense definitions (label, expected amount, expected day of month, default allocation). Expenses tab only.
- `recurring_expense_instances` — one row per recurring expense per month (`month` is `'YYYY-MM'`), with `status` (`pending`/`paid`) and the `transaction_id` that paid it. Unique on `(recurring_expense_id, month)`. Expenses tab only.
- `dismissed_recurring_candidates` — signatures of suggested recurring expenses the operator dismissed. **Not yet created** — see Pending work.

`loadAll()` (~line 1200) fetches all tables on startup and populates `S`. The timesheet and expense tables load with graceful degradation (missing-table flags `S._scheduleBlocksTableMissing`, `S._recurringTableMissing`, `S._recurringInstTableMissing`, `S._dismissedCandTableMissing`) if their SQL hasn't run.

**Storage:** Supabase Storage bucket `invoices` for uploaded invoice PDFs.

**Auth:** Supabase Auth email/password (`sb2.auth.signInWithPassword` in `doLogin`, ~line 5444) with a client-side lockout mechanism (`getLockoutState` / `setLockoutState` — 3 failed attempts → 15-minute lockout). The old hardcoded gate `APP_PW` (~line 3142) is **deprecated, kept only for rollback safety — remove once new auth is verified live**. Still pending: creating the admin Supabase Auth user (Phase 2) and RLS lockdown SQL (Phase 3).

## Global state object `S`

All in-memory application state is on the global `S` object (~line 1027):

```
S = { tx, emps, runs, participants, dd, curMonth, editEmpId, ddField, ddTargetId,
      ch, wiseTransfers, invoiceLedger, _lastGenInvoice,
      shiftTypes, scheduleBlocks, tsNameMap,
      recurringExpenses, recurringInstances, dismissedCandidates }
```

The `ch` sub-object holds Chart.js instances keyed by canvas ID; use `dkc(id)` to destroy before re-rendering.

## Navigation

`nav(page)` switches views by toggling `.active` on `#page-<name>` divs. Pages: `dashboard`, `cashbook`, `employees`, `payroll`, `tax`, `reports`, `invoices`, `participants`, `expenses`.

## Domain constants (~lines 1000–1027)

- `getSuperRate(periodEnd)` — Superannuation Guarantee: **11.5% for periods ending before 1 Jul 2026, 12% from 1 Jul 2026**. The legacy `SUPER_RATE = 0.115` constant still exists but must not be used where the period is known.
- `NDIS_SLEEPOVER_SHIFT_RATE = 297.60` — flat rate per inactive overnight shift (PAPL, MMM 1-5). Named constant — do NOT hardcode.
- `NDIS_SLEEPOVER_ACTIVE_INCLUDED_HRS = 2` — active hours included in the flat rate before overflow billing.
- `NDIS_SLEEPOVER_CODES` — per-budget-line-type sleepover item codes (`sil: '01_820_0138_1_1'`, core/others `01_020_0107_1_1`). Marked as placeholders — verify against the current NDIS Support Catalogue before submitting claims.
- `SCHADS_SLEEPOVER_ALLOWANCE = 58.69` — SCHADS flat allowance per overnight shift (payroll side).
- `SCHADS_SLEEPOVER_ACTIVE_MIN_HRS = 1` — minimum active-work overtime hours per sleepover.
- `WISE_PROFILE_ID = 87229043`, `WISE_FN_URL = '/.netlify/functions/wise'`.
- `VIC_HOLIDAYS` — Victorian public holidays 2025–early 2028; detection via `checkPeriodHolidays`.

## NDIS pricing model

Per-budget-line rate tables live in the `RATE_CARDS` table (~line 5652). Each participant's `budget_lines` array carries its own type (`core`, `sil`, `community`, `employment`, `custom`), management mode, funding, and optional rate overrides.

**SIL uses registration group 0138 (replaced 0115 from 1 Jul 2026), on the NDIS 2026-27 Pricing Schedule** — already updated in code:

| day_type | code | rate |
|---|---|---|
| weekday | `01_801_0138_1_1` | $73.58 |
| evening | `01_802_0138_1_1` | $81.07 |
| night | `01_803_0138_1_1` | $82.57 |
| saturday | `01_804_0138_1_1` | $103.54 |
| sunday | `01_805_0138_1_1` | $133.50 |
| public_holiday | `01_806_0138_1_1` | $163.46 |
| sleepover | `01_832_0138_1_1` | $311.79 **per shift (unit "Each"), not per hour** |
| travel_km | `01_799_0138_1_1` | $1.00/km |

Employment support (Finding & Keeping a Job): `10_016_0102_5_3` @ $80.06/hr; travel `10_799_0102_5_3` @ $0.99/km.

Never invent rate-suffix item codes like `_S`/`_U` — use real PAPL item codes only. SIL is billed to the NDIA via myplace bulk CSV; plan-managed lines are invoiced to the plan manager as PDFs.

**Out of scope for invoicing/service agreements (never itemise):** Support Coordination, Plan Management, Behaviour Support, Psychosocial Recovery Coaching, Consumables, Assistive Technology.

## Budget tracking

Two funding-tracking modes per budget line:

1. **Quarterly (default)** — funding split into calendar quarters from plan start to plan end, with per-quarter overrides (`ndis_plan.quarter_overrides`) and rollover math. Receipts come from paid `invoice_ledger` rows and cash-book NDIS Payment transactions (deduped by invoice ref).
2. **Monthly funding schedule** — a budget line opts in by carrying `funding_schedule` rows (`{start, end, amount}` array) plus optional `funding_opening_balance_override`. Built for Lita's SIL Stated support (17th-to-16th monthly cycle with explicit rollover). The entry UI warns if rows don't sum to the total funding amount. The quarterly path is untouched for lines without a schedule.

## Timesheet importer (Connecteam Excel)

Entry: "Import timesheets" button on the Participants page → modal (`openTsImport`, ~line 8307). Takes a **single `.xlsx` covering all employees for the fortnight** (sheet `All Employees`, filename `NSS_TIMESHEETS_YYYY-MM-DD_YYYY-MM-DD.xlsx`). This replaced the old per-employee PDF importer — pdf.js is gone. Pipeline:

- `xlParseRows(rows, fileName)` (~line 4881) — parses the sheet's array-of-arrays into one result per employee block. The browser wrapper reads the file via `XLSX.read` and guards on `typeof XLSX==='undefined'`.
- `ctMidnightMerge(rawShifts)` — merges overnight pairs (e.g. 21:00→00:00 + 00:00→06:00) into single shifts.
- `ctMatchShiftType(shift, participantId)` (~line 5081) — matches against **`schedule_blocks`** (day-of-week aware: a block not scheduled on the shift's actual weekday is never a candidate), scoring on time-window + tolerance with ±1440-min overnight handling. `shift_types` is legacy.
- `ctEnrichResults` / `ctRematchShiftTypes` — enrich parsed shifts with employee match (via `timesheet_name_map`), participant match, shift kind. Sleepover matches default `activeMins` to the SCHADS 1-hour floor, editable per shift in Stage 2 review.
- Imported sleepovers must price as **flat allowance + active hours** (same split as manual pay runs via `resolveSleepoverFlatRate`), never as plain hourly.

## Payroll

- `paygCalc(annualisedGross)` — ATO tax tables for PAYG withholding.
- Pay calculation (`calcPay`-style logic ~line 1900+) handles weekday/Sat/Sun/PH hours, sleepover shifts (flat allowance × shifts + active OT), and super via `getSuperRate(periodEnd)`.
- Pay run lifecycle: insert with `status:'processed'`, `wise_status:'pending'`; `syncPayRunWiseStatuses` advances `wise_status` when the matching Wise transfer settles; `reconcilePendingPayroll` writes settled runs into the cash book (pending runs land with `amount_out=0`), skipping Wise transfers already used in a prior reconciliation.
- Payslips: `genPayslip(id)`.

## Wise integration

Client-side functions: `fetchWiseBalance`, `fetchWiseTransfers`, `syncPayRunWiseStatuses`, `reconcilePendingPayroll`, `autoImportWiseExpenses`, `autoImportWiseIncome`, `checkWiseForInvoices`.

- `checkWiseForInvoices` matches inbound Wise payments to `invoice_ledger` rows and stores `wise_transfer_id` to prevent double-matching.
- `autoImportWiseExpenses` / `autoImportWiseIncome` import Wise activity into the cash book with a `skipped` counter breakdown (payroll, already-in-cashbook, fees/conversions, incomplete, opening balances, internal jar moves, etc.).

## Invoice generation

Single **Generate** button in `#m-ndis-inv` opens an inline choice (`#ndis-inv-gen-choice`): **PDF** (`genNDISInvoice`, ~line 6505), **CSV** (`genMyPlaceCSV`, ~line 6640), or **Both**. Line items build per budget line/rate card; sleepovers emit with qty = number of shifts. Note: per-line rounding in the PDF can differ by cents from NDIA's raw CSV maths — NDIA pays from the CSV figures.

## Expenses tab (expense tracker)

All of it lives in one block at the end of the script (~line 9148+), behind an `exp*` / `renderExp*` naming prefix. Schema: `migrations/2026-09-04-expense-tracker.sql`.

**Isolation is the design constraint.** Allocation and recurring-expense data are read *only* on this tab. Nothing here feeds Dashboard KPIs, charts, Cash Book totals, invoicing or payroll. Before adding anything to this block, confirm no shared render path calls into it — the only entry points are `nav('expenses')` and the tab's own "Re-check matches" button.

**Payroll never appears on this tab**, in any list, ever — it stays on the Payroll tab. `expIsPayroll(tx)` detects it (reference starting `PAYROLL-`, which covers both the `PAYROLL-PENDING-<runid>` placeholder from `savePayRun` and the reconciled `PAYROLL-<runid>` row, or a `Payroll - <name>` description; matched case-insensitively). Every transaction list goes through the single gate `expIsTrackable(tx)` = `expIsExpense(tx) && !expIsPayroll(tx)` — use it, don't call `expIsExpense` directly.

Three sections, top to bottom:

1. **Suggested recurring expenses** — `detectRecurringCandidates()` scans all of `S.tx` for expenses repeating across **2+ distinct months** (`EXP_CANDIDATE_MIN_MONTHS`), excluding payroll, anything already covered by an active `recurring_expenses` row, and dismissed signatures. Accepting one pre-fills the Mark as Recurring modal and **back-fills `recurring_expense_instances` for every month seen** as `paid` with that month's transaction linked, so the history strip isn't empty on day one. Dismissals persist a `"<normalised label>|<amount>"` signature, compared with the loose helpers rather than string equality so a later month shifting the average by a few cents can't resurrect one.
2. **Recurring expenses** — one card per active definition, showing this month's paid/pending status, the linked transaction, a 6-month history strip, and manual match/unlink.
3. **Unallocated transactions** — this month's unallocated expenses; right-click or the "Allocate ▾" button assigns to a participant or the company, or marks it recurring.

**Matching rules are shared on purpose.** `expLooseMatch(desc, label)` (substring either way, else 60%+ of the label's significant tokens present) and `expAmountMatches(amt, expected)` (within `EXP_MATCH_TOLERANCE`, 5%) are used by candidate detection, dismissal comparison, and `autoMatchRecurringInstances` alike, so a suggestion accepted today is matched by the auto-matcher next month on identical terms. Change them in one place or not at all.

An instance's `month` always derives from its **transaction's date** (`expTxMonthKey`), never the tab's selected month — the back-fill depends on this.

## Key conventions

- Vanilla JS only, all in one file, no build step.
- `eid(id)` = `document.getElementById(id)`; `fmt(n)` formats AUD; `tod()` returns today as `YYYY-MM-DD`; `fmtDate(d)` returns `YYYY-MM-DD`.
- Toasts: `showToast(msg, 'ok'|'err')`. Modals: `openXModal()` / `closeM('m-xxx')`. Sync indicator: `setSync('ok'|'saving'|'error')`.
- Transaction refs auto-increment via `REF_PREFIXES` (~line 1098) / `getNextRef(description)`; `[recurring]` tag flags recurring entries.
- Invisible Unicode in NDIS numbers/ABNs handled by `stripInvisibles` / `hasInvisibles` / `cleanupInvisibleChars()`.
- `#m-participant` modal width is `min(1100px, calc(100vw - 40px))` so the 7-day schedule grid (`min-width:980px`) fits without inner scrolling on desktop.

## Company & participant reference

- **Falaax Group Pty Ltd** t/a Northern Star Support Services — ABN 22 671 393 070, 12 Dimboola Rd Broadmeadows VIC 3064, 03 7057 1645, Admin@NorthernStarSupport.com. Wise BSB 774-001, account 243610957.
- **Abdi Hussein Siyad** — NDIS 431576794, plan 06/03/2026–05/03/2028, Core Flexible agency-managed; plan manager Rebecca at Capital Guardians (**Abdi only — never assume she covers other participants**).
- **Lita Lee McKenzie** — NDIS 430926284 (`participant_id 9cc220cd-113c-44a7-b401-e04506155ff6`), plan Feb 2026–Feb 2027, NSS takeover **02/07/2026**. Three budget lines: SIL agency-managed (0138, billed via myplace, monthly funding schedule totalling $207,947.82), Core Flexible plan-managed, Employment Support 0102 plan-managed. Her plan manager identity is still unconfirmed.

## Status of build docs in this repo

Applied to `index.html` already (verify, don't redo): `fix-sil-0138-pricing.md`, `fix-merge-invoice-generate-buttons.md`, `fix-participant-modal-width.md`, `build-monthly-funding-schedule-tracker.md`, `phase5-timesheet-importer-schedule-blocks.md` (matcher now uses `schedule_blocks` with day-of-week awareness), `excel-timesheet-importer-build-prompt.md` (the PDF importer is fully replaced — SheetJS is loaded, pdf.js is gone).

**Not yet applied:**
- `fix-receipt-bucketing-by-period.md` — not applied; `parsePeriodEndFromRef` and `bucket_date` do not exist in the code, and `collectNDISReceiptsForParticipant` (~line 2466) still sets each receipt's `date` to `payment_date || invoice_date` for `bucketReceiptsByQuarter` (~line 2525) to place.

  **Latent, not observed** — the operator reports the budget tracker reading correctly, and no misbucketing has been demonstrated on real data. Quarterly windows are 3 months wide, so a payment must cross a quarter boundary to land wrong, and the `invoice_date` fallback usually sits near the service period anyway. Before doing this work, confirm it's worth doing: find receipts whose payment date and service-period end fall in different windows. The narrow-window case is the monthly funding schedule path (`computeFundingScheduleRowsForParticipant`, ~line 2597, same bucketing) — Lita's SIL 17th-to-16th cycle, where a payment landing after the 16th shifts a whole month.

  Only consumer is `renderNDISBudget` (~line 3025) on the **Reports** tab. Must not touch P&L, BAS, KPI tallies or dashboard money-in — grep every `bucketReceiptsByQuarter` call site before and after.

Data-side (Supabase, not code) — confirm executed before relying on schedule data:
- `fix-lita-schedule-blocks-data.md` — Sunday sleepover block `flat_hours` 20 → 8 (row `1418987b-…`); check for already-processed overpaid pay runs. Also the all-7-days "Evening" block overlapping the Sat/Sun-specific ones.
- `fix-duplicate-blocks-and-sleepover-totals.md` — duplicate/near-duplicate `schedule_blocks` rows for Lita (casing variants of "Sleepover"/"Evening"); query and dedupe, then verify sleepover-matched imported shifts actually flow into pay run sleepover totals (`tot.sleep`), not plain weekday hours.
- `fix-imported-sleepover-pricing.md` — verify the full import→pay-run path splits sleepovers into flat + active correctly end to end (enrichment sets `shiftKind`/`activeMins`; confirm the pay-run totals honour it).

## Pending work

1. **Supabase Auth Phase 2 + 3** — create the admin Auth user; write and apply RLS lockdown SQL; then delete the deprecated `APP_PW` constant.
2. **Wise auto-import bug** — all transfers currently being skipped by the matching logic in `autoImportWiseExpenses`/`autoImportWiseIncome`; trace the `skipped` counters to find which filter is over-firing, dedupe by Wise transfer ID so re-runs stay idempotent.
3. **Payroll status lifecycle** — the `status` field on `pay_runs` should follow `wise_status`: advance to `paid` only when `syncPayRunWiseStatuses` confirms the outgoing transfer settled.
4. **KPI "Money out" excludes pending payroll** — dashboard/cash-book money-out KPIs should only count payroll transactions whose pay run is `paid`.
5. **Sleepover/duplicate data fixes** — run and verify the two data-fix docs above.
6. **`dismissed_recurring_candidates` table not created** — run `migrations/2026-09-05-dismissed-recurring-candidates.sql` in Supabase. Until then the Expenses tab's "Dismiss" button on a suggested recurring expense fails with a toast; everything else on the tab works and suggestions still render, they just can't be dismissed permanently.
7. **Expenses tab unverified in a browser** — the expense tracker's logic is covered by Node-level checks but the rendering path and its live Supabase writes have never been exercised against real data. The multi-row instance back-fill (accepting a suggested recurring expense) is the write to watch first; it relies on the `unique (recurring_expense_id, month)` constraint holding when a month already has an instance.
8. **`fix-receipt-bucketing-by-period.md`** — not applied, and **not confirmed to be a live problem**; see "Status of build docs" for how to check before spending effort on it.
9. Confirm Lita's plan manager and resolve her address discrepancy (6 Maroon St vs 23 Leeward Dr, Tarneit) before finalising her participant record.
