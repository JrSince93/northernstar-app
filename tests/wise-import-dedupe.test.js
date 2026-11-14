// Wise income-import dedupe harness.  Run:  node tests/wise-import-dedupe.test.js
//
// Pulls the REAL functions out of public/index.html by name (no copies), runs
// them in a vm sandbox against an in-memory Supabase stub, and checks that the
// four October 2026 NDIS payments that were double-counted on 2026-11-01 can no
// longer be imported a second time, by any route.
//
// No network, no Supabase, no npm. Exit code 1 on any failure.
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const HTML = fs.readFileSync(path.join(__dirname, '..', 'public', 'index.html'), 'utf8');

// ── extract a top-level function by name, skipping strings and comments ──
function extractFn(name) {
  const re = new RegExp('^(?:async\\s+)?function\\s+' + name.replace(/\$/g, '\\$') + '\\s*\\(', 'm');
  const m = re.exec(HTML);
  if (!m) throw new Error('function not found in index.html: ' + name);
  let i = HTML.indexOf('{', m.index), depth = 0;
  for (; i < HTML.length; i++) {
    const c = HTML[i], n = HTML[i + 1];
    if (c === '/' && n === '/') { i = HTML.indexOf('\n', i); continue; }
    if (c === '/' && n === '*') { i = HTML.indexOf('*/', i) + 1; continue; }
    if (c === '"' || c === "'" || c === '`') {
      for (i++; i < HTML.length && HTML[i] !== c; i++) if (HTML[i] === '\\') i++;
      continue;
    }
    if (c === '{') depth++;
    if (c === '}' && --depth === 0) return HTML.slice(m.index, i + 1);
  }
  throw new Error('unbalanced braces in ' + name);
}

const FNS = [
  'stripWiseHtml', 'wiseJarDisplayName', 'parseWiseFormattedAmount', 'wiseActivityDirection',
  'wiseBalanceRef', 'wiseFirstBalanceRef', 'wiseCurrencyOf', 'mapWiseActivity', 'mapWiseStatementTx',
  'wiseRefSuffix', 'wiseRefMatches', 'wiseIdKey', 'wiseSameTransfer', 'wiseDayDiff',
  'isInvoicePaymentTx', 'findInvoicePaymentTxNear', 'findImportedDepositTx', 'convertDepositToPayment',
  'wiseImportPaused', 'detectWiseJarMove', 'wiseMelbDate', 'isInternalTransfer',
  'isMissingColumnError', 'writeTolerant', 'insertTolerant', 'updateTolerant', 'findExistingPaymentTx',
  'findWiseTransferForManualPayment', 'manualMarkPaid', 'confirmWisePayment',
  'saveLedgerPayment', 'recordInvoicePaymentTx', 'reportInvoicePayment',
  'findWiseInvoiceMatches', 'autoImportWiseIncome', '_autoImportWiseIncomeInner',
  'autoImportWiseExpenses', '_autoImportWiseExpensesInner', 'wiseCounterpartyName', 'wiseNameKeyword',
  'wiseIdFull', 'isUniqueViolation', 'withWiseId', 'wiseTxAmount', 'wiseFindExisting',
  'wiseResolveConflict', 'wiseSetIdOnRow', 'wiseImportExistingRow', 'wiseImportInsert',
  'wiseImportReportProblems', 'reconcilePendingPayroll'
];

// ── in-memory Supabase stub ──
// Records every write and enforces the same unique indexes as production:
//   transactions_wise_reference_uniq   reference ~ '^WISE-[0-9]{6,8}$'
//   transactions_wise_id_uniq          wise_id where not null
//   invoice_ledger_wise_transfer_uniq  digits after the last hyphen of wise_transfer_id
// noWiseIdCol:true simulates the database before the migration ran.
const sqlKey = v => String(v).replace(/^.*-/, '').replace(/\D/g, '');   // the migration's expression
function violates(table, rows, cand, selfId) {
  const others = rows.filter(r => r.id !== selfId);
  if (table === 'transactions') {
    if (cand.wise_id != null && others.some(r => r.wise_id === cand.wise_id)) return 'transactions_wise_id_uniq';
    if (/^WISE-[0-9]{6,8}$/.test(cand.reference || '') && others.some(r => r.reference === cand.reference)) return 'transactions_wise_reference_uniq';
  }
  if (table === 'invoice_ledger' && cand.wise_transfer_id != null) {
    if (others.some(r => r.wise_transfer_id != null && sqlKey(r.wise_transfer_id) === sqlKey(cand.wise_transfer_id))) return 'invoice_ledger_wise_transfer_uniq';
  }
  return null;
}
const dupErr = idx => ({ code: '23505', message: 'duplicate key value violates unique constraint "' + idx + '"' });
const colErr = () => ({ code: 'PGRST204', message: "Could not find the 'wise_id' column of 'transactions' in the schema cache" });
const copy = o => JSON.parse(JSON.stringify(o));

function makeDb(seed, opts = {}) {
  const db = { tables: copy(seed), writes: [] };
  let nextId = 1;
  function builder(table) {
    const rows = () => (db.tables[table] = db.tables[table] || []);
    const noCol = body => opts.noWiseIdCol && table === 'transactions' && body && 'wise_id' in body;
    return {
      insert(row) {
        return { select: async () => {
          if (noCol(row)) return { data: null, error: colErr() };
          const r = Object.assign({ id: 'new-' + (nextId++), created_at: new Date().toISOString() }, row);
          const v = violates(table, rows(), r, null);
          if (v) { db.writes.push({ op: 'insert-rejected', table, row: r, index: v }); return { data: null, error: dupErr(v) }; }
          rows().push(r); db.writes.push({ op: 'insert', table, row: r });
          return { data: [copy(r)], error: null };
        } };
      },
      update(patch) {
        const filters = [];
        const run = () => {
          if (noCol(patch)) return { data: null, error: colErr() };
          const hit = rows().filter(r => filters.every(([k, v]) => (v === null ? r[k] == null : r[k] === v)));
          for (const r of hit) {
            const v = violates(table, rows(), Object.assign({}, r, patch), r.id);
            if (v) { db.writes.push({ op: 'update-rejected', table, patch, index: v }); return { data: null, error: dupErr(v) }; }
          }
          hit.forEach(r => Object.assign(r, patch));
          db.writes.push({ op: 'update', table, patch, filters: filters.slice(), n: hit.length });
          return { data: copy(hit), error: null };
        };
        const chain = {
          eq(k, v) { filters.push([k, v]); return chain; },
          is(k, v) { filters.push([k, v]); return chain; },
          select: async () => run(),
          then(res, rej) { try { res(run()); } catch (e) { rej(e); } }
        };
        return chain;
      },
      select() {
        return { eq(k, v) { return { limit: async n => {
          if (opts.noWiseIdCol && table === 'transactions' && k === 'wise_id') return { data: null, error: colErr() };
          return { data: copy(rows().filter(r => r[k] === v).slice(0, n)), error: null };
        } }; } };
      }
    };
  }
  db.client = { from: builder };
  return db;
}

// ── sandbox with the real functions plus minimal globals ──
// Pass `db` to share one database between two sandboxes ("two tabs").
function makeSandbox({ tx = [], ledger = [], transfers = [], source = 'statement', prompts = [], eidValues = {},
                       db = null, dbOpts = {}, runs = [], emps = [] }) {
  db = db || makeDb({ transactions: tx, invoice_ledger: ledger }, dbOpts);
  const toasts = [];
  const errors = [];
  const el = () => ({ value: '', style: {}, classList: { contains: () => false }, disabled: false, textContent: '' });
  const ctx = {
    console: { log() {}, warn() {}, error: (...a) => errors.push(a.join(' ')) },
    S: {
      tx: copy(tx), invoiceLedger: copy(ledger),
      wiseTransfers: transfers, wiseSource: source, runs: copy(runs), emps: copy(emps)
    },
    sb2: db.client,
    MONTHS: ['January','February','March','April','May','June','July','August','September','October','November','December'],
    WISE_PAYMENT_NEAR_DAYS: 3,
    WISE_NAME_PREFIXES: ['sent money to ','payment to ','transfer to ','paid to '],
    WISE_NAME_STOPWORDS: ['sent','money','transfer','payment','paid','from','to','the','for','ref'],
    _wiseImportInFlight: { out: false, in: false },
    _wiseImportPausedToasted: false,
    _wiseIdColMissing: false,
    _melbDayFmt: null,
    showToast: (m, t) => toasts.push([m, t]),
    setSync() {}, renderDash() {}, renderCB() {}, renderInvoices() {}, closeM() {},
    fmt: n => '$' + Math.abs(+n || 0).toFixed(2),
    tod: () => '2026-11-14',
    prompt: () => prompts.shift(),
    eid: id => Object.assign(el(), { value: eidValues[id] || '' }),
    document: { getElementById: () => el() },
    Intl, Date, Math, JSON, String, Number, Object, Array, RegExp, isNaN, parseFloat, Infinity
  };
  vm.createContext(ctx);
  vm.runInContext(FNS.map(extractFn).join('\n\n'), ctx);
  return { ctx, db, toasts, errors };
}

// ── fixtures: the four October pairs, exactly as in the database ──
const LITA = 'LITA LEE MCKENZIE';
const PAIRS = [
  { ref: 'INV-CF-20261011',  invDate: '2026-10-13', amt: 3205.70, date: '2026-10-15', wiseNum: '2433035637', sender: 'MPM', bl: null },
  { ref: 'INV-SIL-20261011', invDate: '2026-10-18', amt: 7474.51, date: '2026-10-19', wiseNum: '2440584884', sender: 'NDIS VIC PAYMENT', bl: 'bl-1783271548173' },
  { ref: 'INV-SIL-20261025', invDate: '2026-10-26', amt: 7060.24, date: '2026-10-27', wiseNum: '2456267377', sender: 'NDIS VIC PAYMENT', bl: 'bl-1783271548173' },
  { ref: 'INV-CF-20261025',  invDate: '2026-10-26', amt: 3205.30, date: '2026-10-29', wiseNum: '2460608474', sender: 'MPM', bl: 'bl-1783273601383' }
];
const ledgerPaid = (linkFmt) => PAIRS.map((p, i) => ({
  id: 'inv-' + i, invoice_ref: p.ref, participant_name: LITA, invoice_date: p.invDate, amount: p.amt,
  status: 'paid', payment_source: 'Wise', payment_date: p.date, payment_amount: p.amt,
  wise_transfer_id: linkFmt ? linkFmt(p) : null, budget_line_id: p.bl
}));
const ndisRows = () => PAIRS.map((p, i) => ({
  id: 'tx-' + i, date: p.date, month: 'October', description: 'NDIS Payment - ' + LITA,
  payment_type: 'Wise Transfer', reference: p.ref, amount_in: p.amt, amount_out: 0
}));
// Statement-endpoint shape (what the app sees normally).
const stmtTransfer = (p) => ({ id: 'TRANSFER-' + p.wiseNum, date: p.date, when: p.date + 'T03:00:00Z',
  amount: p.amt, direction: 'in', status: 'COMPLETED', type: 'DEPOSIT', senderName: p.sender, description: '' });
// Activities-fallback shape: bare numeric id (what defeated the link on 1 Nov).
const actTransfer = (p) => Object.assign(stmtTransfer(p), { id: p.wiseNum });

// ── tiny runner ──
let pass = 0, fail = 0;
async function test(name, fn) {
  try { await fn(); pass++; console.log('  ok   ' + name); }
  catch (e) { fail++; console.log('  FAIL ' + name + '\n       ' + e.message); }
}
function eq(a, b, msg) { if (a !== b) throw new Error((msg || '') + ' expected ' + JSON.stringify(b) + ', got ' + JSON.stringify(a)); }
const inserts = db => db.writes.filter(w => w.op === 'insert' && w.table === 'transactions');

(async () => {
  console.log('Wise income-import dedupe');

  await test('1 Nov replay: bare ids, invoices linked by TRANSFER- id, NDIS rows present → 0 inserts', async () => {
    const { ctx, db } = makeSandbox({ tx: ndisRows(), ledger: ledgerPaid(p => 'TRANSFER-' + p.wiseNum),
      transfers: PAIRS.map(actTransfer), source: 'statement' });   // source forced: proves the id fix alone
    await ctx.autoImportWiseIncome();
    eq(inserts(db).length, 0, 'inserts');
  });

  await test('same replay with source=activities → import paused, toast shown, 0 inserts', async () => {
    const { ctx, db, toasts } = makeSandbox({ tx: ndisRows(), ledger: ledgerPaid(p => 'TRANSFER-' + p.wiseNum),
      transfers: PAIRS.map(actTransfer), source: 'activities' });
    await ctx.autoImportWiseIncome();
    eq(inserts(db).length, 0, 'inserts');
    eq(toasts.length, 1, 'toasts');
    eq(toasts[0][0], 'Wise statement unavailable — auto-import paused');
  });

  await test('statement ids, invoices linked → 0 inserts (normal path unchanged)', async () => {
    const { ctx, db } = makeSandbox({ tx: ndisRows(), ledger: ledgerPaid(p => 'TRANSFER-' + p.wiseNum),
      transfers: PAIRS.map(stmtTransfer) });
    await ctx.autoImportWiseIncome();
    eq(inserts(db).length, 0, 'inserts');
  });

  await test('no wise_transfer_id on any invoice (Mark paid route), NDIS rows present → 0 inserts', async () => {
    const { ctx, db } = makeSandbox({ tx: ndisRows(), ledger: ledgerPaid(null), transfers: PAIRS.map(stmtTransfer) });
    await ctx.autoImportWiseIncome();
    eq(inserts(db).length, 0, 'inserts');
  });

  await test('NDIS rows present but no ledger at all → 0 inserts (cash-book check)', async () => {
    const { ctx, db } = makeSandbox({ tx: ndisRows(), ledger: [], transfers: PAIRS.map(stmtTransfer) });
    await ctx.autoImportWiseIncome();
    eq(inserts(db).length, 0, 'inserts');
  });

  await test('control: an unrelated $700 State Trustees deposit is still imported', async () => {
    const t = { id: 'TRANSFER-2430648350', date: '2026-10-14', when: '2026-10-14T02:00:00Z', amount: 700,
      direction: 'in', status: 'COMPLETED', type: 'DEPOSIT', senderName: 'State Trustees', description: '' };
    const { ctx, db } = makeSandbox({ tx: ndisRows(), ledger: ledgerPaid(p => 'TRANSFER-' + p.wiseNum),
      transfers: PAIRS.map(stmtTransfer).concat([t]) });
    await ctx.autoImportWiseIncome();
    eq(inserts(db).length, 1, 'inserts');
    eq(inserts(db)[0].row.reference, 'WISE-30648350');
  });

  await test('Wise_Payroll_ batch marked "in" → skipped (backstop)', async () => {
    const batches = [['343', '2026-10-02', 4838.50, 'Wise_Payroll_2026-09-14_to_2026-09-27'],
                     ['10280', '2026-10-30', 6438.00, 'Wise_Payroll_2026-10-12_to_2026-10-25'],
                     ['2079689', '2026-10-30', 1520.00, 'Wise_Payroll_2026-10-12_to_2026-10-25 (1)']]
      .map(([id, d, a, s]) => ({ id, date: d, when: d + 'T05:00:00Z', amount: a, direction: 'in',
        status: 'COMPLETED', type: 'TRANSFER', senderName: s, description: s }));
    const { ctx, db } = makeSandbox({ transfers: batches });
    await ctx.autoImportWiseIncome();
    eq(inserts(db).length, 0, 'inserts');
  });

  await test('unsigned activities amount → direction "unknown", never imported', async () => {
    const { ctx, db } = makeSandbox({ transfers: [] });
    const unsigned = ctx.mapWiseActivity({ id: 10280, type: 'TRANSFER', title: 'Wise_Payroll_2026-10-12_to_2026-10-25',
      primaryAmount: '6,438 AUD', status: 'COMPLETED', createdOn: '2026-10-30T05:00:00Z' });
    eq(unsigned.direction, 'unknown', 'direction');
    const signedIn = ctx.mapWiseActivity({ id: 1, type: 'TRANSFER', title: 'MPM',
      primaryAmount: '<positive>+ 3,205.70 AUD</positive>', status: 'COMPLETED', createdOn: '2026-10-15T03:00:00Z' });
    eq(signedIn.direction, 'in', 'positive direction');
    const signedOut = ctx.mapWiseActivity({ id: 2, type: 'TRANSFER', title: 'Aldi',
      primaryAmount: '<negative>- 260.55 AUD</negative>', status: 'COMPLETED', createdOn: '2026-10-26T03:00:00Z' });
    eq(signedOut.direction, 'out', 'negative direction');
    // Even with source forced to statement, the unknown row is left alone.
    ctx.S.wiseTransfers = [unsigned];
    await ctx.autoImportWiseIncome();
    eq(inserts(db).length, 0, 'inserts');
  });

  await test('manualMarkPaid with the Wise deposit visible → saves wise_transfer_id; later import → 0 inserts', async () => {
    const p = PAIRS[0];
    const ledger = [{ id: 'inv-0', invoice_ref: p.ref, participant_name: LITA, invoice_date: p.invDate,
      amount: p.amt, status: 'awaiting_payment', wise_transfer_id: null, budget_line_id: null }];
    const { ctx, db } = makeSandbox({ ledger, transfers: [stmtTransfer(p)], prompts: [String(p.amt), p.date] });
    await ctx.manualMarkPaid('inv-0');
    const ledgerWrite = db.writes.find(w => w.table === 'invoice_ledger');
    eq(ledgerWrite.patch.wise_transfer_id, 'TRANSFER-' + p.wiseNum, 'wise_transfer_id saved');
    eq(inserts(db).length, 1, 'one NDIS Payment row');
    eq(inserts(db)[0].row.reference, p.ref);
    // A later sync, even from the fallback's bare id, must not import it again.
    ctx.S.wiseTransfers = [actTransfer(p)];
    await ctx.autoImportWiseIncome();
    eq(inserts(db).length, 1, 'still one row after import');
  });

  await test('manualMarkPaid with no Wise transfer visible → no id saved; later import → 0 inserts', async () => {
    const p = PAIRS[1];
    const ledger = [{ id: 'inv-1', invoice_ref: p.ref, participant_name: LITA, invoice_date: p.invDate,
      amount: p.amt, status: 'awaiting_payment', wise_transfer_id: null, budget_line_id: p.bl }];
    const { ctx, db } = makeSandbox({ ledger, transfers: [], prompts: [String(p.amt), p.date] });
    await ctx.manualMarkPaid('inv-1');
    const ledgerWrite = db.writes.find(w => w.table === 'invoice_ledger');
    eq('wise_transfer_id' in ledgerWrite.patch, false, 'no id when nothing matched');
    eq(inserts(db).length, 1, 'one NDIS Payment row');
    ctx.S.wiseTransfers = [stmtTransfer(p)];
    await ctx.autoImportWiseIncome();
    eq(inserts(db).length, 1, 'still one row after import');
  });

  await test('deposit imported first, then manualMarkPaid → converts it, no second row', async () => {
    const p = PAIRS[2];
    const dep = { id: 'dep-2', date: p.date, month: 'October', description: 'Deposit - ' + p.sender,
      payment_type: 'Wise Transfer', reference: 'WISE-56267377', amount_in: p.amt, amount_out: 0 };
    const ledger = [{ id: 'inv-2', invoice_ref: p.ref, participant_name: LITA, invoice_date: p.invDate,
      amount: p.amt, status: 'awaiting_payment', wise_transfer_id: null, budget_line_id: p.bl }];
    const { ctx, db } = makeSandbox({ tx: [dep], ledger, transfers: [stmtTransfer(p)], prompts: [String(p.amt), p.date] });
    await ctx.manualMarkPaid('inv-2');
    eq(inserts(db).length, 0, 'inserts');
    eq(ctx.S.tx.length, 1, 'S.tx rows');
    eq(ctx.S.tx[0].reference, p.ref, 'converted reference');
    eq(ctx.S.tx[0].description, 'NDIS Payment - ' + LITA, 'converted description');
    eq(ctx.S.tx[0].budget_line_id, p.bl, 'budget line');
    eq(db.tables.transactions[0].reference, p.ref, 'persisted');
  });

  await test('deposit imported first, then confirmWisePayment → converts it, no second row', async () => {
    const p = PAIRS[3];
    const dep = { id: 'dep-3', date: p.date, month: 'October', description: 'Deposit - ' + p.sender,
      payment_type: 'Wise Transfer', reference: 'WISE-60608474', amount_in: p.amt, amount_out: 0 };
    const ledger = [{ id: 'inv-3', invoice_ref: p.ref, participant_name: LITA, invoice_date: p.invDate,
      amount: p.amt, status: 'awaiting_payment', wise_transfer_id: null, budget_line_id: p.bl }];
    const { ctx, db } = makeSandbox({ tx: [dep], ledger, transfers: [stmtTransfer(p)],
      eidValues: { 'wp-inv-id': 'inv-3', 'wp-wise-id': 'TRANSFER-' + p.wiseNum } });
    await ctx.confirmWisePayment();
    eq(inserts(db).length, 0, 'inserts');
    eq(ctx.S.tx.length, 1, 'S.tx rows');
    eq(ctx.S.tx[0].reference, p.ref, 'converted reference');
    await ctx.autoImportWiseIncome();
    eq(inserts(db).length, 0, 'import afterwards');
  });

  await test('match banner: invoice linked by TRANSFER- id is not re-offered a bare-id transfer', async () => {
    const p = PAIRS[0];
    const ledger = [
      { id: 'a', invoice_ref: p.ref, invoice_date: p.invDate, amount: p.amt, status: 'paid', wise_transfer_id: 'TRANSFER-' + p.wiseNum },
      { id: 'b', invoice_ref: 'INV-CF-NEXT', invoice_date: '2026-10-01', amount: p.amt, status: 'awaiting_payment', wise_transfer_id: null }
    ];
    const { ctx } = makeSandbox({ ledger, transfers: [actTransfer(p)] });
    eq(ctx.findWiseInvoiceMatches().length, 0, 'matches');
  });

  // ───────────── wise_id: the database refuses a second row ─────────────
  console.log('\nwise_id unique index (one Wise transaction, one row)');
  const errToasts = t => t.filter(x => x[1] === 'err');
  const dbTx = db => db.tables.transactions;

  await test('wiseIdFull matches the migration SQL expression for every id shape', async () => {
    const { ctx } = makeSandbox({});
    for (const id of ['TRANSFER-2433035637', '2433035637', 'BALANCE-6107067382', 'CONVERSION_ORDER-5942674', 'CARD_TRANSACTION-1234567890', 343, 'abc-'])
      eq(ctx.wiseIdFull(id), sqlKey(id), 'id ' + id);
    eq(ctx.wiseIdFull('TRANSFER-2433035637'), '2433035637', 'untruncated');
  });

  const deposit = { id: 'TRANSFER-2430648350', date: '2026-10-14', when: '2026-10-14T02:00:00Z', amount: 700,
    direction: 'in', status: 'COMPLETED', type: 'DEPOSIT', senderName: 'State Trustees', description: '' };

  await test('income importer: second tab imports the same deposit → 23505, quiet skip, row adopted', async () => {
    const tab1 = makeSandbox({ transfers: [deposit] });
    await tab1.ctx.autoImportWiseIncome();
    eq(dbTx(tab1.db).length, 1, 'tab 1 wrote it');
    eq(dbTx(tab1.db)[0].wise_id, '2430648350', 'with the full wise_id');
    const tab2 = makeSandbox({ transfers: [deposit], db: tab1.db });   // fresh S.tx, same database
    await tab2.ctx.autoImportWiseIncome();
    eq(dbTx(tab1.db).length, 1, 'still one row');
    eq(errToasts(tab2.toasts).length, 0, 'no error toast');
    eq(tab2.ctx.S.tx.length, 1, 'tab 2 adopted the existing row');
  });

  const payout = { id: 'TRANSFER-2462701964', date: '2026-10-30', when: '2026-10-30T05:00:00Z', amount: 2600,
    direction: 'out', status: 'COMPLETED', type: 'TRANSFER', recipientName: 'PDH Trust Account', description: 'Sent money to PDH Trust Account' };

  await test('outbound importer: second tab imports the same payout → 23505, quiet skip, row adopted', async () => {
    const tab1 = makeSandbox({ transfers: [payout] });
    await tab1.ctx.autoImportWiseExpenses();
    eq(dbTx(tab1.db).length, 1, 'tab 1 wrote it');
    eq(dbTx(tab1.db)[0].wise_id, '2462701964', 'with the full wise_id');
    const tab2 = makeSandbox({ transfers: [payout], db: tab1.db });
    await tab2.ctx.autoImportWiseExpenses();
    eq(dbTx(tab1.db).length, 1, 'still one row');
    eq(errToasts(tab2.toasts).length, 0, 'no error toast');
    eq(tab2.ctx.S.tx.length, 1, 'tab 2 adopted the existing row');
  });

  await test('importer: id too short for the reference index (WISE-10280) → only wise_id stops the second row', async () => {
    const shortId = Object.assign({}, payout, { id: 'TRANSFER-10280', amount: 64.38, recipientName: 'Ring', description: 'Ring' });
    const tab1 = makeSandbox({ transfers: [shortId] });
    await tab1.ctx.autoImportWiseExpenses();
    eq(dbTx(tab1.db)[0].reference, 'WISE-10280', 'outside ^WISE-[0-9]{6,8}$');
    const tab2 = makeSandbox({ transfers: [shortId], db: tab1.db });
    await tab2.ctx.autoImportWiseExpenses();
    eq(dbTx(tab1.db).length, 1, 'still one row');
    eq(tab1.db.writes.filter(w => w.op === 'insert-rejected')[0].index, 'transactions_wise_id_uniq', 'caught by wise_id');
  });

  await test('importer self-heal: a legacy WISE- row gets its full wise_id, nothing inserted', async () => {
    const legacy = { id: 'tx-legacy', date: '2026-10-14', reference: 'WISE-30648350', description: 'Deposit - State Trustees',
      payment_type: 'Wise Transfer', amount_in: 700, amount_out: 0 };
    const { ctx, db } = makeSandbox({ tx: [legacy], transfers: [deposit] });
    await ctx.autoImportWiseIncome();
    eq(inserts(db).length, 0, 'inserts');
    eq(dbTx(db)[0].wise_id, '2430648350', 'backfilled in the database');
    eq(ctx.S.tx[0].wise_id, '2430648350', 'and in memory');
  });

  await test('importer: same wise_id but a different amount → counted as a conflict, error toast, not hidden', async () => {
    const other = { id: 'tx-x', date: '2026-10-01', reference: 'PAYROLL-abcdef12', description: 'Payroll - X',
      amount_in: 0, amount_out: 999, wise_id: '2430648350' };
    const { ctx, db, toasts, errors } = makeSandbox({ tx: [other], transfers: [deposit] });
    ctx.S.tx = [];                                   // this tab doesn't have the row
    await ctx.autoImportWiseIncome();
    eq(inserts(db).length, 0, 'inserts');
    eq(errToasts(toasts).length, 1, 'error toast');
    eq(errors.length > 0, true, 'console.error logged');
  });

  const inv0 = (over) => Object.assign({ id: 'inv-0', invoice_ref: PAIRS[0].ref, participant_name: LITA, invoice_date: PAIRS[0].invDate,
    amount: PAIRS[0].amt, status: 'awaiting_payment', wise_transfer_id: null, budget_line_id: 'bl-x' }, over || {});

  await test('confirmWisePayment twice (second, stale tab) → one NDIS Payment row, second reports "already recorded"', async () => {
    const p = PAIRS[0];
    const eidValues = { 'wp-inv-id': 'inv-0', 'wp-wise-id': 'TRANSFER-' + p.wiseNum };
    const tab1 = makeSandbox({ ledger: [inv0()], transfers: [stmtTransfer(p)], eidValues });
    await tab1.ctx.confirmWisePayment();
    eq(dbTx(tab1.db).length, 1, 'tab 1 recorded it');
    eq(dbTx(tab1.db)[0].wise_id, p.wiseNum, 'with wise_id');
    eq(dbTx(tab1.db)[0].budget_line_id, 'bl-x', 'budget line kept');
    const tab2 = makeSandbox({ ledger: [inv0()], transfers: [stmtTransfer(p)], eidValues, db: tab1.db });
    await tab2.ctx.confirmWisePayment();
    eq(dbTx(tab1.db).length, 1, 'still one row');
    eq(errToasts(tab2.toasts).length, 0, 'no error toast');
    eq(tab2.toasts[tab2.toasts.length - 1][0], 'Payment already recorded in cash book — skipped duplicate');
  });

  await test('confirmWisePayment: transfer already pays ANOTHER invoice → refused, error toast, no cash-book row', async () => {
    const p = PAIRS[0];
    const other = { id: 'inv-other', invoice_ref: 'INV-CF-OTHER', amount: p.amt, status: 'paid', wise_transfer_id: p.wiseNum };  // bare format
    const { ctx, db, toasts } = makeSandbox({ ledger: [inv0(), other], transfers: [stmtTransfer(p)],
      eidValues: { 'wp-inv-id': 'inv-0', 'wp-wise-id': 'TRANSFER-' + p.wiseNum } });
    ctx.S.invoiceLedger = [inv0()];                  // this tab never saw the other link
    await ctx.confirmWisePayment();
    eq(dbTx(db).length, 0, 'no cash-book row');
    eq(ctx.S.invoiceLedger[0].status, 'awaiting_payment', 'not marked paid');
    eq(errToasts(toasts).length, 1, 'error toast');
    eq(db.tables.invoice_ledger.find(r => r.id === 'inv-0').status, 'awaiting_payment', 'not marked paid in the database');
  });

  await test('manualMarkPaid after confirmWisePayment in another tab → one row, no error', async () => {
    const p = PAIRS[0];
    const tab1 = makeSandbox({ ledger: [inv0()], transfers: [stmtTransfer(p)],
      eidValues: { 'wp-inv-id': 'inv-0', 'wp-wise-id': 'TRANSFER-' + p.wiseNum } });
    await tab1.ctx.confirmWisePayment();
    const tab2 = makeSandbox({ ledger: [inv0()], transfers: [stmtTransfer(p)], db: tab1.db,
      prompts: [String(p.amt), '2026-10-16'] });   // typed a day later: same-ref check misses, the index doesn't
    await tab2.ctx.manualMarkPaid('inv-0');
    eq(dbTx(tab1.db).length, 1, 'still one row');
    eq(errToasts(tab2.toasts).length, 0, 'no error toast');
  });

  await test('manualMarkPaid: matched transfer already pays another invoice → saved without the link', async () => {
    const p = PAIRS[0];
    const other = { id: 'inv-other', invoice_ref: 'INV-CF-OTHER', amount: p.amt, status: 'paid', wise_transfer_id: 'TRANSFER-' + p.wiseNum };
    const { ctx, db } = makeSandbox({ ledger: [inv0(), other], transfers: [stmtTransfer(p)], prompts: [String(p.amt), p.date] });
    ctx.S.invoiceLedger = [inv0()];
    await ctx.manualMarkPaid('inv-0');
    const saved = db.tables.invoice_ledger.find(r => r.id === 'inv-0');
    eq(saved.status, 'paid', 'marked paid');
    eq(saved.wise_transfer_id, null, 'without the contested link');
  });

  await test('deposit conversion: another row already holds the Wise id → conflict reported, nothing changed', async () => {
    const p = PAIRS[2];
    const dep = { id: 'dep-2', date: p.date, description: 'Deposit - ' + p.sender, payment_type: 'Wise Transfer',
      reference: 'WISE-56267377', amount_in: p.amt, amount_out: 0 };
    const holder = { id: 'tx-h', date: p.date, description: 'NDIS Payment - ' + LITA, reference: 'INV-SIL-ELSEWHERE',
      amount_in: p.amt, amount_out: 0, wise_id: p.wiseNum };
    const { ctx, db, toasts } = makeSandbox({ tx: [dep, holder], ledger: [Object.assign(inv0(), { id: 'inv-2', invoice_ref: p.ref, amount: p.amt })],
      transfers: [stmtTransfer(p)], eidValues: { 'wp-inv-id': 'inv-2', 'wp-wise-id': 'TRANSFER-' + p.wiseNum } });
    ctx.S.tx = [dep];
    await ctx.confirmWisePayment();
    eq(inserts(db).length, 0, 'inserts');
    eq(dbTx(db).find(r => r.id === 'dep-2').reference, 'WISE-56267377', 'deposit left as is');
    eq(errToasts(toasts).length, 1, 'error toast');
  });

  const runs = [{ id: '93d061c2-0000-0000-0000-000000000000', net_pay: 1588.61, period_end: '2026-09-27', employee_id: 'e1' }];
  const pendingRow = () => ({ id: 'pend-1', date: '2026-10-02', reference: 'PAYROLL-PENDING-93d061c2',
    description: 'Payroll - Simon [pending]', amount_in: 0, amount_out: 0 });
  const pay = { id: 'TRANSFER-2400924450', date: '2026-09-30', amount: 1588.61, direction: 'out', status: 'COMPLETED', type: 'TRANSFER' };

  await test('reconcilePendingPayroll: stores the payout\'s wise_id on the PAYROLL row', async () => {
    const { ctx, db } = makeSandbox({ tx: [pendingRow()], transfers: [pay], runs });
    eq(await ctx.reconcilePendingPayroll(), 1, 'reconciled');
    const r = dbTx(db)[0];
    eq(r.reference, 'PAYROLL-93d061c2'); eq(r.wise_id, '2400924450'); eq(r.amount_out, 1588.61);
  });

  await test('reconcilePendingPayroll: payout already on another row → run left pending, nothing double-counted', async () => {
    const elsewhere = { id: 'tx-e', date: '2026-09-30', reference: 'WISE-00924450', description: 'Simon',
      amount_in: 0, amount_out: 1588.61, wise_id: '2400924450' };
    // (a) this tab can see the row: never matched
    const a = makeSandbox({ tx: [pendingRow(), elsewhere], transfers: [pay], runs });
    eq(await a.ctx.reconcilePendingPayroll(), 0, 'not reconciled (visible)');
    // (b) this tab can't: the index refuses the update
    const b = makeSandbox({ tx: [pendingRow(), elsewhere], transfers: [pay], runs });
    b.ctx.S.tx = [pendingRow()];
    eq(await b.ctx.reconcilePendingPayroll(), 0, 'not reconciled (index)');
    eq(dbTx(b.db).find(r => r.id === 'pend-1').reference, 'PAYROLL-PENDING-93d061c2', 'still pending');
  });

  await test('before the migration (no wise_id column): imports work, confirm keeps budget_line_id', async () => {
    const tab = makeSandbox({ transfers: [deposit], dbOpts: { noWiseIdCol: true } });
    await tab.ctx.autoImportWiseIncome();
    eq(dbTx(tab.db).length, 1, 'imported');
    eq('wise_id' in dbTx(tab.db)[0], false, 'without wise_id');
    const p = PAIRS[0];
    const c = makeSandbox({ ledger: [inv0()], transfers: [stmtTransfer(p)], dbOpts: { noWiseIdCol: true },
      eidValues: { 'wp-inv-id': 'inv-0', 'wp-wise-id': 'TRANSFER-' + p.wiseNum } });
    await c.ctx.confirmWisePayment();
    eq(dbTx(c.db).length, 1, 'recorded');
    eq(dbTx(c.db)[0].budget_line_id, 'bl-x', 'budget_line_id NOT dropped with wise_id');
    eq(errToasts(c.toasts).length, 0, 'no error toast');
  });

  console.log('\n' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
})();
