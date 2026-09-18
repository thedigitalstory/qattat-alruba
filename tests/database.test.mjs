// Run with PGlite installed in a temporary directory:
// QATTA_PGLITE_MODULE=/tmp/qatta-db-tests/node_modules/@electric-sql/pglite/dist/index.js node tests/database.test.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
if (!process.env.QATTA_PGLITE_MODULE) throw new Error('Set QATTA_PGLITE_MODULE to the installed PGlite module path.');
const { PGlite } = await import(pathToFileURL(process.env.QATTA_PGLITE_MODULE));
const db = new PGlite();
await db.exec(`create role anon nologin; create role authenticated nologin;
  create schema auth; create table auth.users(id uuid primary key);
  create function auth.uid() returns uuid language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  grant usage on schema auth to anon, authenticated;
  grant execute on function auth.uid() to anon, authenticated;
  insert into auth.users values ('11111111-1111-4111-8111-111111111111'), ('22222222-2222-4222-8222-222222222222');`);
const setup = await readFile(new URL('../supabase/setup.sql', import.meta.url), 'utf8');
await db.exec(setup);
await db.exec(setup);
await db.exec("insert into public.qatta_admins values ('11111111-1111-4111-8111-111111111111')");
const data = (await db.query('select data from public.qatta_ledger')).rows[0].data;
await db.exec('set role anon');
assert.equal((await db.query('select * from public.qatta_ledger')).rows.length, 1);
await assert.rejects(db.query("update public.qatta_ledger set revision=9"), /permission denied/);
await assert.rejects(db.query("select * from public.save_qatta(0,$1)", [data]), /permission denied/);
console.log('PASS anonymous visitors can read, but cannot write or invoke save.');
await db.exec('reset role; set role authenticated');
await db.query("select set_config('request.jwt.claim.sub',$1,false)", ['22222222-2222-4222-8222-222222222222']);
assert.equal((await db.query('select * from public.qatta_admins')).rows.length, 0);
assert.equal((await db.query('update public.qatta_ledger set revision=9 returning id')).rows.length, 0);
await assert.rejects(db.query("insert into public.qatta_admins values ('22222222-2222-4222-8222-222222222222')"), /permission denied/);
await assert.rejects(db.query('select * from public.save_qatta(0,$1)', [data]), /QATTA_FORBIDDEN/);
console.log('PASS a signed-in non-admin cannot update or promote themselves.');
await db.query("select set_config('request.jwt.claim.sub',$1,false)", ['11111111-1111-4111-8111-111111111111']);
assert.equal((await db.query('select * from public.qatta_admins')).rows.length, 1);
data.months['2026-09'] = { dues: 25000, recipient: 'أبو فهد', transfer: '', members: [
  { id: 'member-1', name: 'محمد', paid: 12550, date: '2026-09-16', note: '' }
], expenses: [{ id: 'expense-1', title: 'قهوة', amount: 6025, date: '2026-09-16', paid: true, category: 'supplies' }] };
let saved = (await db.query('select * from public.save_qatta(0,$1)', [data])).rows[0];
assert.equal(saved.revision, 1);
assert.equal(saved.data.months['2026-09'].members[0].paid, 12550);
await assert.rejects(db.query('select * from public.save_qatta(0,$1)', [data]), /QATTA_CONFLICT/);
console.log('PASS admin save persists data and rejects a stale revision.');
const bad = structuredClone(data);
bad.months['2026-09'].members[0].paid = 50000;
await assert.rejects(db.query('select * from public.save_qatta(1,$1)', [bad]), /check constraint/);
bad.months['2026-09'].members[0].paid = 12550;
bad.months['2026-09'].members[0].date = '2026-02-30';
await assert.rejects(db.query('select * from public.save_qatta(1,$1)', [bad]), /check constraint/);
bad.months['2026-09'].members[0].date = '2026-09-16';
delete bad.months['2026-09'].members[0].note;
await assert.rejects(db.query('select * from public.save_qatta(1,$1)', [bad]), /check constraint/);
assert.equal((await db.query('select revision from public.qatta_ledger')).rows[0].revision, 1);
console.log('PASS server validation rejects overpayments, invalid dates and malformed data atomically.');
await db.exec('reset role');
await db.exec(setup);
assert.equal((await db.query('select revision from public.qatta_ledger')).rows[0].revision, 1);
console.log('PASS setup can be re-run without replacing existing ledger data.');
await db.close();
