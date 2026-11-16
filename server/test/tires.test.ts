import { afterAll, beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import { Auth } from '../src/auth';
import { createApp } from '../src/app';
import { connect } from '../src/db';
import { Telemetry } from '../src/telemetry';
import { TireHistory, bucketFor, tireInput } from '../src/tires';

// Synthetic tyre readings only: Bay Area coordinates, synthetic VINs.
const url = process.env.TEST_DATABASE_URL;
if (!url || new URL(url).pathname !== '/volta_test' || !['127.0.0.1','localhost'].includes(new URL(url).hostname)) throw new Error('Tests require an isolated localhost database named volta_test. Run bun run test:local.');
const owner = connect(url, false, 120000), reader = connect(process.env.TESLAMATE_DATABASE_URL!, true), authDb = connect(process.env.AUTH_DATABASE_URL!);
const clock = () => new Date('2026-06-30T12:00:00Z');
const auth = new Auth(authDb), telemetry = new Telemetry(reader, 'USD', clock);
const app = createApp(auth, telemetry, () => {});
let token = '';
const request = (path: string) => app.request(path, { headers: { Authorization: `Bearer ${token}` } });
const history = (query: Record<string, string> = {}, id = 1) => new TireHistory(reader, clock).read(id, tireInput(query));

type Reading = [at: string, fl: number | null, fr: number | null, rl: number | null, rr: number | null];
let nextId = 1;
async function readings(car: number, rows: Reading[]) {
  for (const [at, fl, fr, rl, rr] of rows) {
    await owner`INSERT INTO public.positions (id, car_id, date, latitude, longitude, tpms_pressure_fl, tpms_pressure_fr, tpms_pressure_rl, tpms_pressure_rr)
      VALUES (${nextId++}, ${car}, ${at.replace('Z', '')}::timestamp, 37.4419, -122.143, ${fl}, ${fr}, ${rl}, ${rr})`;
  }
}

beforeAll(async () => { await owner`SELECT 1`; });
beforeEach(async () => {
  await owner`TRUNCATE public.charges, public.charging_processes, public.positions, public.drives, public.states, public.updates, public.cars, public.car_settings, volta.devices, volta.pairing_codes, volta.rate_limits RESTART IDENTITY CASCADE`;
  await owner`INSERT INTO public.car_settings (id) VALUES (1), (2)`;
  await owner`INSERT INTO public.cars (id, eid, vid, vin, name, model, settings_id, inserted_at, updated_at)
    VALUES (1, 1001, 2001, 'SYNTHETIC000000001', 'Synthetic Model 3', '3', 1, now(), now()),
           (2, 1002, 2002, 'SYNTHETIC000000002', 'Empty Tesla', 'Y', 2, now(), now())`;
  nextId = 1;
  const pair = await auth.pair({ code: await auth.createPairingCode(), deviceName: 'Synthetic phone' });
  token = pair.token;
});
afterAll(async () => { await Promise.all([owner.end(), reader.end(), authDb.end()]); });

describe('tyre pressure history', () => {
  test('empty history: every wheel has no points and no reading dates', async () => {
    const body = await history();
    expect(body).toMatchObject({ vehicleId: 1, source: 'teslamate', unit: 'bar', bucket: 'day', timeZone: 'UTC', firstReadingAt: null, lastReadingAt: null });
    expect(body.wheels).toEqual({ fl: [], fr: [], rl: [], rr: [] });
  });

  test('one reading is one point per reporting wheel', async () => {
    await readings(1, [['2026-06-01T08:00:00Z', 2.9, 2.9, 2.8, 2.8]]);
    const body = await history();
    expect(body.wheels.fl).toEqual([{ start: new Date('2026-06-01T00:00:00Z'), minBar: 2.9, avgBar: 2.9, maxBar: 2.9, readings: 1,
      firstAt: new Date('2026-06-01T08:00:00Z'), lastAt: new Date('2026-06-01T08:00:00Z'),
      peerReadings: 1, peerDeltaBar: expect.closeTo(2.9 - 8.5 / 3, 9), peerBar: expect.closeTo(8.5 / 3, 9), peerWheels: 3 }]);
    expect(body.firstReadingAt).toEqual(new Date('2026-06-01T08:00:00Z'));
    expect(body.lastReadingAt).toEqual(new Date('2026-06-01T08:00:00Z'));
  });

  test('a day keeps its lowest, mean and highest reading', async () => {
    await readings(1, [['2026-06-01T06:00:00Z', 2.7, 2.8, 2.8, 2.8], ['2026-06-01T09:00:00Z', 3.0, 3.0, 3.0, 3.0], ['2026-06-01T10:00:00Z', 2.9, 2.9, 2.9, 2.9]]);
    const [point] = (await history()).wheels.fl;
    expect(point!.minBar).toBe(2.7); expect(point!.maxBar).toBe(3.0); expect(point!.readings).toBe(3);
    expect(point!.avgBar).toBeCloseTo(2.8667, 3);
  });

  test('a gap in the record stays a gap: no bucket is invented for missing days', async () => {
    await readings(1, [['2026-06-01T08:00:00Z', 2.9, 2.9, 2.9, 2.9], ['2026-06-05T08:00:00Z', 2.8, 2.9, 2.9, 2.9]]);
    const fl = (await history()).wheels.fl;
    expect(fl.map(p => p.start.toISOString())).toEqual(['2026-06-01T00:00:00.000Z', '2026-06-05T00:00:00.000Z']);
  });

  test('a wheel with no data has no points while the others report', async () => {
    await readings(1, [['2026-06-01T08:00:00Z', 2.9, 2.9, 2.9, null], ['2026-06-02T08:00:00Z', 2.9, 2.9, 2.9, null]]);
    const body = await history();
    expect(body.wheels.rr).toEqual([]);
    expect(body.wheels.fl).toHaveLength(2);
  });

  test('zero and impossible readings are no reading, not a pressure', async () => {
    await readings(1, [['2026-06-01T08:00:00Z', 0, 2.9, 11, 2.9], ['2026-06-01T09:00:00Z', 2.8, 2.9, 2.9, 2.9]]);
    const body = await history();
    expect(body.wheels.fl.map(p => [p.minBar, p.readings])).toEqual([[2.8, 1]]);
    expect(body.wheels.rl.map(p => [p.maxBar, p.readings])).toEqual([[2.9, 1]]);
  });

  test('days are local to the requested zone and returned as UTC instants', async () => {
    // 06:30 UTC is still the previous evening in Los Angeles (PDT, UTC-7).
    await readings(1, [['2026-06-02T06:30:00Z', 2.9, 2.9, 2.9, 2.9], ['2026-06-02T08:00:00Z', 2.7, 2.7, 2.7, 2.7]]);
    const la = (await history({ tz: 'America/Los_Angeles' })).wheels.fl;
    expect(la.map(p => [p.start.toISOString(), p.minBar])).toEqual([['2026-06-01T07:00:00.000Z', 2.9], ['2026-06-02T07:00:00.000Z', 2.7]]);
    const utc = (await history()).wheels.fl;
    expect(utc.map(p => p.readings)).toEqual([2]);
  });

  test('from and to bound the readings (to is exclusive)', async () => {
    await readings(1, [['2026-05-01T08:00:00Z', 2.6, 2.6, 2.6, 2.6], ['2026-06-01T08:00:00Z', 2.9, 2.9, 2.9, 2.9], ['2026-06-10T08:00:00Z', 2.8, 2.8, 2.8, 2.8]]);
    const body = await history({ from: '2026-05-15T00:00:00Z', to: '2026-06-10T08:00:00Z' });
    expect(body.wheels.fl.map(p => p.maxBar)).toEqual([2.9]);
    expect(body.from).toEqual(new Date('2026-05-15T00:00:00Z'));
    expect(body.to).toEqual(new Date('2026-06-10T08:00:00Z'));
  });

  test('a from at or after the defaulted end (now) is invalid, not an empty history', async () => {
    await expect(history({ from: '2027-01-01T00:00:00Z' })).rejects.toMatchObject({ code: 'invalid_input' });
    await expect(history({ from: clock().toISOString() })).rejects.toMatchObject({ code: 'invalid_input' });
    // An explicit range keeps its full precision: microseconds apart is still a range.
    await expect(history({ from: '2026-06-30T11:00:00.000001Z', to: '2026-06-30T11:00:00.000002Z' })).resolves.toMatchObject({ bucket: 'day' });
    const response = await request('/v1/vehicles/1/tires?from=2027-01-01T00:00:00Z');
    expect(response.status).toBe(400);
    expect((await response.json() as any).error.code).toBe('invalid_input');
  });

  test('readings after now are excluded when no end is given', async () => {
    await readings(1, [['2026-06-30T11:00:00Z', 2.9, 2.9, 2.9, 2.9], ['2026-07-01T08:00:00Z', 2.5, 2.5, 2.5, 2.5]]);
    expect((await history()).wheels.fl.map(p => p.minBar)).toEqual([2.9]);
  });

  test('spans over 400 days are weekly, starting on local Mondays', async () => {
    await readings(1, [['2025-01-01T08:00:00Z', 2.9, 2.9, 2.9, 2.9], ['2026-06-03T08:00:00Z', 2.8, 2.8, 2.8, 2.8], ['2026-06-05T08:00:00Z', 2.6, 2.6, 2.6, 2.6]]);
    const body = await history();
    expect(body.bucket).toBe('week');
    expect(body.wheels.fl.map(p => [p.start.toISOString(), p.minBar, p.readings])).toEqual([
      ['2024-12-30T00:00:00.000Z', 2.9, 1], ['2026-06-01T00:00:00.000Z', 2.6, 2]]);
    // The same record inside a short window stays daily.
    expect((await history({ from: '2026-05-01T00:00:00Z' })).bucket).toBe('day');
    // An explicit long window is weekly even with no readings in it.
    expect((await history({ from: '2020-01-01T00:00:00Z' }, 2)).bucket).toBe('week');
  });

  test('a sensor that misses the cold readings is compared only with its contemporaries', async () => {
    // All four tyres read 2.7 bar cold and 3.0 warm; front left misses the cold rows.
    await readings(1, [['2026-06-01T06:00:00Z', null, 2.7, 2.7, 2.7], ['2026-06-01T06:30:00Z', null, 2.7, 2.7, 2.7],
      ['2026-06-01T15:00:00Z', 3.0, 3.0, 3.0, 3.0], ['2026-06-01T16:00:00Z', 3.0, 3.0, 3.0, 3.0]]);
    const body = await history();
    const [fl] = body.wheels.fl, [fr] = body.wheels.fr;
    // The independent daily low differs by 0.3 bar ...
    expect(fl!.minBar).toBe(3.0); expect(fr!.minBar).toBe(2.7);
    // ... but at every shared moment the wheels agree.
    expect(fl).toMatchObject({ readings: 2, peerReadings: 2, peerBar: expect.closeTo(3.0, 9), peerDeltaBar: expect.closeTo(0, 9) });
    for (const wheel of ['fr', 'rl', 'rr'] as const) {
      expect(body.wheels[wheel][0]).toMatchObject({ readings: 4, peerReadings: 4, peerBar: expect.closeTo(2.85, 9), peerDeltaBar: expect.closeTo(0, 9) });
    }
  });

  test('a genuinely low tyre reads below the mean of the others read with it', async () => {
    await readings(1, [['2026-06-01T08:00:00Z', 2.4, 2.9, 2.9, 2.9], ['2026-06-01T09:00:00Z', 2.5, 3.0, 3.0, 3.0]]);
    const body = await history();
    expect(body.wheels.fl[0]).toMatchObject({ peerReadings: 2, peerDeltaBar: expect.closeTo(-0.5, 9), peerBar: expect.closeTo(2.95, 9) });
    // A healthy wheel's peers include the low one, so it reads slightly above them.
    expect(body.wheels.fr[0]).toMatchObject({ peerReadings: 2, peerDeltaBar: expect.closeTo(0.5 / 3, 9), peerBar: expect.closeTo(2.95 - 0.5 / 3, 9) });
  });

  test('a row with fewer than two other plausible wheels contributes no comparison', async () => {
    // rl is implausible and rr missing, so fl and fr each have one peer: no comparison.
    await readings(1, [['2026-06-01T08:00:00Z', 2.4, 2.9, 0, null], ['2026-06-02T08:00:00Z', 2.4, 2.9, 2.9, null]]);
    const body = await history();
    expect(body.wheels.fl.map(p => [p.readings, p.peerReadings, p.peerDeltaBar, p.peerBar])).toEqual([[1, 0, null, null], [1, 1, expect.closeTo(-0.5, 9), expect.closeTo(2.9, 9)]]);
    expect(body.wheels.fr[0]).toMatchObject({ readings: 1, peerReadings: 0, peerDeltaBar: null, peerBar: null });
    expect(body.wheels.rl.map(p => p.peerReadings)).toEqual([1]);
    // Two others took part in the one compared row; with none, nothing is claimed.
    expect(body.wheels.fl.map(p => p.peerWheels)).toEqual([null, 2]);
    expect(body.wheels.rr).toEqual([]);
  });

  test('weekly points weight each day by its readings, never a mean of daily means', async () => {
    await readings(1, [['2025-01-01T08:00:00Z', 2.9, 2.9, 2.9, 2.9],
      // Wednesday: three rows with front left 0.3 bar low.
      ['2026-06-03T08:00:00Z', 2.7, 3.0, 3.0, 3.0], ['2026-06-03T09:00:00Z', 2.7, 3.0, 3.0, 3.0], ['2026-06-03T10:00:00Z', 2.7, 3.0, 3.0, 3.0],
      // Friday: one row where all agree; rr is missing, which still leaves fl two peers.
      ['2026-06-05T08:00:00Z', 2.9, 2.9, 2.9, null]]);
    const body = await history();
    expect(body.bucket).toBe('week');
    const week = body.wheels.fl[1]!;
    expect(week.start).toEqual(new Date('2026-06-01T00:00:00Z'));
    expect(week.readings).toBe(4); expect(week.peerReadings).toBe(4);
    expect(week.avgBar).toBeCloseTo((2.7 * 3 + 2.9) / 4, 9);          // 2.75, not (2.7 + 2.9) / 2
    expect(week.peerDeltaBar!).toBeCloseTo((-0.3 * 3 + 0) / 4, 9);   // -0.225, not -0.15
    expect(week.peerBar!).toBeCloseTo((3.0 * 3 + 2.9) / 4, 9);        // 2.975, not 2.95
    expect(body.wheels.rr[1]).toMatchObject({ readings: 3, peerReadings: 3, peerDeltaBar: expect.closeTo(0.1, 9), peerWheels: 3 });
    // Front left was compared with three wheels on Wednesday and two on Friday:
    // the week cannot say how many, so it says nothing.
    expect(week.peerWheels).toBeNull();
  });

  test('only the requested car is read', async () => {
    await readings(2, [['2026-06-01T08:00:00Z', 2.0, 2.0, 2.0, 2.0]]);
    expect((await history()).wheels.fl).toEqual([]);
    expect((await history({}, 2)).wheels.fl).toHaveLength(1);
  });

  test('bucket choice', () => {
    expect(bucketFor(null, new Date())).toBe('day');
    expect(bucketFor(new Date('2026-01-01T00:00:00Z'), new Date('2027-02-05T00:00:00Z'))).toBe('day');
    expect(bucketFor(new Date('2026-01-01T00:00:00Z'), new Date('2027-02-06T00:00:01Z'))).toBe('week');
  });
});

describe('GET /v1/vehicles/:id/tires', () => {
  test('serves the history as JSON with ISO dates', async () => {
    await readings(1, [['2026-06-01T08:00:00Z', 2.9, 2.9, 2.8, 2.8]]);
    const response = await request('/v1/vehicles/1/tires?tz=America/Los_Angeles&from=2026-05-01T00:00:00Z');
    expect(response.status).toBe(200);
    const body = await response.json() as any;
    expect(body.wheels.rr[0]).toEqual({ start: '2026-06-01T07:00:00.000Z', minBar: 2.8, avgBar: 2.8, maxBar: 2.8, readings: 1,
      firstAt: '2026-06-01T08:00:00.000Z', lastAt: '2026-06-01T08:00:00.000Z',
      peerReadings: 1, peerDeltaBar: expect.closeTo(2.8 - 8.6 / 3, 9), peerBar: expect.closeTo(8.6 / 3, 9), peerWheels: 3 });
    expect(body.timeZone).toBe('America/Los_Angeles');
  });

  test('requires a token, validates input and answers 404 for unknown cars', async () => {
    expect((await app.request('/v1/vehicles/1/tires')).status).toBe(401);
    for (const query of ['tz=Not/AZone', 'tz=%2B02:00', 'from=yesterday', 'from=2026-06-02T00:00:00Z&to=2026-06-01T00:00:00Z']) {
      const response = await request(`/v1/vehicles/1/tires?${query}`);
      expect(response.status).toBe(400);
      expect((await response.json() as any).error.code).toBe('invalid_input');
    }
    expect((await request('/v1/vehicles/99/tires')).status).toBe(404);
    expect((await request('/v1/vehicles/0/tires')).status).toBe(400);
  });

  test('a car outside the configured one is not found', async () => {
    const scoped = createApp(auth, new Telemetry(reader, 'USD', clock, false, () => {}, 2), () => {});
    expect((await scoped.request('/v1/vehicles/1/tires', { headers: { Authorization: `Bearer ${token}` } })).status).toBe(404);
  });

  test('the API role cannot write TeslaMate positions', async () => {
    // postgres.js queries are lazy: they run only when `.then` is called, and
    // bun 1.4.1's `rejects` never calls it, so a bare query here would never
    // be sent and the test would wait forever. Promise.resolve starts it.
    await expect(Promise.resolve(reader`INSERT INTO public.positions (id, car_id, date, latitude, longitude) VALUES (999, 1, now(), 37.44, -122.14)`))
      .rejects.toThrow(/read-only|permission denied/);
  });
});
