# Handoff — post-Copilot sanity fixes complete, paystub root cause found, next phases

> **Update (2026-07-17):** The `day_breakdown` column ALREADY EXISTS on
> `pay_runs` (verified via REST — 9 of 20 pay runs carry data). Do NOT run the
> ALTER TABLE below; it has already been applied. The remaining payslip bug was
> in rendering, not the schema: sleepover shifts saved by the new shift board
> were double-rendered (as an hourly day line AND the flat allowance). Fixed in
> `genPayslip` (sleepover/meta rows skipped in the hourly loop) and `savePayRun`
> now also captures `pay_amt` per shift so payslip lines reflect manual block
> rates exactly. Verified via extracted-code simulation; see git history.

## Status (verified against the actual current `public/index.html`, not assumed)

Schedule blocks are properly wired now. Confirmed in the current code:

- `schedule_blocks` is the live source of truth — CRUD works (`renderScheduleBlocks`,
  insert/update/delete all hit the `schedule_blocks` table correctly), and it's
  read from consistently: participant cards, weekly hours chart, holiday
  auto-hours, employee-hours-on-date lookups, and worker conflict detection
  all pull from `getParticipantScheduleBlocks` / `getScheduleBlocksForEmployeeOnDate`
  / `scheduleBlockAppliesToEmployee` rather than the old roster.
- `saveParticipant` no longer writes to `roster` at all — that column is fully
  retired going forward (old data may still sit in it on old records, but
  nothing reads or writes it live anymore except one explicitly-flagged
  legacy fallback, see below).
- Dead functions from the old roster-grid UI (`buildRosterTable`,
  `getRosterValues`, `updateRosterTotal`, `prBlockChange`) have been removed.

**This is not yet committed/pushed** — confirm with the operator whether to
commit now before starting the next phase, since Netlify won't see any of
this until it lands on `main`.

## Root cause of the paystub problem (found, not yet fixed)

`savePayRun` already does the right thing — it captures the exact day-grid
selections at the moment a pay run is processed into a `day_breakdown` field
(`{date, dow, hrs, type, block_id, participant_id, shift_kind}[]`), and
`genPayslip` already prefers rendering from that saved snapshot over
reconstructing anything.

**The problem: the `day_breakdown` column doesn't exist on `pay_runs` in
Supabase yet.** `savePayRun` detects the missing-column error and silently
retries the insert *without* `day_breakdown` (see the comment right at the
insert call, `public/index.html` around the `savePayRun` function) — so
every pay run currently being processed saves fine, but with no day
breakdown attached.

Then in `genPayslip`, when `day_breakdown` is empty/missing, it falls back
to **legacy roster reconstruction** — which reads `p.roster`, a field that
(per the fix above) is no longer written to for any participant going
forward. So new payslips are silently falling through to a reconstruction
path built on data that's now permanently stale, producing wrong hours
(it defaults to a flat 7.5h/day guess when there's nothing in roster at
all).

**The fix is one line of SQL, run once in Supabase:**

```sql
ALTER TABLE pay_runs ADD COLUMN day_breakdown JSONB;
```

After that:
1. Process a new pay run for an hourly employee with some schedule blocks
   ticked in the day grid.
2. Generate that pay run's payslip and confirm it shows the actual dates/
   hours/shift names from the day grid — not a flat 7.5h/day guess.
3. Confirm the legacy roster-reconstruction branch in `genPayslip` is now
   only ever hit for genuinely old pay runs that predate this column
   (check a couple of the oldest existing pay runs still render sensibly —
   they won't have day_breakdown and will still hit the fallback, which is
   expected and fine for those specifically).

## Next phases

**Phase A (do first):** Run the SQL above, verify per the 3 steps, commit
and push. This is the last item blocking "participant profile + pay runs
are done."

**Phase B:** Invoicing/budget tracker rebuild. Already fully specified in
`invoicing-budget-tracker-build-prompt.md` in this repo — verified against
the current code just now and it's still accurate (the invoice functions
`genNDISInvoice`, `genMyPlaceCSV`, `_buildInvLines`, `ndisInvApplyBudgetLineDefaults`,
`blRate`, and `BL_CARD_LABELS` are all unchanged from what that file
assumes). Proceed straight to that file once Phase A is confirmed working.

## Explicitly not in scope for this handoff

`CLAUDE.md`'s existing "Pending Work" list (invoice payment matching on the
Cash Book, payroll status pending→paid lifecycle, KPI money-out excluding
pending payroll, Wise auto-import wiring) is separate, pre-existing tracked
work — not touched by this handoff and not blocking Phase A/B above. Don't
fold that in here; flag it back to the operator separately if it comes up.
