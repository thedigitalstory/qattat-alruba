const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');
const source = fs.readFileSync(path.join(__dirname, '../dist/app.js'), 'utf8')
  .replace('render();initializeCloud();registerAgentTools();',
    'globalThis.logic={cents,validateState,sampleState,totals,validDate,esc,currentMonth};');
const node = { addEventListener() {} };
const sandbox = { window: { addEventListener() {} }, document: { querySelector: () => node, addEventListener() {} },
  setInterval() {}, setTimeout() {}, clearTimeout() {}, Intl, Date, structuredClone, console };
vm.createContext(sandbox);
vm.runInContext(source, sandbox);
const logic = sandbox.logic;
// Keep arithmetic fixtures independent of the names and defaults in the preview.
function fixtureState() {
  const state = logic.sampleState();
  const key = logic.currentMonth(), month = state.months[key];
  month.dues = 25000;
  month.members = month.members.slice(0, 8).map((p, i) => ({ ...p,
    paid: i < 6 ? 25000 : 0, date: i < 6 ? `${key}-01` : '' }));
  month.expenses = [
    { id: 'test-rent', title: 'Test rent', amount: 100000, date: `${key}-28`, paid: false, category: 'rent' },
    { id: 'test-bills', title: 'Test bills', amount: 40000, date: `${key}-05`, paid: true, category: 'bills' }
  ];
  return state;
}

test('Saudi and western decimal amounts remain exact integer halalas', () => {
  assert.equal(logic.cents('١٢٥٫٥٠'), 12550);
  assert.equal(logic.cents('0.29'), 29);
  assert.equal(logic.cents('۲۵۰'), 25000);
  for (const bad of ['-1', '1.234', '1e3', '', 'NaN', '100000.01']) assert.throws(() => logic.cents(bad));
  assert.equal(logic.cents('0', true), 0);
});
test('unpaid commitments are separate from cash spent', () => {
  const state = fixtureState(), m = state.months[logic.currentMonth()];
  const t = logic.totals(m);
  assert.equal(t.collected, 150000);
  assert.equal(t.spent, 40000);
  assert.equal(t.committed, 100000);
  assert.equal(t.balance, 110000);
  m.members[6].paid = 12550;
  assert.equal(logic.totals(m).balance, 122550);
  m.expenses[0].paid = true;
  assert.equal(logic.totals(m).balance, 22550);
});
test('a nearly complete pot is never labelled complete', () => {
  const m = fixtureState().months[logic.currentMonth()];
  m.members.forEach(p => p.paid = m.dues);
  m.members[0].paid -= 1;
  assert.equal(logic.totals(m).percent, 99);
  assert.equal(logic.totals(m).paidCount, 7);
});
test('invalid imported ledgers fail validation without touching the original', () => {
  const valid = fixtureState();
  assert.ok(logic.validateState(valid));
  const bad = structuredClone(valid), m = bad.months[logic.currentMonth()];
  m.members[0].paid = m.dues + 1;
  assert.throws(() => logic.validateState(bad));
  assert.equal(valid.months[logic.currentMonth()].members[0].paid, 25000);
  m.members[0].paid = 25000;
  m.members.push(structuredClone(m.members[0]));
  assert.throws(() => logic.validateState(bad));
  assert.throws(() => logic.validateState({ version: 1, demo: true }));
  assert.equal(logic.validDate('2026-02-30'), false);
  assert.equal(logic.validDate('2028-02-29'), true);
});
test('user names and notes are escaped before rendering', () => {
  assert.equal(logic.esc('<img src=x onerror="alert(1)">'), '&lt;img src=x onerror=&quot;alert(1)&quot;&gt;');
});
