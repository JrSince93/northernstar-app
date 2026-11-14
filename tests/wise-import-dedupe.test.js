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
  'isMissingColumnError', 'insertTolerant', 'updateTolerant', 'findExistingPaymentTx',
  'findWiseTransferForManualPayment', 'manualMarkPaid', 'confirmWisePayment',
  'findWiseInvoiceMatches', 'wiseAdoptExistingTx', 'autoImportWiseIncome', '_autoImportWiseIncomeInner'
];

// ── in-memory Supabase stub: records every write ──
function makeDb(seed) {
  const db = { tables: JSON.parse(JSON.stringify(seed)), writes: [] };
  let nextId = 1;
  function builder(table) {
    const rows = () => (db.tables[table] = db.tables[table] || []);
    return {
      insert(row) {
        return { select: async () => {
          const r = Object.assign({ id: 'new-' + (nextId++), created_at: new Date().toISOString() }, row);
          rows().push(r); db.writes.push({ op: 'insert', table, row: r });
          return { data: [JSON.parse(JSON.stringify(r))], error: null };
        } };
      },
      update(patch) {
        const filters = [];
        const run = () => {
          const hit = rows().filter(r => filters.every(([k, v]) => r[k] === v));
          hit.forEach(r => Object.assign(r, patch));
          db.writes.push({ op: 'update', table, patch, filters: filters.slice(), n: hit.length });
          return { data: JSON.parse(JSON.stringify(hit)), error: null };
        };
        const chain = {
          eq(k, v) { filters.push([k, v]); return chain; },
          select: async () => run(),
          then(res, rej) { try { res(run()); } catch (e) { rej(e); } }
        };
        return chain;
      },
      select() { return { eq() { return { limit: async () => ({ data: [], error: null }) }; } }; }
    };
  }
  db.client = { from: builder };
  return db;
}

// ── sandbox with the real functions plus minimal globals ──
function makeSandbox({ tx = [], ledger = [], transfers = [], source = 'statement', prompts = [], eidValues = {} }) {
  const db = makeDb({ transactions: tx, invoice_ledger: ledger });
  const toasts = [];
  const el = () => ({ value: '', style: {}, classList: { contains: () => false }, disabled: false, textContent: '' });
  const ctx = {
    console: { log() {}, warn() {}, error: console.error },
    S: {
      tx: JSON.parse(JSON.stringify(tx)), invoiceLedger: JSON.parse(JSON.stringify(ledger)),
      wiseTransfers: transfers, wiseSource: source
    },
    sb2: db.client,
    MONTHS: ['January','February','March','April','May','June','July','August','September','October','November','December'],
    WISE_PAYMENT_NEAR_DAYS: 3,
    _wiseImportInFlight: { out: false, in: false },
    _wiseImportPausedToasted: false,
    _melbDayFmt: null,
    showToast: (m, t) => toasts.push([m, t]),
    setSync() {}, renderDash() {}, renderCB() {}, renderInvoices() {}, closeM() {},
    tod: () => '2026-11-14',
    prompt: () => prompts.shift(),
    eid: id => Object.assign(el(), { value: eidValues[id] || '' }),
    document: { getElementById: () => el() },
    Intl, Date, Math, JSON, String, Number, Object, Array, RegExp, isNaN, parseFloat, Infinity
  };
  vm.createContext(ctx);
  vm.runInContext(FNS.map(extractFn).join('\n\n'), ctx);
  return { ctx, db, toasts };
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

  console.log('\n' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
})();
