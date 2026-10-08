import { afterAll, beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Auth } from '../src/auth';
import { createApp } from '../src/app';
import { connect } from '../src/db';
import { Telemetry } from '../src/telemetry';

const url = process.env.TEST_DATABASE_URL;
if (!url || new URL(url).pathname !== '/volta_test' || !['127.0.0.1','localhost'].includes(new URL(url).hostname)) throw new Error('Tests require an isolated localhost database named volta_test. Run bun run test:local.');
const owner = connect(url, false, 120000), reader = connect(process.env.TESLAMATE_DATABASE_URL!, true), authDb = connect(process.env.AUTH_DATABASE_URL!);
const auth = new Auth(authDb), telemetry = new Telemetry(reader, 'USD');
let logs: object[] = [], token = '';
const app = createApp(auth, telemetry, entry => logs.push(entry));
const request = (path: string, options: RequestInit = {}, authenticated = true) => app.request(path, { ...options, headers: { ...(authenticated ? { Authorization: `Bearer ${token}` } : {}), ...options.headers } });
const json = async (path: string) => { const response = await request(path); const body = await response.json(); if (response.status !== 200) throw new Error(`${path}: ${response.status} ${JSON.stringify(body)}`); return body as any; };
const pair = (code: string, name = 'Synthetic phone') => request('/v1/auth/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code, deviceName: name }) }, false);
beforeAll(async () => { await owner`SELECT 1`; });
beforeEach(async () => {
  await owner`TRUNCATE public.charges, public.charging_processes, public.positions, public.drives, public.states, public.updates, public.cars, public.car_settings, public.addresses, public.geofences, volta.devices, volta.pairing_codes, volta.rate_limits RESTART IDENTITY CASCADE`;
  await owner.file(new URL('./fixtures.sql', import.meta.url));
  const response = await pair(await auth.createPairingCode());
  expect(response.status).toBe(200); token = (await response.json() as any).token; logs = [];
});
afterAll(async () => { await Promise.all([owner.end(), reader.end(), authDb.end()]); });

describe('pairing and authorization', () => {
  test('health is public and reports database timestamps', async () => {
    const r = await request('/v1/health', {}, false); expect(r.status).toBe(200);
    expect((await r.json() as any).teslamate.reachable).toBe(true);
  });
  test('all contracted private endpoints require a token', async () => {
    for (const path of ['/v1/me','/v1/vehicles','/v1/vehicles/1/status','/v1/vehicles/1/summary','/v1/vehicles/1/timeline','/v1/vehicles/1/drives','/v1/drives/1','/v1/vehicles/1/charges','/v1/charges/1','/v1/vehicles/1/idles','/v1/vehicles/1/battery','/v1/vehicles/1/mileage','/v1/vehicles/1/firmware','/v1/vehicles/1/places']) {
      const r = await request(path, {}, false); expect(r.status).toBe(401); expect((await r.json() as any).error.code).toBe('unauthorized');
    }
    expect((await request('/v1/vehicles/1/commands/wake', { method: 'POST' }, false)).status).toBe(401);
  });
  test('tokens are hashed, me updates lastSeenAt, revocation is immediate', async () => {
    const me = await json('/v1/me'); expect(me.name).toBe('Synthetic phone'); expect(me.lastSeenAt).toMatch(/Z$/);
    const [stored] = await owner`SELECT token_hash FROM volta.devices WHERE id = ${me.id}`;
    expect(Buffer.from(stored!.token_hash).equals(createHash('sha256').update(token).digest())).toBe(true);
    expect((await request('/v1/me', { method: 'DELETE' })).status).toBe(204);
    expect((await request('/v1/vehicles')).status).toBe(401); expect(await auth.devices()).toEqual([]);
  });
  test('single-use code is atomic under concurrent pairing', async () => {
    const code = await auth.createPairingCode(); expect(code).toMatch(/^[A-HJ-NP-Z2-9]{8}$/);
    const responses = await Promise.all([pair(code), pair(code)]);
    expect(responses.map(r => r.status).sort()).toEqual([200,401]);
  });
  test('expired codes and invalid codes cannot issue tokens', async () => {
    const code = await auth.createPairingCode(); await owner`UPDATE volta.pairing_codes SET expires_at = now() - interval '1 second'`;
    expect((await pair(code)).status).toBe(401); expect((await pair('AAAAAAAA')).status).toBe(401);
  });
  test('rate limit persists across Auth instances; spoofed client headers do not bypass it', async () => {
    await owner`DELETE FROM volta.rate_limits`;
    for (let n=0; n<30; n++) expect((await pair('AAAAAAAA')).status).toBe(401);
    const r = await request('/v1/auth/pair', { method: 'POST', headers: { 'X-Forwarded-For':'1.2.3.4' }, body: '{"code":"AAAAAAAA","deviceName":"Phone"}' }, false);
    expect(r.status).toBe(429); expect((await r.json() as any).error.code).toBe('rate_limited');
    await expect(new Auth(authDb).pair({ code: await auth.createPairingCode(), deviceName: 'Phone' })).rejects.toMatchObject({ status:429 });
    await owner`UPDATE volta.rate_limits SET window_start = now() - interval '11 minutes'`;
    expect((await pair(await auth.createPairingCode())).status).toBe(200);
  });
  test('malformed JSON, oversized body and invalid names receive envelope errors', async () => {
    expect((await request('/v1/auth/pair', { method:'POST', body:'{' }, false)).status).toBe(400);
    expect((await pair(await auth.createPairingCode(), ' ')).status).toBe(400);
    const r = await request('/v1/auth/pair', { method:'POST', body: 'a'.repeat(4097) }, false);
    expect(r.status).toBe(413); expect((await r.json() as any).error.code).toBe('payload_too_large');
  });
  test('logs omit authorization, body, pairing code, queries and unmatched paths', async () => {
    const code = await auth.createPairingCode(); await pair(code);
    await request(`/v1/vehicles/1/drives?cursor=${token}`); await request(`/v1/not-a-route-${token}`);
    const rendered = JSON.stringify(logs); expect(rendered).not.toContain(token); expect(rendered).not.toContain(code);
  });
  test('running Bun entrypoint serves pairing and revocation over HTTP with sanitized logs', async () => {
    const probe = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch: () => new Response('probe') });
    const port = probe.port!; probe.stop(true);
    const child = Bun.spawn([process.execPath, 'src/index.ts'], { cwd: new URL('..', import.meta.url).pathname, env: { ...process.env, HOST: '127.0.0.1', PORT: String(port) }, stdout: 'pipe', stderr: 'pipe' });
    const base = `http://127.0.0.1:${port}`;
    let issued = '';
    try {
      let ready = false;
      for (let n=0;n<100;n++) {
        try { const r = await fetch(base+'/v1/health'); ready = r.ok; if (ready) break; } catch { }
        await Bun.sleep(20);
      }
      expect(ready).toBe(true);
      const response = await fetch(base+'/v1/auth/pair', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ code:await auth.createPairingCode(), deviceName:'HTTP fixture' }) });
      expect(response.status).toBe(200); issued = (await response.json() as any).token;
      const headers = { Authorization:`Bearer ${issued}` };
      const drives = await fetch(base+'/v1/vehicles/1/drives?limit=1', {headers}); expect(drives.status).toBe(200); expect((await drives.json() as any).items).toHaveLength(1);
      expect((await fetch(base+'/v1/me', {method:'DELETE',headers})).status).toBe(204);
      expect((await fetch(base+'/v1/vehicles', {headers})).status).toBe(401);
    } finally {
      child.kill('SIGTERM'); await child.exited;
      const out = await new Response(child.stdout).text(); expect(out).not.toContain(issued || 'never-issued-secret');
      expect(out).toContain('"event":"started"');
    }
  }, 10000);
  test('CLI pair/devices/revoke runs against the auth role', async () => {
    const run = async (...args: string[]) => {
      const child = Bun.spawn([process.execPath, 'src/cli.ts', ...args], { cwd: new URL('..', import.meta.url).pathname, stdout:'pipe', stderr:'pipe' });
      return { status: await child.exited, out: await new Response(child.stdout).text() };
    };
    const generated = await run('pair'); expect(generated.status).toBe(0); expect(generated.out).toMatch(/[A-HJ-NP-Z2-9]{8}/);
    const devices = await run('devices'); expect(devices.status).toBe(0); expect(JSON.parse(devices.out)).toHaveLength(1);
    const me = await json('/v1/me'); expect((await run('revoke', String(me.id))).status).toBe(0);
    expect((await request('/v1/me')).status).toBe(401); expect((await run('revoke', '999')).status).toBe(1);
  });
});

describe('metric telemetry contract', () => {
  test('charge coordinates use positions, then address coordinates, then null on list and detail', async () => {
    const check = async (latitude: number | null, longitude: number | null) => {
      const detail = await json('/v1/charges/1');
      const item = (await json('/v1/vehicles/1/charges')).items.find((r:any) => r.id === 1);
      for (const charge of [detail, item]) {
        expect(charge.latitude).toBe(latitude); expect(charge.longitude).toBe(longitude);
      }
    };
    await owner`UPDATE positions SET latitude=40.123456, longitude=-74.654321 WHERE id=6`;
    await check(40.123456, -74.654321);
    // v4.3.0 mandates position_id. Exercise the defensive fallback under a
    // nullable historical schema, restoring the upstream constraint afterward.
    await owner`ALTER TABLE charging_processes ALTER COLUMN position_id DROP NOT NULL`;
    try {
      await owner`UPDATE charging_processes SET position_id=NULL WHERE id=1`;
      await check(40, -74);
      await owner`UPDATE addresses SET latitude=NULL, longitude=NULL WHERE id=1`;
      await check(null, null); // Existing address/geofence names do not invent a point.
      await owner`UPDATE charging_processes SET address_id=NULL WHERE id=1`;
      await check(null, null);
    } finally {
      await owner`UPDATE charging_processes SET position_id=6 WHERE id=1`;
      await owner`ALTER TABLE charging_processes ALTER COLUMN position_id SET NOT NULL`;
    }
    await owner`UPDATE positions SET latitude=0, longitude=0 WHERE id=6`;
    await owner`UPDATE charging_processes SET position_id=6 WHERE id=1`;
    await check(0, 0); // Recorded zero is a valid coordinate.
  });
  test('idle coordinates use the ending drive or charge position, then bounded nearest observations', async () => {
    const idle = async (id = 2) => (await json('/v1/vehicles/1/idles')).items.find((r:any) => r.id === id);
    expect((await idle()).latitude).toBe(40.01); expect((await idle()).longitude).toBe(-74.01);
    expect((await idle(3)).latitude).toBe(40); // Gap after charge: its linked parking position.
    await owner`UPDATE drives SET end_position_id=NULL WHERE id=1`;
    await owner`INSERT INTO positions(id,car_id,date,latitude,longitude)
      SELECT 20,1,end_date+interval '1 minute',42,-72 FROM drives WHERE id=1`;
    expect((await idle()).latitude).toBe(40.01); // Exact unlinked drive point is nearest.
    await owner`UPDATE positions SET date=date-interval '20 minutes' WHERE id=3`;
    expect((await idle()).latitude).toBe(42); expect((await idle()).longitude).toBe(-72);
    await owner`INSERT INTO positions(id,car_id,date,latitude,longitude)
      SELECT 21,1,end_date-interval '1 minute',43,-73 FROM drives WHERE id=1`;
    expect((await idle()).latitude).toBe(43); // Equal distances choose earlier timestamp.
    await owner`INSERT INTO positions(id,car_id,date,latitude,longitude)
      SELECT 22,2,end_date,44,-74 FROM drives WHERE id=1`;
    expect((await idle()).latitude).toBe(43); // Another vehicle is never a fallback.
    await owner`DELETE FROM positions WHERE id IN (20,21)`;
    expect((await idle()).latitude).toBeNull(); expect((await idle()).longitude).toBeNull();
    const page = await json('/v1/vehicles/1/idles?limit=1');
    expect(page.items[0]._locationPositionId).toBeUndefined();
    const next = await json(`/v1/vehicles/1/idles?limit=1&cursor=${page.nextCursor}`);
    expect(next.items[0]).toHaveProperty('latitude'); expect(next.items[0]._locationPositionId).toBeUndefined();
  });
  test('batched idle fallback keeps each gap within its own observation window', async () => {
    await owner`UPDATE drives SET end_position_id=NULL WHERE id IN (1,2)`;
    await owner`UPDATE positions SET date=date+interval '30 minutes' WHERE id=5`;
    const gaps = async () => (await json('/v1/vehicles/1/idles')).items;
    const first = await gaps();
    expect(first.find((r:any)=>r.id===2)).toMatchObject({latitude:40.01,longitude:-74.01});
    expect(first.find((r:any)=>r.id===4)).toMatchObject({latitude:null,longitude:null});
    // Both gaps share the candidate range, but observations are local to each gap.
    await owner`INSERT INTO positions(id,car_id,date,latitude,longitude)
      SELECT 20,1,end_date-interval '1 minute',43,-73 FROM drives WHERE id=2`;
    const second = await gaps();
    expect(second.find((r:any)=>r.id===2)).toMatchObject({latitude:40.01,longitude:-74.01});
    expect(second.find((r:any)=>r.id===4)).toMatchObject({latitude:43,longitude:-73});
  });
  const summaryAt = async (instant: string, query = '', id = 2) => {
    const fixed = createApp(auth, new Telemetry(reader, 'USD', () => new Date(instant)), () => {});
    const r = await fixed.request(`/v1/vehicles/${id}/summary${query}`, { headers: { Authorization: `Bearer ${token}` } });
    expect(r.status).toBe(200); return await r.json() as any;
  };
  test('summary today attributes New York evening to the local day and reports exact bounds', async () => {
    await owner.file(new URL('./summary-zone.sql', import.meta.url));
    const instant = '2026-07-02T03:59:59.000Z';
    const local = await summaryAt(instant, '?tz=America/New_York');
    expect(local.periodStart).toBe('2026-07-01T04:00:00.000Z'); expect(local.periodEnd).toBe(instant);
    expect(local.timeZone).toBe('America/New_York'); expect(local.driveCount).toBe(3);
    expect(local.distanceKm).toBe(60); expect(local.chargeCount).toBe(3); expect(local.energyAddedKwh).toBe(60); expect(local.chargeCost).toBe(6);
    const utc = await summaryAt(instant);
    expect(utc.periodStart).toBe('2026-07-02T00:00:00.000Z'); expect(utc.timeZone).toBe('UTC');
    expect(utc.distanceKm).toBe(50); expect(utc.chargeCount).toBe(2);
    expect(await summaryAt(instant, '?tz=UTC')).toEqual(utc);
    const midnight = await summaryAt('2026-07-02T04:00:00.000Z', '?tz=America/New_York');
    expect(midnight.periodStart).toBe(midnight.periodEnd); expect(midnight.driveCount).toBe(0); expect(midnight.chargeCount).toBe(0);
  });
  test('summary zone boundaries observe spring and fall DST for today and rolling ranges', async () => {
    await owner`INSERT INTO positions(id,car_id,date,latitude,longitude) VALUES(100,2,'2026-01-01',40,-74)`;
    for (const [instant, today, week, month] of [
      ['2026-03-09T03:59:59.000Z','2026-03-08T05:00:00.000Z','2026-03-02T04:59:59.000Z','2026-02-07T04:59:59.000Z'],
      ['2026-11-02T04:59:59.000Z','2026-11-01T04:00:00.000Z','2026-10-26T03:59:59.000Z','2026-10-03T03:59:59.000Z'],
    ] as const) {
      for (const [range, start] of [['today',today],['7d',week],['30d',month]] as const) {
        await owner`DELETE FROM drives WHERE car_id=2`; await owner`DELETE FROM charging_processes WHERE car_id=2`;
        const before = new Date(Date.parse(start)-1).toISOString();
        await owner`INSERT INTO drives(id,car_id,start_date,end_date,distance,duration_min) VALUES
          (100,2,${before},${start},1,1),(101,2,${start},${instant},10,1),(102,2,${instant},${instant},100,1)`;
        await owner`INSERT INTO charging_processes(id,car_id,position_id,start_date,end_date,duration_min,charge_energy_added) VALUES
          (100,2,100,${before},${start},1,1),(101,2,100,${start},${instant},1,10),(102,2,100,${instant},${instant},1,100)`;
        const result = await summaryAt(instant, `?range=${range}&tz=America/New_York`);
        expect(result.periodStart).toBe(start); expect(result.periodEnd).toBe(instant);
        expect(result.driveCount).toBe(1); expect(result.distanceKm).toBe(10); expect(result.chargeCount).toBe(1); expect(result.energyAddedKwh).toBe(10);
        const utc = await summaryAt(instant, `?range=${range}`);
        const expected = range === 'today' ? instant.slice(0,10)+'T00:00:00.000Z' : new Date(Date.parse(instant)-(range==='7d'?7:30)*86400000).toISOString();
        expect(utc.periodStart).toBe(expected); expect(utc.timeZone).toBe('UTC');
      }
    }
  });
  test('invalid summary zones return the standard 400 envelope', async () => {
    for (const tz of ['', 'Not/AZone', '+01:00', 'America/New_York\u0000', 'x'.repeat(101)]) {
      const r = await request(`/v1/vehicles/1/summary?tz=${encodeURIComponent(tz)}`);
      expect(r.status).toBe(400); expect(await r.json()).toEqual({ error: { code: 'invalid_input', message: 'tz must be an IANA time zone' } });
    }
  });
  test('summary IANA short names retain summer daylight saving offsets', async () => {
    for (const [tz, start] of [['CET','2026-07-01T22:00:00.000Z'],['MET','2026-07-01T22:00:00.000Z'],['EET','2026-07-01T21:00:00.000Z'],['WET','2026-07-01T23:00:00.000Z']]) {
      const result = await summaryAt('2026-07-02T12:00:00.000Z', `?tz=${tz}`);
      expect(result.periodStart).toBe(start); expect(result.timeZone).toBe(tz);
    }
  });
  test('summary supports new IANA zones independently of the Postgres zone catalog', async () => {
    const result = await summaryAt('2026-07-02T12:00:00.000Z', '?tz=America/Coyhaique');
    expect(result.periodStart).toBe('2026-07-02T03:00:00.000Z'); expect(result.timeZone).toBe('America/Coyhaique');
  });
  test('summary today includes both occurrences of a repeated midnight', async () => {
    // Havana falls back at 01:00 to 00:00: the day begins at the first midnight.
    await owner`INSERT INTO drives(id,car_id,start_date,end_date,distance,duration_min) VALUES
      (100,2,'2026-11-01 04:30:00','2026-11-01 04:31:00',10,1),
      (101,2,'2026-11-01 05:30:00','2026-11-01 05:31:00',20,1)`;
    const result = await summaryAt('2026-11-01T12:00:00.000Z', '?tz=America/Havana');
    expect(result.periodStart).toBe('2026-11-01T04:00:00.000Z'); expect(result.driveCount).toBe(2); expect(result.distanceKm).toBe(30);
  });
  test('vehicles expose only VIN suffix and installed firmware', async () => {
    const cars = await json('/v1/vehicles'); expect(cars).toHaveLength(3);
    expect(cars[0]).toEqual({ id:1, name:'Synthetic Model 3', model:'3', trim:'LR', exteriorColor:'White', vinSuffix:'000001', firmware:'2026.2', hasData:true });
  });
  test('hasData marks vehicles without any SOC observation, matching status 409', async () => {
    const byId = async () => Object.fromEntries((await json('/v1/vehicles')).map((c:any) => [c.id, c.hasData]));
    expect(await byId()).toEqual({ 1:true, 2:false, 3:true });
    expect((await request('/v1/vehicles/2/status')).status).toBe(409);
    // Neither a position without SOC nor a stale streamed (unpolled) sample is a status observation.
    await owner`INSERT INTO positions (id, car_id, date, latitude, longitude, battery_level) VALUES
      (900, 2, now() AT TIME ZONE 'UTC', 40, -74, NULL), (901, 2, now() AT TIME ZONE 'UTC' - interval '2 days', 40, -74, 60)`;
    expect((await byId())[2]).toBe(false); expect((await request('/v1/vehicles/2/status')).status).toBe(409);
    // An open charging session's sample alone counts and makes status available.
    await owner`INSERT INTO charging_processes (id, car_id, position_id, start_date) VALUES (900, 2, 900, now() AT TIME ZONE 'UTC')`;
    await owner`INSERT INTO charges (id, charging_process_id, date, battery_level, charge_energy_added, charger_power, ideal_battery_range_km) VALUES (900, 900, now() AT TIME ZONE 'UTC', 55, 1, 11, 200)`;
    expect((await byId())[2]).toBe(true); expect((await json('/v1/vehicles/2/status')).batteryLevel).toBe(55);
  });
  test('hasData agrees with status when the reading status picks has no SOC', async () => {
    const agree = async () => {
      const cars = await json('/v1/vehicles');
      for (const car of cars) expect([car.id, car.hasData]).toEqual([car.id, (await request(`/v1/vehicles/${car.id}/status`)).status === 200]);
      return Object.fromEntries(cars.map((c:any) => [c.id, c.hasData]));
    };
    expect(await agree()).toEqual({ 1:true, 2:false, 3:true });
    // An old poll with SOC, then a position without SOC within 15 minutes: status reads the later one.
    await owner`INSERT INTO positions (id, car_id, date, latitude, longitude, battery_level, ideal_battery_range_km, rated_battery_range_km) VALUES
      (910, 2, now() AT TIME ZONE 'UTC' - interval '3 days', 40, -74, 60, 300, 300),
      (911, 2, now() AT TIME ZONE 'UTC' - interval '3 days' + interval '5 minutes', 40, -74, NULL, NULL, NULL)`;
    expect((await agree())[2]).toBe(false);
    // An open charge whose newest sample has no SOC, although an earlier one did.
    await owner`INSERT INTO charging_processes (id, car_id, position_id, start_date) VALUES (910, 2, 911, now() AT TIME ZONE 'UTC' - interval '1 hour')`;
    await owner`INSERT INTO charges (id, charging_process_id, date, battery_level, charge_energy_added, charger_power, ideal_battery_range_km) VALUES
      (910, 910, now() AT TIME ZONE 'UTC' - interval '50 minutes', 55, 1, 11, 200), (911, 910, now() AT TIME ZONE 'UTC' - interval '40 minutes', NULL, 2, 11, 210)`;
    expect((await agree())[2]).toBe(false);
    await owner`INSERT INTO charges (id, charging_process_id, date, battery_level, charge_energy_added, charger_power, ideal_battery_range_km) VALUES
      (912, 910, now() AT TIME ZONE 'UTC' - interval '30 minutes', 57, 3, 11, 220)`;
    expect((await agree())[2]).toBe(true);
  });
  test('status maps observations and unknown live attributes without fabricating zeros', async () => {
    const status = await json('/v1/vehicles/1/status'); expect(status.state).toBe('asleep'); expect(status.batteryLevel).toBe(84);
    expect(status.ratedRangeKm).toBe(420); expect(status.insideTempC).toBe(21); expect(status.location.latitude).toBe(40.01);
    for (const key of ['locked','sentryMode','chargeLimit','minutesToFull','chargingState']) expect(status[key]).toBeNull();
    const r = await request('/v1/vehicles/2/status'); expect(r.status).toBe(409); expect((await r.json() as any).error.code).toBe('data_unavailable');
  });
  test('active drive, charge sample and update take precedence over logged state', async () => {
    await owner`UPDATE drives SET end_date = NULL WHERE id = 3`;
    expect((await json('/v1/vehicles/1/status')).state).toBe('driving');
    await owner`UPDATE drives SET end_date = (now() AT TIME ZONE 'UTC')::date - interval '1 day' + interval '9 hours' WHERE id = 3`;
    await owner`UPDATE charging_processes SET end_date = NULL WHERE id = 1`;
    await owner`UPDATE charges SET date = now() AT TIME ZONE 'UTC' WHERE id = 2`;
    const status = await json('/v1/vehicles/1/status'); expect(status.state).toBe('charging'); expect(status.batteryLevel).toBe(93);
    await owner`INSERT INTO updates (id, car_id, start_date) VALUES (3,1, now() AT TIME ZONE 'UTC')`;
    expect((await json('/v1/vehicles/1/status')).state).toBe('updating');
  });
  test('drive detail is flat, with ordered samples and rated-energy estimate', async () => {
    const d = await json('/v1/drives/1'); expect(d.distanceKm).toBe(40); expect(d.durationMin).toBe(60);
    expect(d.energyUsedKwh).toBeCloseTo(6); expect(d.efficiencyWhPerKm).toBeCloseTo(150);
    expect(d.startBatteryLevel).toBe(80); expect(d.endBatteryLevel).toBe(72); expect(d.maxSpeedKph).toBe(100); expect(d.elevationGainM).toBe(120);
    expect(d.path.map((p: any) => p.elevationM)).toEqual([10,80,20]); expect(d.summary).toBeUndefined();
  });
  test('charge detail is flat with energy, costs, samples, and efficiency ratio', async () => {
    const ch = await json('/v1/charges/1'); expect(ch.energyAddedKwh).toBe(21); expect(ch.energyUsedKwh).toBe(24); expect(ch.cost).toBe(4.8);
    expect(ch.currency).toBe('USD'); expect(ch.maxPowerKw).toBe(11); expect(ch.fastCharger).toBe(false); expect(ch.efficiency).toBeCloseTo(0.875);
    expect(ch.samples).toHaveLength(2); expect(ch.samples[0].powerKw).toBe(11); expect(ch.samples[0].ratedRangeKm).toBe(325);
  });
  test('cursor pagination is deterministic for equal timestamps and scoped to filters', async () => {
    const seen: number[] = []; let cursor: string | null = null;
    do { const result = await json('/v1/vehicles/1/drives?limit=1' + (cursor ? `&cursor=${cursor}` : '')); seen.push(result.items[0].id); cursor = result.nextCursor; } while (cursor);
    expect(seen).toEqual([4,3,2,1]);
    const p = await json('/v1/vehicles/1/drives?limit=1');
    expect((await request(`/v1/vehicles/1/charges?cursor=${p.nextCursor}`)).status).toBe(400);
    expect((await request(`/v1/vehicles/1/drives?from=2026-01-01T00:00:00Z&cursor=${p.nextCursor}`)).status).toBe(400);
    const ch = await json('/v1/vehicles/1/charges?limit=1'); expect(ch.nextCursor).toBeNull();
  });
  test('cursors retain microsecond ordering without duplicates or skipped records', async () => {
    await owner`UPDATE drives SET start_date = (now() AT TIME ZONE 'UTC')::date - interval '1 day' + interval '8 hours 0.000999 seconds' WHERE id = 3`;
    await owner`UPDATE drives SET start_date = (now() AT TIME ZONE 'UTC')::date - interval '1 day' + interval '8 hours 0.000111 seconds' WHERE id = 4`;
    const first = await json('/v1/vehicles/1/drives?limit=1'); expect(first.items[0].id).toBe(3);
    expect(first.items[0]._cursorStart).toBeUndefined();
    const second = await json(`/v1/vehicles/1/drives?limit=1&cursor=${first.nextCursor}`); expect(second.items[0].id).toBe(4);
    const third = await json(`/v1/vehicles/1/drives?limit=1&cursor=${second.nextCursor}`); expect(third.items[0].id).toBe(2);
    const d = await json('/v1/drives/1'); expect(d._cursorStart).toBeUndefined();
  });
  test('unsampled drives do not poison history or aggregates; detail reports unavailable', async () => {
    await owner`INSERT INTO drives (id,car_id,start_date) VALUES(20,1,now() AT TIME ZONE 'UTC')`;
    expect((await request('/v1/drives/20')).status).toBe(409);
    expect((await json('/v1/vehicles/1/drives')).items.map((r:any)=>r.id)).toEqual([4,3,2,1]);
    expect((await json('/v1/vehicles/1/summary?range=7d')).distanceKm).toBe(105);
    expect((await json('/v1/vehicles/1/mileage'))[0].distanceKm).toBeGreaterThan(0);
  });
  test('TeslaMate-shaped open drives derive first and last measurements before close_drive', async () => {
    await owner`INSERT INTO drives(id,car_id,start_date) VALUES(20,1,now() AT TIME ZONE 'UTC'-interval '10 minutes')`;
    await owner`INSERT INTO positions(id,car_id,drive_id,date,latitude,longitude,odometer,battery_level,rated_battery_range_km,ideal_battery_range_km) VALUES
      (20,1,20,now() AT TIME ZONE 'UTC'-interval '10 minutes',40,-74,10100,80,400,400),
      (21,1,20,now() AT TIME ZONE 'UTC',40.01,-74.01,10110,78,390,390)`;
    const d = await json('/v1/drives/20'); expect(d.end).toBeNull(); expect(d.distanceKm).toBe(10);
    expect(d.startBatteryLevel).toBe(80); expect(d.endBatteryLevel).toBe(78); expect(d.energyUsedKwh).toBeCloseTo(1.5);
    expect((await json('/v1/vehicles/1/status')).state).toBe('driving');
    expect((await json('/v1/vehicles/1/drives')).items[0].id).toBe(20);
    expect((await json('/v1/vehicles/1/summary?range=today')).distanceKm).toBe(10);
    expect((await json('/v1/vehicles/1/mileage?bucket=day'))[0].distanceKm).toBe(10);
  });
  test('mixed streamed/polled positions keep range energy and status fields stable', async () => {
    await owner`INSERT INTO drives(id,car_id,start_date) VALUES(20,1,now() AT TIME ZONE 'UTC'-interval '10 minutes')`;
    await owner`INSERT INTO positions(id,car_id,drive_id,date,latitude,longitude,odometer,battery_level) VALUES
      (20,1,20,now() AT TIME ZONE 'UTC'-interval '10 minutes 2 seconds',40,-74,10100,80),
      (23,1,20,now() AT TIME ZONE 'UTC',40.02,-74.02,10110,77)`;
    await owner`INSERT INTO positions(id,car_id,drive_id,date,latitude,longitude,odometer,battery_level,usable_battery_level,ideal_battery_range_km,rated_battery_range_km,est_battery_range_km,inside_temp,outside_temp,is_climate_on,driver_temp_setting) VALUES
      (21,1,20,now() AT TIME ZONE 'UTC'-interval '9 minutes',40,-74,10101,80,80,400,400,380,21,10,false,21),
      (22,1,20,now() AT TIME ZONE 'UTC'-interval '1 minute',40.01,-74.01,10109,78,78,390,390,370,22,11,true,22)`;
    const drive = await json('/v1/drives/20'); expect(drive.energyUsedKwh).toBeCloseTo(1.5); expect(drive.efficiencyWhPerKm).toBeCloseTo(150);
    const status = await json('/v1/vehicles/1/status'); expect(status.batteryLevel).toBe(77); expect(status.odometerKm).toBe(10110);
    expect(status.ratedRangeKm).toBe(390); expect(status.usableBatteryLevel).toBe(78); expect(status.insideTempC).toBe(22); expect(status.climateOn).toBe(true);
    expect(status.location.latitude).toBe(40.02);
    expect((await json('/v1/vehicles/1/summary?range=today')).energyUsedKwh).toBeCloseTo(1.5);
    expect((await json('/v1/vehicles/1/mileage?bucket=day'))[0].energyUsedKwh).toBeCloseTo(1.5);
    expect((await json('/v1/vehicles/1/mileage?bucket=month'))[0].energyUsedKwh).toBeCloseTo(17.25);
    const idle = (await json('/v1/vehicles/1/idles')).items.find((r:any)=>r.id===6); expect(idle.endBatteryLevel).toBe(80);
    await owner`INSERT INTO positions(id,car_id,drive_id,date,latitude,longitude,odometer,battery_level) VALUES(24,1,20,now() AT TIME ZONE 'UTC',40.03,-74.03,10111,76)`;
    expect((await json('/v1/drives/20')).energyUsedKwh).toBeCloseTo(1.5);
    expect((await json('/v1/vehicles/1/status')).ratedRangeKm).toBe(390);
    const [last] = await owner`SELECT date FROM positions WHERE id=24`;
    expect(Date.parse((await json('/v1/health')).teslamate.lastDataAt)).toBeGreaterThanOrEqual(+last!.date);
  });
  test('battery degradation uses capacity estimates and rejects zero usable SOC', async () => {
    await owner`UPDATE charges SET rated_battery_range_km = 418.5 WHERE id = 2`;
    const b = await json('/v1/vehicles/1/battery'); expect(b.capacityNewKwh).toBeCloseTo(67.5); expect(b.capacityNowKwh).toBeCloseTo(71.25);
    // Earliest known maximum final sample is the baseline; zero SOC must not divide by zero.
    await owner`UPDATE charges SET usable_battery_level = 0 WHERE charging_process_id = 1`;
    const empty = await json('/v1/vehicles/1/battery'); expect(empty.capacityNewKwh).toBeNull(); expect(empty.capacityNowKwh).toBeNull();
  });
  test('from is inclusive and to exclusive', async () => {
    const d = await json('/v1/drives/1'); const p = await json(`/v1/vehicles/1/drives?from=${d.start}&to=${d.end}`); expect(p.items.map((r:any) => r.id)).toEqual([1]);
  });
  test('idles merge overlapping drives, derive observed loss and state overlap', async () => {
    const p = await json('/v1/vehicles/1/idles'); expect(p.items).toHaveLength(3);
    const idle = p.items.find((r:any) => r.id === 2); expect(idle.durationMin).toBe(120); expect(idle.startBatteryLevel).toBe(72); expect(idle.endBatteryLevel).toBe(70);
    expect(idle.rangeLostKm).toBe(10); expect(idle.energyLostKwh).toBeCloseTo(1.5); expect(idle.asleepMinutes).toBe(60); expect(p.items.find((r:any) => r.id===4).asleepMinutes).toBe(0); expect(idle.climateMinutes).toBe(5); expect(idle.sentryMinutes).toBeNull(); expect(p.items.find((r:any)=>r.id===4).climateMinutes).toBe(0);
    const exact = await json('/v1/vehicles/1/idles?minMinutes=120'); expect(exact.items.some((r:any) => r.id===2)).toBe(false);
    const first = await json('/v1/vehicles/1/idles?limit=1'); const next = await json(`/v1/vehicles/1/idles?limit=1&cursor=${first.nextCursor}`); expect(next.items[0].id).not.toBe(first.items[0].id);
  });
  test('partial logger-state coverage cannot fabricate a complete asleep total', async () => {
    await owner`DELETE FROM states WHERE id IN (3,4)`;
    const idle = (await json('/v1/vehicles/1/idles')).items.find((r:any) => r.id===2);
    expect(idle.asleepMinutes).toBeNull();
  });
  test('idle range uses stored or bounded polled range when the next drive starts streamed', async () => {
    await owner`UPDATE positions SET rated_battery_range_km=NULL, ideal_battery_range_km=NULL WHERE id=4`;
    const idle = async () => (await json('/v1/vehicles/1/idles')).items.find((r:any)=>r.id===2);
    expect((await idle()).rangeLostKm).toBe(10); // Closed drive's stored start range.
    await owner`UPDATE drives SET start_rated_range_km=NULL WHERE id=2`;
    await owner`INSERT INTO positions(id,car_id,drive_id,date,latitude,longitude,odometer,ideal_battery_range_km,rated_battery_range_km)
      SELECT 20,1,2,start_date+interval '1 minute',40,-74,10041,349,349 FROM drives WHERE id=2`;
    expect((await idle()).rangeLostKm).toBe(11);
    expect((await idle()).energyLostKwh).toBeCloseTo(1.65);
    await owner`UPDATE drives SET start_position_id=NULL,end_position_id=NULL,end_date=NULL WHERE id=2`;
    expect((await idle()).endBatteryLevel).toBe(70); // Open drive retains first streamed battery.
    expect((await idle()).rangeLostKm).toBe(11);
    await owner`UPDATE positions SET date=date+interval '20 minutes' WHERE id=20`;
    expect((await idle()).rangeLostKm).toBeNull(); // A distant poll cannot fill the boundary.
    expect((await idle()).energyLostKwh).toBeNull();
  });
  test('idle missing boundary readings stay null', async () => {
    await owner`UPDATE drives SET start_rated_range_km=NULL WHERE id=2`;
    await owner`UPDATE positions SET rated_battery_range_km = NULL, battery_level = NULL WHERE id = 4`;
    const idle = (await json('/v1/vehicles/1/idles')).items.find((r:any) => r.id===2); expect(idle.rangeLostKm).toBeNull(); expect(idle.energyLostKwh).toBeNull(); expect(idle.endBatteryLevel).toBeNull();
  });
  test('battery health follows rated range and usable SOC with modal efficiency', async () => {
    const b = await json('/v1/vehicles/1/battery'); expect(b.capacityNewKwh).toBeCloseTo(75); expect(b.capacityNowKwh).toBeCloseTo(75);
    expect(b.healthPercent).toBeCloseTo(100); expect(b.ratedRangeAt100Km).toBeCloseTo(500); expect(b.history[0].ratedRangeAt100Km).toBeCloseTo(500); expect(b.avgIdleDrainPctPerDay).toBeGreaterThan(0);
    const derived = await json('/v1/vehicles/3/battery'); expect(derived.capacityNowKwh).toBeCloseTo(75); // 20 / 100 km = 0.2 kWh/km, 300 / 80% = 375km.
    const empty = await json('/v1/vehicles/2/battery'); expect(empty.history).toEqual([]); expect(empty.capacityNewKwh).toBeNull(); expect(empty.healthPercent).toBeNull();
  });
  test('summary, mileage buckets, firmware and geofence billing map correctly', async () => {
    const summary = await json('/v1/vehicles/1/summary?range=7d'); expect(summary.distanceKm).toBe(105); expect(summary.driveCount).toBe(4); expect(summary.chargeCount).toBe(1); expect(summary.energyUsedKwh).toBeCloseTo(15.75); expect(summary.energyAddedKwh).toBe(21);
    for (const bucket of ['day','week','month']) { const buckets = await json(`/v1/vehicles/1/mileage?bucket=${bucket}`); expect(buckets.reduce((sum:number,r:any) => sum+r.distanceKm,0)).toBe(105); }
    const firmware = await json('/v1/vehicles/1/firmware'); expect(firmware[0].previousVersion).toBe('2026.1'); expect(firmware[1].previousVersion).toBeNull();
    const places = await json('/v1/vehicles/1/places'); expect(places.find((r:any) => r.id===1).costPerKwh).toBe(0.2); expect(places.find((r:any) => r.id===2).costPerKwh).toBeNull();
  });
  test('unknown measurements cannot silently turn aggregate energy into a partial total', async () => {
    await owner`UPDATE drives SET end_rated_range_km = NULL WHERE id = 1`;
    await owner`UPDATE positions SET rated_battery_range_km = NULL WHERE id = 3`;
    await owner`UPDATE charging_processes SET charge_energy_added = NULL, cost = NULL WHERE id = 1`;
    const summary = await json('/v1/vehicles/1/summary?range=7d');
    expect(summary.distanceKm).toBe(105); expect(summary.energyUsedKwh).toBeNull(); expect(summary.efficiencyWhPerKm).toBeNull();
    expect(summary.energyAddedKwh).toBeNull(); expect(summary.chargeCost).toBeNull();
    expect((await json('/v1/vehicles/1/mileage?bucket=month'))[0].energyUsedKwh).toBeNull();
  });
  test('timeline clips boundaries and prioritizes activities without overlaps', async () => {
    const timeline = await json('/v1/vehicles/1/timeline?hours=72'); expect(timeline.some((r:any) => r.kind==='drive')).toBe(true); expect(timeline.some((r:any) => r.kind==='asleep')).toBe(true);
    for (let i=0;i<timeline.length-1;i++) expect(Date.parse(timeline[i].start)).toBeGreaterThanOrEqual(Date.parse(timeline[i+1].end));
    expect(timeline.every((r:any) => Date.parse(r.end)>Date.parse(r.start))).toBe(true);
  });
  test('empty histories are empty, unknown resources are 404 and commands are 501', async () => {
    for (const kind of ['drives','charges','idles']) expect((await json(`/v1/vehicles/2/${kind}`)).items).toEqual([]);
    for (const path of ['/v1/vehicles/999/status','/v1/vehicles/999/drives','/v1/drives/999','/v1/charges/999']) expect((await request(path)).status).toBe(404);
    const r = await request('/v1/vehicles/1/commands/wake', {method:'POST',body:'{}'}); expect(r.status).toBe(501); expect((await r.json() as any).error.code).toBe('commands_unavailable');
  });
  test('invalid IDs, dates, ranges, limits and cursors receive 400', async () => {
    for (const path of ['/v1/vehicles/0/status','/v1/vehicles/1/drives?limit=101','/v1/vehicles/1/drives?limit=1.5','/v1/vehicles/1/drives?cursor=garbage','/v1/vehicles/1/drives?from=2026-02-30T00:00:00Z','/v1/vehicles/1/drives?from=2026-02-01T00:00:00Z&to=2026-01-01T00:00:00Z','/v1/vehicles/1/summary?range=forever','/v1/vehicles/1/timeline?hours=745','/v1/vehicles/1/mileage?bucket=year','/v1/vehicles/1/idles?minMinutes=0']) expect((await request(path)).status).toBe(400);
  });
  test('history analytics stay within SQL timeout at realistic recording volume', async () => {
    await owner.file(new URL('./scale.sql', import.meta.url));
    // VACUUM must be a separate autocommit statement, not part of the SQL file.
    await owner`VACUUM (ANALYZE) public.positions`;
    const started = performance.now(), timings: Record<string, number> = {};
    const timed = async (name: string, path: string) => { const at = performance.now(); const value = await json(path); timings[name] = Math.round(performance.now()-at); return value; };
    const status = await timed('status','/v1/vehicles/1/status'); expect(status.vehicleId).toBe(1);
    const vehicles = await timed('vehicles','/v1/vehicles'); expect(vehicles.map((c:any)=>c.hasData)).toEqual([true,false,true]);
    const health = await timed('health','/v1/health'); expect(health.ok).toBe(true);
    const drives = await timed('drives', '/v1/vehicles/1/drives?limit=50'); expect(drives.items).toHaveLength(50);
    const mileage = await timed('mileage', '/v1/vehicles/1/mileage'); expect(mileage.length).toBeGreaterThan(1);
    const idles = await timed('idles', '/v1/vehicles/1/idles?limit=50'); expect(idles.items).toHaveLength(50);
    await owner`UPDATE drives SET end_position_id=NULL WHERE id>12450`;
    const fallbackIdles = await timed('idleCoordinatesFallback', '/v1/vehicles/1/idles?limit=50');
    expect(fallbackIdles.items).toHaveLength(50); expect(fallbackIdles.items.every((r:any)=>r.latitude===40 || r.latitude===40.01)).toBe(true);
    await timed('summaryZone','/v1/vehicles/1/summary?range=30d&tz=America/New_York');
    const battery = await timed('battery', '/v1/vehicles/1/battery'); expect(battery.capacityNowKwh).toBeGreaterThan(0);
    // Each SQL statement also has the unchanged production 15-second timeout.
    console.log(JSON.stringify({ event:'scale_receipt', added:{drives:2500,positions:1722500,parkedPositions:222500,states:7500,chargingProcesses:1000,chargeSamples:100000}, milliseconds:timings }));
    expect(performance.now()-started).toBeLessThan(15000);
  }, 120000);
  test('health failure is sanitized and no-data timestamp is null', async () => {
    await owner`TRUNCATE public.charges, public.positions, public.states CASCADE`;
    expect((await telemetry.health()).teslamate.lastDataAt).toBeNull();
    const broken = connect('postgres://nobody@127.0.0.1:1/no_db');
    try { expect(await new Telemetry(broken).health()).toEqual({ok:false,version:'0.1.0',teslamate:{reachable:false,lastDataAt:null}}); } finally { await broken.end(); }
  });
});

describe('database privilege boundaries', () => {
  const runAdmin = async (entry: string, prefix = '', suffix = '') => {
    const dir = await mkdtemp(join(tmpdir(),'volta-bootstrap-check-'));
    try {
      for (const name of ['bootstrap.sql','auth-recover.sql','auth-schema.sql','history-schema.sql','auth-grants.sql','privilege-checks.sql']) {
        const script = (await Bun.file(new URL(`../../deploy/${name}`,import.meta.url)).text()).split('\n').filter(line=>!line.startsWith('\\password ')).join('\n');
        await Bun.write(join(dir,name),script);
      }
      await Bun.write(join(dir,'run.sql'), `\\set ON_ERROR_STOP on\n${prefix}\n\\ir ${entry}\n${suffix}\n`);
      const psql = process.env.PG_BIN ? join(process.env.PG_BIN,'psql') : Bun.which('psql');
      if (!psql) throw new Error('PG_BIN or psql on PATH is required for the bootstrap test');
      const child = Bun.spawn([psql,url!,'-At','-v','ON_ERROR_STOP=1','-f',join(dir,'run.sql')],{stdout:'pipe',stderr:'pipe'});
      const [code,out,error] = await Promise.all([child.exited,new Response(child.stdout).text(),new Response(child.stderr).text()]);
      return {code,out,error};
    } finally { await rm(dir,{recursive:true,force:true}); }
  };
  test('reader can select telemetry but cannot mutate it or read auth/private tokens', async () => {
    expect((await reader`SELECT count(*) FROM public.cars`).length).toBe(1);
    await expect(Promise.resolve(reader`UPDATE public.cars SET name = 'bad' WHERE id = 1`)).rejects.toBeDefined();
    await expect(Promise.resolve(reader`SELECT * FROM volta.devices`)).rejects.toBeDefined();
    await expect(Promise.resolve(reader`SELECT * FROM private.tokens`)).rejects.toBeDefined();
    // Even after explicitly disabling read-only, grants still prohibit mutations.
    const unrestricted = connect(process.env.TESLAMATE_DATABASE_URL!);
    try { await unrestricted`SET default_transaction_read_only = off`; await expect(Promise.resolve(unrestricted`UPDATE public.cars SET name = 'bad' WHERE id = 1`)).rejects.toBeDefined(); } finally { await unrestricted.end(); }
  });
  test('bootstrap rejects unsafe legacy PUBLIC CREATE without changing shared grants', async () => {
    try {
      await owner`GRANT CREATE ON SCHEMA public TO PUBLIC`;
      const result = await runAdmin('bootstrap.sql');
      expect(result.code).not.toBe(0); expect(result.error).toContain('inherit unsafe privileges');
      const [row] = await owner`SELECT has_schema_privilege('volta_auth','public','CREATE') AS allowed`;
      expect(row!.allowed).toBe(true); // Bootstrap aborted instead of silently altering PUBLIC.
    } finally { await owner`REVOKE CREATE ON SCHEMA public FROM PUBLIC`; }
  });
  test('reapplied bootstrap preserves the ops telemetry limits', async () => {
    expect((await runAdmin('bootstrap.sql')).code).toBe(0);
    const [role] = await owner`SELECT rolconnlimit,rolconfig FROM pg_roles WHERE rolname='volta_reader'`;
    expect(role!.rolconnlimit).toBe(10);
    expect(role!.rolconfig).toEqual(expect.arrayContaining(['statement_timeout=30s','idle_in_transaction_session_timeout=60s','lock_timeout=5s','default_transaction_read_only=on']));
  });
  test('bootstrap and auth recovery reject inherited writes and sequence access in unrelated schemas', async () => {
    await owner`CREATE SCHEMA recovery_probe`;
    await owner`CREATE TABLE recovery_probe.data(id integer)`;
    await owner`CREATE SEQUENCE recovery_probe.counter`;
    await owner`GRANT USAGE ON SCHEMA recovery_probe TO PUBLIC`;
    try {
      for (const entry of ['bootstrap.sql','auth-recover.sql']) {
        await owner`GRANT UPDATE ON recovery_probe.data TO PUBLIC`;
        const writes = await runAdmin(entry); expect(writes.code).not.toBe(0); expect(writes.error).toContain('inherit unsafe privileges');
        await owner`REVOKE UPDATE ON recovery_probe.data FROM PUBLIC`;
        await owner`GRANT USAGE ON SEQUENCE recovery_probe.counter TO PUBLIC`;
        const sequence = await runAdmin(entry); expect(sequence.code).not.toBe(0); expect(sequence.error).toContain('inherit unsafe privileges');
        await owner`REVOKE USAGE ON SEQUENCE recovery_probe.counter FROM PUBLIC`;
        expect((await runAdmin(entry)).code).toBe(0);
      }
    } finally { await owner`DROP SCHEMA recovery_probe CASCADE`; }
  });
  test('same-cluster auth recovery restores grants without changing passwords or role settings', async () => {
    const recovered = await runAdmin('auth-recover.sql', `
      -- Synthetic fixture password only; no real credential is read or logged.
      ALTER ROLE volta_reader PASSWORD 'synthetic-recovery-only';
      ALTER ROLE volta_auth PASSWORD 'synthetic-recovery-only';
      CREATE TEMP TABLE expected_roles AS SELECT a.rolname,a.rolpassword,r.rolconfig,r.rolconnlimit
        FROM pg_authid a JOIN pg_roles r USING(rolname)
        WHERE a.rolname IN ('volta_reader','volta_auth','volta_readonly');
      REVOKE USAGE ON SCHEMA volta FROM volta_auth;
      REVOKE ALL ON ALL TABLES IN SCHEMA volta FROM volta_auth;
      REVOKE ALL ON ALL SEQUENCES IN SCHEMA volta FROM volta_auth;`, `
      SELECT 'roles_preserved=' || bool_and(e.rolpassword IS NOT DISTINCT FROM r.rolpassword
        AND e.rolconfig IS NOT DISTINCT FROM settings.rolconfig AND e.rolconnlimit=r.rolconnlimit)
        FROM expected_roles e JOIN pg_authid r USING(rolname) JOIN pg_roles settings USING(rolname);`);
    if (recovered.code !== 0) throw new Error(recovered.error);
    expect(recovered.code).toBe(0); expect(recovered.out).toContain('roles_preserved=true');
    expect((await authDb`SELECT count(*) FROM volta.devices`).length).toBe(1);
    const code = await auth.createPairingCode(); expect((await pair(code)).status).toBe(200);
  });
  test('both entry scripts reject non-inherited superuser membership and database CREATE', async () => {
    await owner`CREATE ROLE recovery_probe_super SUPERUSER NOLOGIN`;
    try {
      await owner`GRANT recovery_probe_super TO volta_auth WITH INHERIT FALSE`;
      for (const entry of ['bootstrap.sql','auth-recover.sql']) {
        const result = await runAdmin(entry); expect(result.code).not.toBe(0); expect(result.error).toContain('inherit unsafe privileges');
      }
      await owner`REVOKE recovery_probe_super FROM volta_auth`;
      await owner`GRANT CREATE ON DATABASE volta_test TO volta_auth`;
      for (const entry of ['bootstrap.sql','auth-recover.sql']) {
        const result = await runAdmin(entry); expect(result.code).not.toBe(0); expect(result.error).toContain('inherit unsafe privileges');
      }
      const [grants] = await owner`SELECT has_database_privilege('volta_auth',current_database(),'CREATE') AS present`;
      expect(grants!.present).toBe(true); // The guard fails closed without altering the administrator's grant.
      await owner`REVOKE CREATE ON DATABASE volta_test FROM volta_auth`;
      expect((await runAdmin('auth-recover.sql')).code).toBe(0);
    } finally {
      await owner`REVOKE recovery_probe_super FROM volta_auth`;
      await owner`REVOKE CREATE ON DATABASE volta_test FROM volta_auth`;
      await owner`DROP ROLE recovery_probe_super`;
    }
  });
  test('auth role can write only auth records, not TeslaMate data or private tokens', async () => {
    expect((await authDb`SELECT count(*) FROM volta.devices`).length).toBe(1);
    await expect(Promise.resolve(authDb`SELECT * FROM public.cars`)).rejects.toBeDefined();
    await expect(Promise.resolve(authDb`UPDATE public.cars SET name = 'bad' WHERE id=1`)).rejects.toBeDefined();
    await expect(Promise.resolve(authDb`SELECT * FROM private.tokens`)).rejects.toBeDefined();
    await expect(Promise.resolve(authDb`CREATE TABLE public.should_not_exist (id integer)`)).rejects.toBeDefined();
  });
});
