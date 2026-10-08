import { afterAll, beforeEach, describe, expect, test } from 'bun:test';
import { randomBytes } from 'node:crypto';
import type { Auth } from '../src/auth';
import { createApp } from '../src/app';
import { connect } from '../src/db';
import { ApiError } from '../src/errors';
import { type Announce, ChargingHistory, ResumeLost, derive, parsePage, probe, resume, sync, upsertPage, window } from '../src/history';
import type { Telemetry } from '../src/telemetry';
import { HistoryCallError, TeslaLink } from '../src/tesla';

const url = process.env.TEST_DATABASE_URL;
if (!url || new URL(url).pathname !== '/volta_test' || !['127.0.0.1', 'localhost'].includes(new URL(url).hostname)) throw new Error('Tests require an isolated localhost database named volta_test. Run bun run test:local.');
const owner = connect(url, false, 120000), reader = connect(process.env.TESLAMATE_DATABASE_URL!, true), authDb = connect(process.env.AUTH_DATABASE_URL!);

// Synthetic, valid-format VINs only. C shares A's last six characters.
const VIN_A = '5YJ3E1EA1PF000001', VIN_B = '5YJ3E1EA1PF000002', VIN_C = '7SAYGDEE1PF000001', VIN_X = '5YJ3E1EA1PF999999';
const ACCOUNT_1 = 'a'.repeat(64), ACCOUNT_2 = 'b'.repeat(64);
const SINCE = '2020-01-01T00:00:00Z', UNTIL = '2020-06-01T00:00:00Z';
const SECRET = 'synthetic-commander-secret-0000000000', DEVICE = 'synthetic-device-token';

const fee = (overrides: Record<string, unknown> = {}) => ({ sessionFeeId: '10', feeType: 'CHARGING', currencyCode: 'USD', pricingType: 'PAYMENT', uom: 'kwh', isPaid: true, status: 'PAID',
  amounts: { rateBase: '0.46', usageBase: '40', usageTier1: '0', totalBase: '18.4', totalDue: '18.4', netDue: '18.4' }, ...overrides });
const session = (id: number, vin: string | null, day = id) => ({ sessionId: String(id), vin, siteLocationName: 'Synthetic Site, CA', chargeStartDateTime: `2020-02-${String(day).padStart(2, '0')}T11:43:45-07:00`,
  chargeStopDateTime: `2020-02-${String(day).padStart(2, '0')}T12:08:35-07:00`, unlatchDateTime: null, countryCode: 'US', billingType: 'IMMEDIATE', vehicleMakeType: 'TSLA',
  fees: [fee()], invoices: [{ fileName: 'SYNTHETIC-FILE.pdf', contentId: 'SYNTHETIC-CONTENT-ID', invoiceType: 'IMMEDIATE' }] });

// Loopback fake commander: link status plus scripted history pages.
let link = { connected: true, enabled: true, account: ACCOUNT_1 as string | null };
let pages: (q: URLSearchParams) => { status?: number; body: unknown } | Promise<{ status?: number; body: unknown }> = () => ({ body: null });
let historyCalls: URLSearchParams[] = [];
// Runs inside a link-status request, before commander answers it.
let onStatus: (() => Promise<void>) | null = null;
const reply = (q: URLSearchParams, sessions: unknown[], extra: Record<string, unknown> = {}) => ({ body: { ok: true, account: link.account, pageNo: Number(q.get('pageNo')), pageSize: Number(q.get('pageSize')),
  startTime: q.get('startTime'), endTime: q.get('endTime'), totalResults: null, totalResultsLocation: 'none', sessions, rejected: 0, ...extra } });
const commander = Bun.serve({ hostname: '127.0.0.1', port: 0, async fetch(req) {
  const u = new URL(req.url);
  if (req.headers.get('authorization') !== `Bearer ${SECRET}`) return Response.json({ error: { code: 'unauthorized' } }, { status: 401 });
  if (u.pathname === '/oauth/status') await onStatus?.();
  if (u.pathname === '/oauth/status') return Response.json({ available: true, connected: link.connected, needsReauth: false, linkPending: false, collector: { enabled: false },
    budget: { monthlyLimitUsd: 10, spentUsd: 0, paused: false }, history: { enabled: link.enabled, ...(link.connected && link.account ? { account: link.account } : {}) } });
  if (u.pathname === '/v1/history/charging') {
    historyCalls.push(u.searchParams);
    const r = await pages(u.searchParams);
    return Response.json(r.body, { status: r.status ?? 200, headers: r.status === 429 ? { 'Retry-After': '3600' } : {} });
  }
  return Response.json({ error: { code: 'not_found' } }, { status: 404 });
} });
const tesla = new TeslaLink(`http://127.0.0.1:${commander.port}`, SECRET);
const auth = { authenticate: async (header?: string) => { if (header !== `Bearer ${DEVICE}`) throw new ApiError(401, 'unauthorized', 'Valid device token required'); return { id: 7, name: 'Synthetic phone', createdAt: null, lastSeenAt: null }; } } as unknown as Auth;
const history = new ChargingHistory(authDb, reader, tesla);
const app = createApp(auth, {} as Telemetry, () => {}, tesla, history);
const get = (path: string, a = app) => a.request(path, { headers: { Authorization: `Bearer ${DEVICE}` } });
const body = async (r: Response) => { const text = await r.text(); return { status: r.status, text, json: JSON.parse(text) as any }; };
const window1 = window(SINCE, UNTIL, 2);
// Commander-shaped fees through the same boundary parser the CLI uses.
const fees = (...list: unknown[]) => parsePage({ ok: true, account: ACCOUNT_1, pageNo: 0, pageSize: 1, startTime: SINCE, endTime: UNTIL, totalResults: null, totalResultsLocation: 'none',
  sessions: [{ ...session(1, null), fees: list }], rejected: 0 }, { pageNo: 0, pageSize: 1, startTime: SINCE, endTime: UNTIL }).sessions[0]!.fees;
const store = (sessions: unknown[], account = ACCOUNT_1) => upsertPage(authDb, parsePage({ ok: true, account, pageNo: 0, pageSize: 50, startTime: SINCE, endTime: UNTIL, totalResults: null, totalResultsLocation: 'none', sessions, rejected: 0 }, { pageNo: 0, pageSize: 50, startTime: SINCE, endTime: UNTIL }));

// Synthetic PostgreSQL fault: the next matching update of a sync row fails.
const fault = (when: string) => owner.unsafe(`CREATE FUNCTION volta.synthetic_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic fault'; END $$;
  CREATE TRIGGER synthetic_fault BEFORE UPDATE ON volta.tesla_history_syncs FOR EACH ROW WHEN (${when}) EXECUTE FUNCTION volta.synthetic_fault();`);
const clearFault = () => owner.unsafe('DROP TRIGGER IF EXISTS synthetic_fault ON volta.tesla_history_syncs; DROP FUNCTION IF EXISTS volta.synthetic_fault();');

// Holds the history table locked until the read has passed its first link
// check and is blocked in Postgres, then changes the link before releasing it.
const delayed = async (path: string, change: () => void) => {
  let response!: Promise<Response>;
  await owner.begin(async tx => {
    await tx`LOCK TABLE volta.tesla_charging_sessions IN ACCESS EXCLUSIVE MODE`;
    response = Promise.resolve(get(path));
    let blocked = false;
    for (let i = 0; i < 500 && !blocked; i++) {
      const [w] = await owner`SELECT count(*)::int AS n FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE '%tesla_charging_sessions%' AND pid <> pg_backend_pid()`;
      blocked = w!.n > 0;
      if (!blocked) await Bun.sleep(10);
    }
    expect(blocked).toBe(true);
    change();
  });
  return body(await response);
};

beforeEach(async () => {
  await owner`TRUNCATE public.charges, public.charging_processes, public.positions, public.drives, public.states, public.updates, public.cars, public.car_settings, public.addresses, public.geofences, volta.tesla_charging_sessions, volta.tesla_history_syncs RESTART IDENTITY CASCADE`;
  await owner.file(new URL('./fixtures.sql', import.meta.url));
  // Car 3 keeps its malformed synthetic VIN (TeslaMate requires one), which matches nothing.
  await owner`UPDATE cars SET vin = CASE id WHEN 1 THEN ${VIN_A} WHEN 2 THEN ${VIN_B} ELSE vin END`;
  link = { connected: true, enabled: true, account: ACCOUNT_1 }; historyCalls = []; pages = () => ({ body: null }); onStatus = null;
  await clearFault();
});
afterAll(async () => { commander.stop(true); await Promise.all([owner.end(), reader.end(), authDb.end()]); });

describe('commander page boundary', () => {
  const expected = { pageNo: 0, pageSize: 2, startTime: SINCE, endTime: UNTIL };
  const good = () => ({ ok: true, account: ACCOUNT_1, pageNo: 0, pageSize: 2, startTime: SINCE, endTime: UNTIL, totalResults: 3, totalResultsLocation: 'top', sessions: [session(1, VIN_A)], rejected: 0 });
  test('accepts the documented shape and refuses anything off-contract', () => {
    expect(parsePage(good(), expected).sessions[0]!.fees[0]!.amounts.totalDue).toBe('18.4');
    const broken: ((p: any) => void)[] = [
      p => { p.ok = false; }, p => { p.account = 'A'.repeat(64); }, p => { p.pageNo = 1; }, p => { p.pageSize = 3; }, p => { p.endTime = '2020-06-02T00:00:00Z'; },
      p => { p.totalResults = -1; }, p => { p.totalResultsLocation = 'body'; }, p => { p.sessions = [session(1, VIN_A), session(2, VIN_A), session(3, VIN_A)]; },
      p => { p.sessions = [session(1, VIN_A), session(1, VIN_A)]; }, p => { p.rejected = 2; }, p => { p.sessions[0].sessionId = 1; }, p => { p.sessions[0].vin = 'SYNTHETIC000000001'; },
      p => { p.sessions[0].siteLocationName = 'line\nbreak'; }, p => { p.sessions[0].fees[0].amounts.totalDue = '1e2'; }, p => { p.sessions[0].fees[0].amounts.rawCharge = '1'; },
      p => { p.sessions[0].fees[0].amounts.totalDue = 18.4; }, p => { p.sessions[0].invoices[0].fileName = '../x.pdf'; }, p => { p.sessions[0].fees = Array(21).fill(fee()); },
      p => { p.sessions[0].chargeStartDateTime = 'yesterday'; }, p => { p.sessions = {}; },
    ];
    for (const mutate of broken) {
      const p = good(); mutate(p);
      expect(() => parsePage(p, expected)).toThrow(HistoryCallError);
    }
    expect(() => parsePage(null, expected)).toThrow(HistoryCallError);
  });
  test('derived totals never double count, mix currencies or invent energy', () => {
    // Tesla's published example: usageBase 40 with usageTier2 24, but only totalBase billed.
    expect(derive(fees(fee({ amounts: { usageBase: '40', usageTier2: '24', totalBase: '18.4', totalDue: '18.4', netDue: '18.4' } })))).toEqual({ currency: 'USD', totalDue: '18.4', netDue: '18.4', billedEnergyKwh: null });
    expect(derive(fees(fee())).billedEnergyKwh).toBe('40');
    expect(derive(fees(fee({ uom: 'min' }))).billedEnergyKwh).toBeNull();
    expect(derive(fees(fee(), fee({ feeType: 'CHARGING' }))).billedEnergyKwh).toBeNull();
    // Per-fee totalDue already includes its base and tiers; only fee totals are summed, exactly.
    expect(derive(fees(fee({ amounts: { totalDue: '0.1', netDue: '0.1', totalBase: '0.1' } }), fee({ feeType: 'PARKING', uom: 'min', amounts: { totalDue: '0.2', netDue: '-0.05' } })))).toEqual({ currency: 'USD', totalDue: '0.3', netDue: '0.05', billedEnergyKwh: null });
    expect(derive(fees(fee(), fee({ feeType: 'PARKING', currencyCode: 'CAD' })))).toMatchObject({ currency: null, totalDue: null, netDue: null });
    expect(derive(fees(fee({ currencyCode: null })))).toMatchObject({ currency: null, totalDue: null });
    expect(derive(fees(fee(), fee({ feeType: 'PARKING', amounts: { netDue: '1' } })))).toMatchObject({ currency: 'USD', totalDue: null, netDue: '19.4' });
    expect(derive(fees())).toEqual({ currency: null, totalDue: null, netDue: null, billedEnergyKwh: null });
  });
});

describe('storage and device reads', () => {
  test('upserts are idempotent per account and session', async () => {
    expect(await store([session(1, VIN_A), session(2, VIN_B)])).toEqual({ inserted: 2, updated: 0, unchanged: 0 });
    expect(await store([session(1, VIN_A), session(2, VIN_B)])).toEqual({ inserted: 0, updated: 0, unchanged: 2 });
    const changed = session(2, VIN_B); changed.fees = [fee({ isPaid: false, status: 'PENDING' })];
    expect(await store([session(1, VIN_A), changed])).toEqual({ inserted: 0, updated: 1, unchanged: 1 });
    // The same Tesla session ID under another link is a separate, isolated row.
    expect(await store([session(1, VIN_A)], ACCOUNT_2)).toEqual({ inserted: 1, updated: 0, unchanged: 0 });
    const [row] = await owner`SELECT count(*)::int AS n, sum(total_due)::text AS total FROM volta.tesla_charging_sessions`;
    expect(row).toEqual({ n: 3, total: '55.2' });
  });

  test('vehicle reads match the exact full VIN and expose no private fields', async () => {
    await store([session(1, VIN_A), session(2, VIN_C), session(3, VIN_X), session(4, null), session(5, VIN_B), session(6, VIN_A)]);
    const r = await body(await get('/v1/vehicles/1/tesla-charging-sessions'));
    expect(r.status).toBe(200);
    expect(r.json.items.map((i: any) => i.id)).toEqual(['6', '1']);
    expect(r.json.items[0]).toEqual({ id: '6', source: 'tesla_billed', site: 'Synthetic Site, CA', countryCode: 'US', startedAt: '2020-02-06T18:43:45.000Z', endedAt: '2020-02-06T19:08:35.000Z', unlatchedAt: null,
      billingType: 'IMMEDIATE', billedEnergyKwh: 40, currency: 'USD', totalDue: 18.4, netDue: 18.4,
      fees: [{ type: 'CHARGING', currency: 'USD', pricingType: 'PAYMENT', unit: 'kwh', isPaid: true, status: 'PAID', totalDue: 18.4, netDue: 18.4 }], invoiceCount: 1 });
    for (const secret of [VIN_A, VIN_C, '000001', 'SYNTHETIC-CONTENT-ID', 'SYNTHETIC-FILE', ACCOUNT_1, 'usageTier']) expect(r.text).not.toContain(secret);
    expect((await body(await get('/v1/vehicles/2/tesla-charging-sessions'))).json.items.map((i: any) => i.id)).toEqual(['5']);
    // A car with a malformed VIN matches nothing, not even rows with a null VIN.
    expect((await body(await get('/v1/vehicles/3/tesla-charging-sessions'))).json).toEqual({ items: [], nextCursor: null });
    expect((await get('/v1/vehicles/99/tesla-charging-sessions')).status).toBe(404);
    const summary = (await body(await get('/v1/tesla/charging-history'))).json;
    expect(summary).toEqual({ available: true, enabled: true, connected: true, sessions: 6, unmatched: 3, lastSync: null });
  });

  test('cursor pages are stable, scoped and validated', async () => {
    await store([1, 2, 3, 4, 5].map(id => session(id, VIN_A)));
    const first = (await body(await get('/v1/vehicles/1/tesla-charging-sessions?limit=2'))).json;
    expect(first.items.map((i: any) => i.id)).toEqual(['5', '4']);
    const second = (await body(await get(`/v1/vehicles/1/tesla-charging-sessions?limit=2&cursor=${first.nextCursor}`))).json;
    const third = (await body(await get(`/v1/vehicles/1/tesla-charging-sessions?limit=2&cursor=${second.nextCursor}`))).json;
    expect([...second.items, ...third.items].map((i: any) => i.id)).toEqual(['3', '2', '1']);
    expect(third.nextCursor).toBeNull();
    for (const bad of [`cursor=${first.nextCursor}x!`, 'cursor=e30', 'limit=51', 'limit=0']) expect((await get(`/v1/vehicles/1/tesla-charging-sessions?${bad}`)).status).toBe(400);
    expect((await get(`/v1/vehicles/2/tesla-charging-sessions?cursor=${first.nextCursor}`)).status).toBe(400);
  });

  test('a cursor continues only the link that issued it', async () => {
    await store([session(1, VIN_A), session(2, VIN_A)]);
    await store([session(3, VIN_A), session(4, VIN_A)], ACCOUNT_2);
    const page = async (query: string) => body(await get(`/v1/vehicles/1/tesla-charging-sessions?${query}`));
    const ids = (r: { json: any }) => r.json.items.map((i: any) => i.id);
    const a = await page('limit=1');
    expect(ids(a)).toEqual(['2']);
    // The cursor carries no namespace, VIN or account identifier.
    const decoded = Buffer.from(a.json.nextCursor, 'base64url').toString();
    for (const secret of [ACCOUNT_1, VIN_A, 'aaaaaaaa']) expect(decoded).not.toContain(secret);
    // Same link: the continuation keeps its place.
    expect(ids(await page(`limit=1&cursor=${a.json.nextCursor}`))).toEqual(['1']);
    // Relink to B: A's cursor is refused rather than applied to B's rows, and a fresh read sees all of B.
    link.account = ACCOUNT_2;
    const stale = await page(`limit=1&cursor=${a.json.nextCursor}`);
    expect([stale.status, stale.json.error?.code]).toEqual([409, 'tesla_link_changed']);
    expect(stale.text).not.toContain('Synthetic Site');
    const b = await page('limit=1');
    expect(ids(b)).toEqual(['4']);
    expect(ids(await page(`limit=2&cursor=${b.json.nextCursor}`))).toEqual(['3']);
    expect(ids(await page('limit=2'))).toEqual(['4', '3']);
    // Replacement back to A refuses B's cursor too; a disconnect refuses any cursor.
    link.account = ACCOUNT_1;
    expect((await page(`limit=1&cursor=${b.json.nextCursor}`)).json.error?.code).toBe('tesla_link_changed');
    link = { connected: false, enabled: true, account: null };
    expect((await page(`limit=1&cursor=${a.json.nextCursor}`)).json.error?.code).toBe('tesla_not_connected');
    link = { connected: true, enabled: true, account: ACCOUNT_1 };
    // A relink while the continuation's query is in flight discards its rows.
    const racing = await delayed(`/v1/vehicles/1/tesla-charging-sessions?limit=1&cursor=${a.json.nextCursor}`, () => { link.account = ACCOUNT_2; });
    expect([racing.status, racing.json.error?.code]).toEqual([409, 'tesla_link_changed']);
    link.account = ACCOUNT_1;
    // Tampered, legacy (unbound), extended and oversized cursors are rejected.
    const fields = JSON.parse(decoded);
    const encode = (v: unknown) => Buffer.from(JSON.stringify(v)).toString('base64url');
    const forged = await page(`limit=1&cursor=${encode({ ...fields, link: 'A'.repeat(22) })}`);
    expect([forged.status, forged.json.error?.code]).toEqual([409, 'tesla_link_changed']);
    const { v, link: _, ...legacy } = fields;
    for (const bad of [encode(legacy), encode({ ...fields, v: 1 }), encode({ ...fields, extra: 1 }), encode({ ...fields, link: 'short' }), 'A'.repeat(513)]) {
      const r = await page(`limit=1&cursor=${bad}`);
      expect([r.status, r.json.error?.code]).toEqual([400, 'invalid_input']);
    }
  });

  test('stored history follows the current link only', async () => {
    await store([session(1, VIN_A)]);
    await store([session(2, VIN_A)], ACCOUNT_2);
    const ids = async () => (await body(await get('/v1/vehicles/1/tesla-charging-sessions'))).json.items.map((i: any) => i.id);
    expect(await ids()).toEqual(['1']);
    link.account = ACCOUNT_2; expect(await ids()).toEqual(['2']);
    link = { connected: false, enabled: true, account: null };
    const r = await body(await get('/v1/vehicles/1/tesla-charging-sessions'));
    expect(r.status).toBe(409); expect(r.json.error.code).toBe('tesla_not_connected');
    expect((await body(await get('/v1/tesla/charging-history'))).json).toEqual({ available: true, enabled: true, connected: false, sessions: 0, unmatched: 0, lastSync: null });
    // The device-facing Tesla status contract is unchanged: no namespace field.
    link = { connected: true, enabled: true, account: ACCOUNT_1 };
    expect(JSON.stringify(await tesla.status())).not.toContain(ACCOUNT_1);
    const off = createApp(auth, {} as Telemetry, () => {}, null, new ChargingHistory(authDb, reader, null));
    expect((await body(await get('/v1/vehicles/1/tesla-charging-sessions', off))).status).toBe(501);
    expect((await body(await get('/v1/tesla/charging-history', off))).json).toMatchObject({ available: false, connected: false });
    expect((await get('/v1/tesla/charging-history', createApp(auth, {} as Telemetry, () => {}))).status).toBe(501);
    expect((await app.request('/v1/vehicles/1/tesla-charging-sessions')).status).toBe(401);
  });

  test('a disconnect or relink during an in-flight read discards its rows', async () => {
    await store([session(1, VIN_A)]);
    await store([session(2, VIN_A)], ACCOUNT_2);
    const reset = () => { link = { connected: true, enabled: true, account: ACCOUNT_1 }; };
    // Control: an unchanged link returns account 1's rows through the same delay.
    expect((await delayed('/v1/vehicles/1/tesla-charging-sessions', () => {})).json.items.map((i: any) => i.id)).toEqual(['1']);
    expect((await delayed('/v1/tesla/charging-history', () => {})).json).toMatchObject({ connected: true, sessions: 1 });
    for (const [name, change] of [['disconnect', () => { link = { connected: false, enabled: true, account: null }; }], ['relink', () => { link.account = ACCOUNT_2; }]] as const) {
      for (const path of ['/v1/vehicles/1/tesla-charging-sessions', '/v1/tesla/charging-history']) {
        reset();
        const r = await delayed(path, change);
        expect([name, path, r.status, r.json.error?.code]).toEqual([name, path, 409, 'tesla_link_changed']);
        expect(r.text).not.toContain('Synthetic Site');
        expect(r.text).not.toContain('"sessions"');
      }
    }
    // A commander failure on the second check fails closed too.
    reset();
    const broken = new ChargingHistory(authDb, reader, Object.assign(Object.create(tesla), { historyLink: (() => { let n = 0; return async () => { if (n++) throw new ApiError(503, 'tesla_unavailable', 'x'); return { enabled: true, account: ACCOUNT_1 }; }; })() }));
    expect((await body(await get('/v1/vehicles/1/tesla-charging-sessions', createApp(auth, {} as Telemetry, () => {}, tesla, broken)))).status).toBe(503);
  });

  test('database roles: only volta_auth touches history; the reader cannot', async () => {
    // Await inside try: postgres.js queries are lazy thenables that expect().rejects does not drive.
    const denied = async (query: () => PromiseLike<unknown>) => { try { await query(); return false; } catch (error) { return /permission denied|read-only transaction/.test(String((error as Error).message)); } };
    await store([session(1, VIN_A)]);
    expect(await denied(() => reader`SELECT 1 FROM volta.tesla_charging_sessions`)).toBe(true);
    expect(await denied(() => reader`SELECT 1 FROM volta.tesla_history_syncs`)).toBe(true);
    expect(await denied(() => reader`INSERT INTO volta.tesla_history_syncs (account_key, window_start, window_end, first_page, pages, received, rejected, inserted, updated, unchanged, window_complete, outcome, started_at)
      VALUES (${ACCOUNT_1}, now(), now(), 0, 0, 0, 0, 0, 0, 0, false, 'x', now())`)).toBe(true);
    expect(await denied(() => authDb`CREATE TABLE volta.extra (id int)`)).toBe(true);
    expect(await denied(() => authDb`UPDATE public.cars SET name = 'x'`)).toBe(true);
    const [check] = await owner`SELECT has_table_privilege('volta_reader', 'volta.tesla_charging_sessions', 'SELECT') AS reader, has_table_privilege('volta_auth', 'volta.tesla_charging_sessions', 'SELECT,INSERT,UPDATE,DELETE') AS auth`;
    expect(check).toEqual({ reader: false, auth: true });
    expect((await authDb`SELECT session_id FROM volta.tesla_charging_sessions`).length).toBe(1);
  });
});

describe('operator probe and sync', () => {
  const synced = (o: Partial<Parameters<typeof sync>[2]> = {}, announce?: Announce) => sync(authDb, tesla, { ...window1, firstPage: 1, maxPages: 5, apply: true, ...o }, 0, announce);
  // Captures the token a run hands the operator before its first call.
  const announced = () => { const box = { token: '' }; return { box, announce: async (t: string) => { box.token = t; } }; };

  test('probe reads one page, stores nothing and prints no identifiers', async () => {
    pages = q => reply(q, [session(11, VIN_A), session(12, null)], { totalResults: 7, totalResultsLocation: 'top' });
    const out = await probe(tesla, window1, 1);
    expect(historyCalls).toHaveLength(1);
    expect(Object.fromEntries(historyCalls[0]!)).toEqual({ pageNo: '1', pageSize: '2', startTime: SINCE, endTime: UNTIL, sortOrder: 'ASC' });
    expect(out).toMatchObject({ pageNo: 1, received: 2, rejected: 0, totalResults: 7, totalResultsLocation: 'top', withVin: 1, earliestStart: '2020-02-11T18:43:45.000Z', latestStart: '2020-02-12T18:43:45.000Z' });
    expect(out.pageDigest).toMatch(/^[a-f0-9]{16}$/);
    for (const secret of [VIN_A, '"11"', 'SYNTHETIC-CONTENT-ID', ACCOUNT_1]) expect(JSON.stringify(out)).not.toContain(secret);
    expect((await owner`SELECT count(*)::int AS n FROM volta.tesla_charging_sessions`)[0]!.n).toBe(0);
  });

  test('dry run makes no call; apply pages to an empty page and is idempotent', async () => {
    const byPage: Record<string, unknown[]> = { 1: [session(1, VIN_A), session(2, VIN_A)], 2: [session(3, VIN_X)], 3: [] };
    pages = q => reply(q, byPage[q.get('pageNo')!] ?? []);
    expect(await sync(authDb, tesla, { ...window1, firstPage: 1, maxPages: 5, apply: false })).toEqual({ applied: false, plan: { startTime: SINCE, endTime: UNTIL, firstPage: 1, pageSize: 2, maxCalls: 5 }, calls: 0 });
    expect(historyCalls).toHaveLength(0);
    // A short page is followed by one more call; an empty page ends paging, but
    // without Tesla's total it does not prove the window complete.
    expect(await synced()).toMatchObject({ applied: true, calls: 3, pages: 3, received: 3, inserted: 3, windowComplete: false, outcome: 'end_unverified', nextPage: null, resume: null });
    expect(historyCalls.map(q => q.get('pageNo'))).toEqual(['1', '2', '3']);
    pages = q => reply(q, byPage[q.get('pageNo')!] ?? [], { totalResults: 3, totalResultsLocation: 'response' });
    expect(await synced()).toMatchObject({ inserted: 0, updated: 0, unchanged: 3, windowComplete: true, outcome: 'total_reached' });
    expect((await body(await get('/v1/tesla/charging-history'))).json).toMatchObject({ sessions: 3, unmatched: 1, lastSync: { windowStart: '2020-01-01T00:00:00.000Z', windowEnd: '2020-06-01T00:00:00.000Z', windowComplete: true, outcome: 'total_reached' } });
  });

  test('anomalies stop before the suspect page is written', async () => {
    // Page base wrong or ignored: page 2 repeats page 1.
    pages = q => reply(q, [session(1, VIN_A), session(2, VIN_A)]);
    expect(await synced()).toMatchObject({ calls: 2, inserted: 2, windowComplete: false, outcome: 'repeated_page', nextPage: null });
    await owner`TRUNCATE volta.tesla_charging_sessions, volta.tesla_history_syncs`;
    // The account changes between pages: nothing from the new link is written under either.
    pages = q => { if (q.get('pageNo') === '2') link.account = ACCOUNT_2; return reply(q, [session(Number(q.get('pageNo')) * 10, VIN_A), session(Number(q.get('pageNo')) * 10 + 1, VIN_A)]); };
    expect(await synced()).toMatchObject({ calls: 2, inserted: 2, outcome: 'account_changed', windowComplete: false });
    expect((await owner`SELECT array_agg(DISTINCT account_key) AS a FROM volta.tesla_charging_sessions`)[0]!.a).toEqual([ACCOUNT_1]);
    link.account = ACCOUNT_1;
    // totalResults that changes mid-run is not trusted.
    pages = q => reply(q, [session(Number(q.get('pageNo')) * 100, VIN_A, 3), session(Number(q.get('pageNo')) * 100 + 1, VIN_A, 4)], { totalResults: q.get('pageNo') === '1' ? 10 : 11, totalResultsLocation: 'top' });
    expect(await synced()).toMatchObject({ calls: 2, outcome: 'total_changed', windowComplete: false });
  });

  test('completeness needs evidence; caps and refusals stop with a resume page', async () => {
    let n = 0;
    pages = q => reply(q, [session(++n, VIN_A), session(++n, VIN_A)]);
    expect(await synced({ maxPages: 3 })).toMatchObject({ calls: 3, received: 6, windowComplete: false, outcome: 'max_pages', nextPage: 4, resume: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/) });
    // totalResults reached: stop without an extra call.
    pages = q => reply(q, [session(++n, VIN_A), session(++n, VIN_A)].slice(0, q.get('pageNo') === '2' ? 1 : 2), { totalResults: 3, totalResultsLocation: 'response' });
    historyCalls = [];
    expect(await synced()).toMatchObject({ calls: 2, received: 3, windowComplete: true, outcome: 'total_reached' });
    // An empty first page might be the wrong page base: unproven unless Tesla reports zero.
    pages = q => reply(q, []);
    expect(await synced({ firstPage: 0 })).toMatchObject({ calls: 1, windowComplete: false, outcome: 'empty_first_page' });
    pages = q => reply(q, [], { totalResults: 0, totalResultsLocation: 'top' });
    expect(await synced({ firstPage: 0 })).toMatchObject({ windowComplete: true, outcome: 'total_reached' });
    // Commander refusals end the run and report where to resume.
    pages = q => q.get('pageNo') === '1' ? reply(q, [session(++n, VIN_A), session(++n, VIN_A)]) : { status: 429, body: { error: { code: 'history_daily_limit', message: 'x' } } };
    expect(await synced()).toMatchObject({ calls: 2, pages: 1, windowComplete: false, outcome: 'history_daily_limit', nextPage: 2 });
    pages = q => ({ body: { ...reply(q, []).body as object, account: 'not-an-account' } });
    expect(await synced()).toMatchObject({ calls: 1, pages: 0, outcome: 'commander_invalid_page' });
    await expect(synced({ maxPages: 21 })).rejects.toThrow(RangeError);
    expect(() => window('2020-01-01', UNTIL, 2)).toThrow(RangeError);
    expect(() => window(UNTIL, SINCE, 2)).toThrow(RangeError);
    expect(() => window(SINCE, '2999-01-01T00:00:00Z', 2)).toThrow(RangeError);
    expect(() => window(SINCE, UNTIL, 51)).toThrow(RangeError);
  });

  test('contradicted or partial coverage is never reported complete', async () => {
    const outcome = async () => (await owner`SELECT window_complete, outcome, chain_received, chain_rejected, total_results FROM volta.tesla_history_syncs ORDER BY id DESC LIMIT 1`)[0];
    // 1 received, 10 advertised, then an empty page.
    pages = q => reply(q, q.get('pageNo') === '1' ? [session(1, VIN_A)] : [], { totalResults: 10, totalResultsLocation: 'top' });
    expect(await synced()).toMatchObject({ calls: 2, received: 1, windowComplete: false, outcome: 'total_mismatch', nextPage: null });
    expect(await outcome()).toEqual({ window_complete: false, outcome: 'total_mismatch', chain_received: 1, chain_rejected: 0, total_results: 10 });
    // 1 kept and 1 rejected cover the advertised 2, but a rejected row is missing.
    pages = q => reply(q, [session(2, VIN_A)], { totalResults: 2, totalResultsLocation: 'top', rejected: 1 });
    expect(await synced()).toMatchObject({ calls: 1, received: 1, rejected: 1, windowComplete: false, outcome: 'rows_rejected', nextPage: null });
    expect(await outcome()).toMatchObject({ window_complete: false, chain_rejected: 1 });
    // A rejected row anywhere in the chain also blocks completion through an empty page.
    pages = q => q.get('pageNo') === '1' ? reply(q, [session(3, VIN_A)], { rejected: 1 }) : reply(q, []);
    expect(await synced()).toMatchObject({ calls: 2, windowComplete: false, outcome: 'end_unverified' });
    // More rows than Tesla advertised.
    pages = q => reply(q, [session(4, VIN_A), session(5, VIN_A)], { totalResults: 1, totalResultsLocation: 'top' });
    expect(await synced()).toMatchObject({ calls: 1, windowComplete: false, outcome: 'total_exceeded' });
    // Storage refuses a complete flag without matching evidence.
    const denied = async (query: () => PromiseLike<unknown>) => { try { await query(); return false; } catch (error) { return /check constraint/.test(String((error as Error).message)); } };
    expect(await denied(() => authDb`INSERT INTO volta.tesla_history_syncs (account_key, window_start, window_end, first_page, page_size, pages, received, rejected, inserted, updated, unchanged,
      chain_pages, chain_received, chain_rejected, total_results, seen_ids, window_complete, outcome, started_at)
      VALUES (${ACCOUNT_1}, ${SINCE}, ${UNTIL}, 1, 2, 1, 1, 0, 1, 0, 0, 1, 1, 0, 10, '{1}', true, 'x', now())`)).toBe(true);
  });

  test('conflicting totals end the chain, before writing, and never complete it', async () => {
    const last = async () => (await owner`SELECT window_complete, outcome, next_page, chain_received, total_results FROM volta.tesla_history_syncs ORDER BY id DESC LIMIT 1`)[0];
    const stored = async () => (await owner`SELECT array_agg(session_id::text ORDER BY session_id) AS ids FROM volta.tesla_charging_sessions`)[0]!.ids;
    // Page 1 advertises 2 rows; page 2 brings the second row, but commander saw
    // two different totals (it then reports none). Matching counts prove nothing.
    pages = q => q.get('pageNo') === '1' ? reply(q, [session(1, VIN_A)], { totalResults: 2, totalResultsLocation: 'top' })
      : reply(q, [session(2, VIN_A)], { totalResults: null, totalResultsLocation: 'conflict' });
    const token = ((await synced({ maxPages: 1 })) as any).resume as string;
    expect(await resume(authDb, tesla, { token, maxPages: 3, apply: true }, 0)).toMatchObject({ calls: 1, pages: 1, inserted: 0, windowComplete: false, outcome: 'total_conflict', nextPage: null, resume: null });
    expect(await last()).toEqual({ window_complete: false, outcome: 'total_conflict', next_page: null, chain_received: 1, total_results: 2 });
    expect(await stored()).toEqual(['1']);
    expect((await body(await get('/v1/tesla/charging-history'))).json.lastSync).toMatchObject({ windowComplete: false, outcome: 'total_conflict' });
    // Within one run, and on a first page, the same.
    await owner`TRUNCATE volta.tesla_charging_sessions, volta.tesla_history_syncs`;
    expect(await synced()).toMatchObject({ calls: 2, inserted: 1, windowComplete: false, outcome: 'total_conflict' });
    await owner`TRUNCATE volta.tesla_charging_sessions, volta.tesla_history_syncs`;
    pages = q => reply(q, [session(3, VIN_A)], { totalResults: null, totalResultsLocation: 'conflict' });
    expect(await synced()).toMatchObject({ calls: 1, inserted: 0, outcome: 'total_conflict', resume: null });
    expect(await stored()).toBeNull();
    // Storage refuses a complete flag on any other outcome.
    const denied = async (query: () => PromiseLike<unknown>) => { try { await query(); return false; } catch (error) { return /check constraint/.test(String((error as Error).message)); } };
    expect(await denied(() => authDb`INSERT INTO volta.tesla_history_syncs (account_key, window_start, window_end, first_page, page_size, pages, received, rejected, inserted, updated, unchanged,
      chain_pages, chain_received, chain_rejected, total_results, seen_ids, window_complete, outcome, started_at)
      VALUES (${ACCOUNT_1}, ${SINCE}, ${UNTIL}, 1, 2, 1, 1, 0, 1, 0, 0, 1, 1, 0, 1, '{1}', true, 'total_conflict', now())`)).toBe(true);
  });

  test('a run whose lease lapsed cannot write, release or complete over its successor', async () => {
    const two = (q: URLSearchParams) => reply(q, [session(Number(q.get('pageNo')) * 10, VIN_A), session(Number(q.get('pageNo')) * 10 + 1, VIN_A)]);
    pages = two;
    const token = ((await synced({ maxPages: 1 })) as any).resume as string;
    historyCalls = [];
    // A resumes, moving the chain to its own row and token, then stalls inside
    // its Tesla call past its lease.
    let n = 0, enteredA!: () => void, releaseA!: () => void, enteredB!: () => void, releaseB!: () => void;
    const inA = new Promise<void>(r => { enteredA = r; }), gateA = new Promise<void>(r => { releaseA = r; });
    const inB = new Promise<void>(r => { enteredB = r; }), gateB = new Promise<void>(r => { releaseB = r; });
    pages = async q => { if (++n === 1) { enteredA(); await gateA; return reply(q, [session(901, VIN_A, 7), session(902, VIN_A, 8)]); } return two(q); };
    const A = announced();
    const a = resume(authDb, tesla, { token, maxPages: 1, apply: true }, 0, A.announce).then(() => null, (error: unknown) => error);
    await inA;
    const claim = async (t: string) => (await owner`SELECT claim_owner, resumed_at FROM volta.tesla_history_syncs WHERE resume_hash = sha256(${t}::bytea)`)[0]!;
    const ownerA = (await claim(A.box.token)).claim_owner as Buffer;
    // The token A started from is already retired.
    await expect(resume(authDb, tesla, { token, maxPages: 1, apply: true }, 0)).rejects.toThrow(RangeError);
    await owner`UPDATE volta.tesla_history_syncs SET claimed_at = now() - interval '31 minutes' WHERE resume_hash = sha256(${A.box.token}::bytea)`;
    // B takes over A's lapsed row with a new owner generation, and is held
    // before moving the chain on.
    onStatus = async () => { onStatus = null; enteredB(); await gateB; };
    const B = announced();
    const b = resume(authDb, tesla, { token: A.box.token, maxPages: 1, apply: true }, 0, B.announce);
    await inB;
    const ownerB = (await claim(A.box.token)).claim_owner as Buffer;
    expect(ownerB.equals(ownerA)).toBe(false);
    // A's reply arrives late: its page and progress are not written, and its
    // failure does not release B's claim.
    releaseA();
    expect(await a).toBeInstanceOf(ResumeLost);
    expect((await owner`SELECT count(*)::int AS n FROM volta.tesla_charging_sessions WHERE session_id IN (901, 902)`)[0]!.n).toBe(0);
    expect([...await owner`SELECT chain_pages, outcome, next_page FROM volta.tesla_history_syncs WHERE resume_hash = sha256(${A.box.token}::bytea)`]).toEqual([{ chain_pages: 1, outcome: 'in_progress', next_page: 2 }]);
    expect(((await claim(A.box.token)).claim_owner as Buffer).equals(ownerB)).toBe(true);
    // So a third run is still refused while B holds the token, without a call.
    await expect(resume(authDb, tesla, { token: A.box.token, maxPages: 1, apply: true }, 0)).rejects.toThrow(RangeError);
    expect(n).toBe(1);
    releaseB();
    expect(await b).toMatchObject({ calls: 1, received: 2, inserted: 2, outcome: 'max_pages', nextPage: 3, resume: B.box.token });
    expect(historyCalls.map(q => q.get('pageNo'))).toEqual(['2', '2']);
    // First run, A's row, B's row: each later row continues exactly one earlier one.
    expect((await owner`SELECT count(*)::int AS n FROM volta.tesla_history_syncs WHERE resumed_from IS NOT NULL`)[0]!.n).toBe(2);
    await expect(resume(authDb, tesla, { token: A.box.token, maxPages: 1, apply: true }, 0)).rejects.toThrow(RangeError);
  });

  test('a run that lost its claim stops before calling Tesla, retiring the token or recording its run', async () => {
    pages = q => reply(q, [session(Number(q.get('pageNo')) * 10, VIN_A), session(Number(q.get('pageNo')) * 10 + 1, VIN_A)]);
    let token = ((await synced({ maxPages: 1 })) as any).resume as string;
    // Another run takes the claim while this one checks the link.
    const steal = (t: string) => async () => { onStatus = null; await owner`UPDATE volta.tesla_history_syncs SET claimed_at = now(), claim_owner = ${randomBytes(32)} WHERE resume_hash = sha256(${t}::bytea)`; };
    onStatus = steal(token); historyCalls = [];
    await expect(resume(authDb, tesla, { token, maxPages: 3, apply: true }, 0)).rejects.toThrow(ResumeLost);
    expect(historyCalls).toHaveLength(0);
    // Nor may it retire the token for a changed link.
    token = ((await synced({ maxPages: 1 })) as any).resume as string;
    link.account = ACCOUNT_2; onStatus = steal(token); historyCalls = [];
    await expect(resume(authDb, tesla, { token, maxPages: 3, apply: true }, 0)).rejects.toThrow(ResumeLost);
    expect((await owner`SELECT resumed_at FROM volta.tesla_history_syncs WHERE resume_hash = sha256(${token}::bytea)`)[0]!.resumed_at).toBeNull();
    expect(historyCalls).toHaveLength(0);
    // Nor record its run when the claim on its own row goes during a refused call.
    link.account = ACCOUNT_1;
    token = ((await synced({ maxPages: 1 })) as any).resume as string;
    const C = announced();
    pages = async () => { await steal(C.box.token)(); return { status: 429, body: { error: { code: 'tesla_rate_limited', message: 'x' } } }; };
    await expect(resume(authDb, tesla, { token, maxPages: 3, apply: true }, 0, C.announce)).rejects.toThrow(ResumeLost);
    expect((await owner`SELECT resumed_at, claim_owner IS NOT NULL AS held, outcome, next_page FROM volta.tesla_history_syncs WHERE resume_hash = sha256(${C.box.token}::bytea)`)[0])
      .toEqual({ resumed_at: null, held: true, outcome: 'in_progress', next_page: 2 });
  });

  test('a chain ends at page 200 with no continuation past it', async () => {
    // A stored chain that has reached page 200 (199 full pages of 2 behind it).
    const at200 = async (total: number | null) => {
      const token = randomBytes(32).toString('base64url');
      await owner`INSERT INTO volta.tesla_history_syncs (account_key, window_start, window_end, first_page, page_size, pages, received, rejected, inserted, updated, unchanged,
          chain_pages, chain_received, chain_rejected, total_results, seen_ids, window_complete, outcome, next_page, resume_hash, started_at)
        VALUES (${ACCOUNT_1}, ${SINCE}, ${UNTIL}, 1, 2, 1, 2, 0, 2, 0, 0, 199, 398, 0, ${total}, (SELECT array_agg(g::bigint) FROM generate_series(1, 398) g), false, 'max_pages', 200, sha256(${token}::bytea), now())`;
      historyCalls = [];
      return token;
    };
    pages = q => reply(q, [session(1001, VIN_A, 5), session(1002, VIN_A, 6)]);
    let token = await at200(null);
    expect(await resume(authDb, tesla, { token, maxPages: 1, apply: true }, 0)).toMatchObject({ calls: 1, inserted: 2, windowComplete: false, outcome: 'page_limit', nextPage: null, resume: null });
    expect((await owner`SELECT outcome, next_page, chain_pages FROM volta.tesla_history_syncs ORDER BY id DESC LIMIT 1`)[0]).toEqual({ outcome: 'page_limit', next_page: null, chain_pages: 200 });
    // The token was consumed with the page: it cannot buy page 200 again.
    await expect(resume(authDb, tesla, { token, maxPages: 1, apply: true }, 0)).rejects.toThrow(RangeError);
    expect(historyCalls.map(q => q.get('pageNo'))).toEqual(['200']);
    // A larger allowance still never asks for page 201.
    await owner`TRUNCATE volta.tesla_charging_sessions, volta.tesla_history_syncs`;
    token = await at200(null);
    expect(await resume(authDb, tesla, { token, maxPages: 3, apply: true }, 0)).toMatchObject({ calls: 1, outcome: 'page_limit', nextPage: null });
    expect(historyCalls.map(q => q.get('pageNo'))).toEqual(['200']);
    // If page 200's checkpoint cannot commit, none of it is kept: its rows,
    // its progress and the chain's end roll back together, so the run's own
    // token (printed before the call) still points at page 200.
    await owner`TRUNCATE volta.tesla_charging_sessions, volta.tesla_history_syncs`;
    token = await at200(null);
    await fault("NEW.outcome = 'page_limit'");
    const R = announced();
    await expect(resume(authDb, tesla, { token, maxPages: 1, apply: true }, 0, R.announce)).rejects.toThrow('synthetic fault');
    await clearFault();
    expect((await owner`SELECT count(*)::int AS n FROM volta.tesla_charging_sessions`)[0]!.n).toBe(0);
    expect([...await owner`SELECT outcome, next_page, claim_owner IS NOT NULL AS held FROM volta.tesla_history_syncs WHERE resume_hash = sha256(${R.box.token}::bytea)`]).toEqual([{ outcome: 'in_progress', next_page: 200, held: false }]);
    expect(await resume(authDb, tesla, { token: R.box.token, maxPages: 1, apply: true }, 0)).toMatchObject({ calls: 1, inserted: 2, outcome: 'page_limit', resume: null });
    // Once kept, it is never requested again through either token.
    for (const t of [token, R.box.token]) await expect(resume(authDb, tesla, { token: t, maxPages: 1, apply: true }, 0)).rejects.toThrow(RangeError);
    expect(historyCalls.map(q => q.get('pageNo'))).toEqual(['200', '200']);
    // Tesla's total met exactly on page 200 is still a complete window.
    await owner`TRUNCATE volta.tesla_charging_sessions, volta.tesla_history_syncs`;
    pages = q => reply(q, [session(1001, VIN_A, 5), session(1002, VIN_A, 6)], { totalResults: 400, totalResultsLocation: 'top' });
    token = await at200(400);
    expect(await resume(authDb, tesla, { token, maxPages: 1, apply: true }, 0)).toMatchObject({ calls: 1, windowComplete: true, outcome: 'total_reached', nextPage: null });
  });

  test('each kept page is checkpointed with its progress, so a late failure never re-buys it', async () => {
    const ids = (n: number) => [session(n * 2 - 1, VIN_A, n), session(n * 2, VIN_A, n)];
    pages = q => reply(q, ids(Number(q.get('pageNo'))));
    const row = async (t: string) => (await owner`SELECT outcome, next_page, chain_pages, chain_received, cardinality(seen_ids)::int AS seen, claim_owner IS NOT NULL AS held,
      resumed_at IS NOT NULL AS used FROM volta.tesla_history_syncs WHERE resume_hash = sha256(${t}::bytea)`)[0];
    const stored = async () => (await owner`SELECT count(*)::int AS n FROM volta.tesla_charging_sessions`)[0]!.n;
    // Pages 1 and 2 are kept, then the run's closing record fails.
    await fault("NEW.outcome = 'max_pages'");
    const A = announced();
    await expect(synced({ maxPages: 2 }, A.announce)).rejects.toThrow('synthetic fault');
    await clearFault();
    expect(await stored()).toBe(4);
    expect(await row(A.box.token)).toEqual({ outcome: 'in_progress', next_page: 3, chain_pages: 2, chain_received: 4, seen: 4, held: false, used: false });
    // The printed token continues at the first page not yet kept.
    historyCalls = [];
    expect(await resume(authDb, tesla, { token: A.box.token, maxPages: 1, apply: true }, 0)).toMatchObject({ calls: 1, inserted: 2, outcome: 'max_pages', nextPage: 4 });
    expect(historyCalls.map(q => q.get('pageNo'))).toEqual(['3']);

    // A crash after page 1 is kept: the run resumes at page 2.
    await owner`TRUNCATE volta.tesla_charging_sessions, volta.tesla_history_syncs`;
    const crashOn2 = Object.assign(Object.create(tesla), { chargingHistory: async (q: URLSearchParams) => { if (q.get('pageNo') === '2') throw new TypeError('synthetic crash'); return tesla.chargingHistory(q); } }) as TeslaLink;
    const B = announced();
    await expect(sync(authDb, crashOn2, { ...window1, firstPage: 1, maxPages: 3, apply: true }, 0, B.announce)).rejects.toThrow(TypeError);
    expect(await row(B.box.token)).toMatchObject({ outcome: 'in_progress', next_page: 2, chain_received: 2, held: false });
    historyCalls = [];
    expect(await resume(authDb, tesla, { token: B.box.token, maxPages: 1, apply: true }, 0)).toMatchObject({ calls: 1, outcome: 'max_pages', nextPage: 3 });
    expect(historyCalls.map(q => q.get('pageNo'))).toEqual(['2']);

    // A page whose checkpoint fails is not kept at all, and the run resumes at it.
    await owner`TRUNCATE volta.tesla_charging_sessions, volta.tesla_history_syncs`;
    await fault("NEW.chain_pages = 2");
    const C = announced();
    await expect(synced({ maxPages: 3 }, C.announce)).rejects.toThrow('synthetic fault');
    await clearFault();
    expect(await stored()).toBe(2);
    expect(await row(C.box.token)).toMatchObject({ outcome: 'in_progress', next_page: 2, chain_pages: 1, held: false });

    // If the token cannot be handed over, nothing is called or recorded.
    await owner`TRUNCATE volta.tesla_charging_sessions, volta.tesla_history_syncs`;
    historyCalls = [];
    await expect(synced({}, async () => { throw new Error('synthetic closed output'); })).rejects.toThrow('synthetic closed output');
    expect(historyCalls).toHaveLength(0);
    expect((await owner`SELECT count(*)::int AS n FROM volta.tesla_history_syncs`)[0]!.n).toBe(0);
  });

  test('a stopped run resumes once, from storage, without refetching its pages', async () => {
    const ids = (n: number) => [session(n * 2 - 1, VIN_A, n), session(n * 2, VIN_A, n)];
    pages = q => { const n = Number(q.get('pageNo')); return reply(q, n <= 5 ? ids(n) : [], { totalResults: 10, totalResultsLocation: 'top' }); };
    const first = await synced({ maxPages: 3 }) as any;
    expect(first).toMatchObject({ calls: 3, received: 6, outcome: 'max_pages', nextPage: 4 });
    const token: string = first.resume;
    // The token is opaque: only its hash is stored, and it carries no identifiers.
    expect((await owner`SELECT count(*)::int AS n FROM volta.tesla_history_syncs WHERE resume_hash = sha256(${token}::bytea)`)[0]!.n).toBe(1);
    expect((await owner`SELECT count(*)::int AS n FROM volta.tesla_history_syncs WHERE encode(resume_hash, 'escape') LIKE ${'%' + token + '%'}`)[0]!.n).toBe(0);
    historyCalls = [];
    // Dry run: the stored plan, no call and no claim.
    expect(await resume(authDb, tesla, { token, maxPages: 5, apply: false })).toEqual({ applied: false, plan: { startTime: SINCE, endTime: UNTIL, firstPage: 1, pageSize: 2, nextPage: 4, maxCalls: 5 }, calls: 0 });
    expect(historyCalls).toHaveLength(0);
    expect(await resume(authDb, tesla, { token, maxPages: 5, apply: true }, 0)).toMatchObject({ applied: true, calls: 2, received: 4, inserted: 4, windowComplete: true, outcome: 'total_reached', nextPage: null, resume: null });
    // Same window and page size as the original run, continuing at page 4.
    expect(historyCalls.map(q => [q.get('pageNo'), q.get('pageSize'), q.get('startTime'), q.get('endTime'), q.get('sortOrder')])).toEqual([['4', '2', SINCE, UNTIL, 'ASC'], ['5', '2', SINCE, UNTIL, 'ASC']]);
    expect((await body(await get('/v1/tesla/charging-history'))).json).toMatchObject({ sessions: 10, lastSync: { windowComplete: true, outcome: 'total_reached' } });
    // Single use, and unknown or malformed tokens are refused before any call.
    historyCalls = [];
    for (const bad of [token, 'x'.repeat(43), 'short', `${token}=`]) await expect(resume(authDb, tesla, { token: bad, maxPages: 5, apply: true }, 0)).rejects.toThrow(RangeError);
    expect(historyCalls).toHaveLength(0);
  });

  test('resumed runs keep their pagination evidence and their link', async () => {
    const start = async (o: Record<string, unknown> = {}) => ((await synced({ maxPages: 1, ...o })) as any).resume as string;
    // A page repeated across runs is caught from the stored session IDs.
    pages = q => reply(q, [session(1, VIN_A), session(2, VIN_A)]);
    let token = await start();
    expect(await resume(authDb, tesla, { token, maxPages: 3, apply: true }, 0)).toMatchObject({ calls: 1, inserted: 0, outcome: 'repeated_page', nextPage: null, resume: null });
    // So is a total that changes between runs.
    await owner`TRUNCATE volta.tesla_charging_sessions, volta.tesla_history_syncs`;
    pages = q => reply(q, [session(Number(q.get('pageNo')) * 10, VIN_A), session(Number(q.get('pageNo')) * 10 + 1, VIN_A)], { totalResults: q.get('pageNo') === '1' ? 10 : 11, totalResultsLocation: 'top' });
    token = await start();
    expect(await resume(authDb, tesla, { token, maxPages: 3, apply: true }, 0)).toMatchObject({ calls: 1, inserted: 0, outcome: 'total_changed' });
    // A relink before resuming spends nothing and retires the token.
    pages = q => reply(q, [session(Number(q.get('pageNo')) * 10, VIN_A), session(Number(q.get('pageNo')) * 10 + 1, VIN_A)]);
    token = await start();
    link.account = ACCOUNT_2; historyCalls = [];
    expect(await resume(authDb, tesla, { token, maxPages: 3, apply: true }, 0)).toMatchObject({ calls: 0, outcome: 'account_changed', nextPage: null, resume: null });
    expect(historyCalls).toHaveLength(0);
    link.account = ACCOUNT_1;
    await expect(resume(authDb, tesla, { token, maxPages: 3, apply: true }, 0)).rejects.toThrow(RangeError);
    // A refusal keeps the page and issues a fresh token; the used one is retired.
    token = await start();
    pages = q => ({ status: 429, body: { error: { code: 'tesla_rate_limited', message: 'x' } } });
    const limited = await resume(authDb, tesla, { token, maxPages: 3, apply: true }, 0) as any;
    expect(limited).toMatchObject({ calls: 1, pages: 0, outcome: 'tesla_rate_limited', nextPage: 2 });
    expect(limited.resume).not.toBe(token);
    await expect(resume(authDb, tesla, { token, maxPages: 3, apply: true }, 0)).rejects.toThrow(RangeError);
    // An unexpected failure releases the run's claim: the token it printed
    // before calling continues the chain at once, from the same page.
    const crashing = Object.assign(Object.create(tesla), { chargingHistory: async () => { throw new TypeError('synthetic crash'); } }) as TeslaLink;
    const D = announced();
    await expect(resume(authDb, crashing, { token: limited.resume, maxPages: 3, apply: true }, 0, D.announce)).rejects.toThrow(TypeError);
    await expect(resume(authDb, tesla, { token: limited.resume, maxPages: 3, apply: true }, 0)).rejects.toThrow(RangeError);
    pages = q => reply(q, []); historyCalls = [];
    expect(await resume(authDb, tesla, { token: D.box.token, maxPages: 3, apply: true }, 0)).toMatchObject({ calls: 1, outcome: 'end_unverified' });
    expect(historyCalls.map(q => q.get('pageNo'))).toEqual(['2']);
  });

  test('a resume token is held by one run at a time', async () => {
    const two = (q: URLSearchParams) => reply(q, [session(Number(q.get('pageNo')) * 10, VIN_A), session(Number(q.get('pageNo')) * 10 + 1, VIN_A)]);
    pages = two;
    const token = ((await synced({ maxPages: 1 })) as any).resume as string;
    historyCalls = [];
    // The first run is held inside its Tesla call while others try the same token.
    let entered!: () => void, release!: () => void;
    const inCall = new Promise<void>(r => { entered = r; }), gate = new Promise<void>(r => { release = r; });
    pages = async q => { entered(); await gate; return two(q); };
    const held = resume(authDb, tesla, { token, maxPages: 1, apply: true }, 0);
    await inCall;
    pages = two;
    const others = await Promise.allSettled([1, 2, 3].map(() => resume(authDb, tesla, { token, maxPages: 1, apply: true }, 0)));
    expect(others.every(r => r.status === 'rejected' && r.reason instanceof RangeError)).toBe(true);
    release();
    expect(await held).toMatchObject({ calls: 1, received: 2, outcome: 'max_pages', nextPage: 3 });
    expect(historyCalls.map(q => q.get('pageNo'))).toEqual(['2']);
    // A claim left by a crashed process lapses after its lease.
    const next = ((await held) as any).resume as string;
    await owner`UPDATE volta.tesla_history_syncs SET claimed_at = now() WHERE resume_hash = sha256(${next}::bytea)`;
    await expect(resume(authDb, tesla, { token: next, maxPages: 1, apply: true }, 0)).rejects.toThrow(RangeError);
    await owner`UPDATE volta.tesla_history_syncs SET claimed_at = now() - interval '31 minutes' WHERE resume_hash = sha256(${next}::bytea)`;
    expect(await resume(authDb, tesla, { token: next, maxPages: 1, apply: true }, 0)).toMatchObject({ calls: 1, nextPage: 4 });
  });

  test('CLI sync defaults to a no-call plan and requires an explicit page base', async () => {
    const run = async (...args: string[]) => {
      const child = Bun.spawn([process.execPath, 'src/cli.ts', ...args], { cwd: new URL('..', import.meta.url).pathname, stdout: 'pipe', stderr: 'pipe',
        env: { ...process.env, COMMANDER_URL: `http://127.0.0.1:${commander.port}`, COMMANDER_INTERNAL_SECRET: SECRET } });
      return { status: await child.exited, out: await new Response(child.stdout).text(), err: await new Response(child.stderr).text() };
    };
    const plan = await run('history-sync', '--since', SINCE, '--until', UNTIL, '--first-page', '1');
    expect(plan.status).toBe(0); expect(JSON.parse(plan.out)).toMatchObject({ applied: false, calls: 0, plan: { maxCalls: 5, pageSize: 50 } });
    const missingBase = await run('history-sync', '--since', SINCE);
    expect(missingBase.status).toBe(1); expect(missingBase.err).toContain('--first-page');
    expect((await run('history-sync', '--since', SINCE, '--first-page', '1', '--max-pages', '21')).status).toBe(1);
    expect((await run('history-probe', '--since', SINCE, '--vin', VIN_A)).status).toBe(1);
    expect(historyCalls).toHaveLength(0);
    pages = q => reply(q, [session(1, VIN_A)]);
    const probed = await run('history-probe', '--since', SINCE, '--until', UNTIL, '--page', '1', '--page-size', '2');
    expect(probed.status).toBe(0); expect(JSON.parse(probed.out)).toMatchObject({ pageNo: 1, received: 1 }); expect(probed.out).not.toContain(VIN_A);
    expect(historyCalls).toHaveLength(1);
    // Resume takes only its token; the stored run fixes the window and page base.
    const token = ((await synced({ maxPages: 1 })) as any).resume as string;
    historyCalls = [];
    expect((await run('history-sync', '--resume', token, '--since', SINCE)).status).toBe(1);
    expect((await run('history-sync', '--resume', token, '--first-page', '0')).status).toBe(1);
    const bad = await run('history-sync', '--resume', 'not-a-token', '--apply');
    expect(bad.status).toBe(1); expect(bad.err).toContain('resume token');
    const resumed = await run('history-sync', '--resume', token);
    expect(resumed.status).toBe(0); expect(JSON.parse(resumed.out)).toMatchObject({ applied: false, calls: 0, plan: { nextPage: 2, pageSize: 2, firstPage: 1 } });
    expect(historyCalls).toHaveLength(0);
  }, 20000);
});
