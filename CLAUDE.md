# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this app is

Northern Star Support Services — a private financial operations dashboard for an Australian NDIS (National Disability Insurance Scheme) disability support provider. It manages cash book entries, employee payroll (PAYG + superannuation), NDIS participant records and budget tracking, invoice generation, and Wise banking reconciliation.

## Architecture

This is a **zero-build, single-file SPA** deployed on Netlify:

- `public/index.html` — The entire application: ~5,400 lines of HTML + CSS + vanilla JS in one file. No framework, no bundler, no npm.
- `netlify/functions/wise.js` — A serverless function that proxies authenticated requests to `api.wise.com` (keeps `WISE_API_TOKEN` off the client).
- `netlify.toml` — Publishes `public/`, serves functions from `netlify/functions/`.

External libs are CDN-loaded: Chart.js and `@supabase/supabase-js@2`.

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

Push to `main`. Netlify auto-deploys — `public/` is the publish directory.

The Wise API token must be set as a Netlify environment variable: `WISE_API_TOKEN`.

## Backend: Supabase

All data lives in Supabase (project `bhqjsqwbsbhjuhjwxwcp`). The anon key and project URL are embedded as `SURL`/`SKEY` in `index.html` around line 720. The Supabase client is `sb2`.

**Tables:** `transactions`, `employees`, `pay_runs`, `dropdown_options`, `participants`, `invoice_ledger`

**Storage:** Supabase Storage bucket `invoices` for uploaded invoice PDFs.

Auth is Supabase Auth with a custom lockout mechanism (`getLockoutState` / `setLockoutState`).

## Global state object `S`

All in-memory application state is on the global `S` object (defined ~line 729):

```
S = { tx, emps, runs, participants, dd, curMonth, editEmpId, ddField, ddTargetId, ch, wiseTransfers, invoiceLedger, _lastGenInvoice }
```

`loadAll()` (~line 901) fetches all tables on startup and populates `S`. The `ch` sub-object holds Chart.js instances keyed by canvas ID; use `dkc(id)` to destroy before re-rendering.

## Navigation

`nav(page)` switches views by toggling `.active` on `#page-<name>` divs. Pages: `dashboard`, `cashbook`, `employees`, `participants`, `payroll`, `invoices`, `tax`, `reports`.

## Domain constants

- `SUPER_RATE = 0.115` — Australian superannuation rate (11.5%)
- `WISE_PROFILE_ID = 87229043` — Falaax Group Pty Ltd Wise business profile
- `WISE_FN_URL = '/.netlify/functions/wise'` — all Wise calls go through this proxy
- NDIS rates are embedded in the invoice modal (~line 660) labelled "PAPL 2025-26 v1.1"

## Wise integration

The `wise.js` function is a passthrough proxy restricted to paths starting with `v1/profiles`, `v3/profiles`, `v4/profiles`, `v1/borderless-accounts`. Add `?debug=1` to log the first response item to Netlify function logs.

Client-side Wise logic: `fetchWiseBalance`, `fetchWiseTransfers`, `syncPayRunWiseStatuses`, `reconcilePendingPayroll`, `autoImportWiseExpenses`, `autoImportWiseIncome`, `checkWiseForInvoices`.

## Key conventions

- `eid(id)` is a shorthand for `document.getElementById(id)`.
- `fmt(n)` formats AUD dollar amounts.
- `tod()` returns today as `YYYY-MM-DD`.
- Transaction references follow prefixes defined in `REF_PREFIXES` (~line 799); `getNextRef(description)` auto-increments them.
- The `[recurring]` tag in a transaction description flags it as a recurring entry.
- Invisible Unicode characters in NDIS numbers/ABNs are caught by `stripInvisibles` / `hasInvisibles` and cleaned up via `cleanupInvisibleChars()` on load.

## Australian compliance details

- PAYG withholding is calculated by `paygCalc(annualisedGross)` using ATO 2024–25 tax tables.
- BAS/GST estimates appear on the Tax & BAS page.
- Payroll runs record `period_start`, `period_end`, PAYG, super, and net for each employee. Public holiday detection lives in `checkPeriodHolidays`.

## Pending Work

1. **Invoice payment matching** — when an `NDIS Payment` transaction is created in the Cash Book whose amount matches an outstanding invoice in the participant archive, display a green checkmark on that invoice entry.

2. **Payroll status lifecycle** — new pay runs should start with status `pending` (not `paid`). Status advances to `paid` only when `syncPayRunWiseStatuses` confirms the outgoing Wise transfer has settled. The existing `wise_status` field on `pay_runs` tracks the Wise side; the `status` field should follow it.

3. **KPI "Money out" excludes pending payroll** — the Dashboard and Cash Book money-out KPI currently counts payroll transactions that are still pending Wise confirmation. It should only sum transactions where the associated pay run `status` is `paid` (or transactions unrelated to payroll).

4. **Auto-import Wise transactions into Cash Book** — `autoImportWiseExpenses` and `autoImportWiseIncome` (both in `index.html`) already fetch and parse Wise activity; wire them up to automatically write matching rows into the `transactions` table in Supabase, deduplicating by Wise transfer ID so re-runs are idempotent.
