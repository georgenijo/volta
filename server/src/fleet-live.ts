import { createHash } from 'node:crypto';
import type { DB, Row } from './db';

export const liveFields = ['BatteryLevel','Soc','RatedRange','EstBatteryRange','ChargeLimitSoc','ModuleTempMax','ModuleTempMin','Locked','SentryMode','TpmsPressureFl','TpmsPressureFr','TpmsPressureRl','TpmsPressureRr','ChargePortDoorOpen','ChargePortLatch','InsideTemp','OutsideTemp','Version','Odometer','EnergyRemaining',
  'DetailedChargeState','ACChargingPower','DCChargingPower','ChargeAmps','ChargerVoltage','TimeToFullCharge','ACChargingEnergyIn','DCChargingEnergyIn','FastChargerPresent','ChargingCableType',
  'HvacPower','HvacLeftTemperatureRequest','Gear','VehicleSpeed','PackVoltage','PackCurrent','Location'];
/** Tesla's DetailedChargeState mapped onto the API's chargingState. */
const chargeStates: Record<string,string> = {DetailedChargeStateDisconnected:'disconnected',DetailedChargeStateNoPower:'stopped',
  DetailedChargeStateStarting:'charging',DetailedChargeStateCharging:'charging',DetailedChargeStateComplete:'complete',DetailedChargeStateStopped:'stopped'};
/** Tesla's ShiftState mapped onto the API's gear; Invalid, SNA and Unknown are unknown. */
const gears: Record<string,LiveGear> = {ShiftStateP:'P',ShiftStateR:'R',ShiftStateN:'N',ShiftStateD:'D'};
export type LiveGear = 'P'|'R'|'N'|'D';
/** One live drive value: when it was observed, and whether it still holds now. */
export type LiveReading<T> = { value: T; observedAt: Date; current: boolean; source: 'fleet_telemetry'|'teslamate' };
/** The stream in gear has reported no movement since `since`; the car's
 * average speed since then is below `speedBelowKph`. Not a claim that it stopped. */
export type LiveQuiet = { since: Date; speedBelowKph: number };
export type LiveDrive = { gear: LiveReading<LiveGear>|null; speedKph: LiveReading<number>|null; powerKw: LiveReading<number>|null; quiet: LiveQuiet|null };
/** Location arrives only after the car moves (normal profile: every 2 s
 * after 3 m; economy: every 10 s after 15 m, ingestion/fleetconfig), with
 * VehicleSpeed, PackVoltage and PackCurrent riding on it. The receiver holds
 * the last speed a stopping car reported (often 1 to 5 mph). So a speed or
 * power reading is current only briefly after it was observed (`currentMs`).
 * A connected stream in gear quiet for longer proves only that the car has
 * moved less than the report distance since (see `quietSpeedBelowKph`).
 * The window follows the installed profile: five times its interval
 * (`installedFixIntervalS`), within 10 to 60 s; while that is unknown,
 * nothing is inferred. */
export const stillnessMs = (fixIntervalS: number | null) => fixIntervalS == null || !Number.isFinite(fixIntervalS) || fixIntervalS <= 0
  ? null : Math.min(60_000, Math.max(10_000, fixIntervalS * 5_000));
/** Location's MinimumDelta over IntervalSeconds, the same in both profiles
 * (3 m / 2 s, 15 m / 10 s; checked against fleetconfig.go by the tests). */
export const reportDistancePerIntervalM = 1.5;
/** The speed a car quiet for `quietMs` must be below. A car checks each
 * interval and reports once it has moved the report distance, so over
 * (quiet − one interval) it moved less than that distance. */
export const quietSpeedBelowKph = (fixIntervalS: number, quietMs: number) =>
  reportDistancePerIntervalM * fixIntervalS / Math.max(fixIntervalS, quietMs / 1000 - fixIntervalS) * 3.6;
/** Location's IntervalSeconds in the installed profiles (normal, economy;
 * checked against fleetconfig.go by the tests). */
export const profileFixIntervalsS = [2, 10] as const;
/** At this speed a car passes the report distance well within one interval
 * in both profiles (5.6 m per 2 s against 3 m; 55 m per 10 s against 15 m),
 * so consecutive fixes this fast are one interval apart. Slower fixes are
 * not: a car creeping in a queue reports once per 3 m, which can be 30 s
 * apart on a 2 s profile. */
export const cadenceSpeedKph = 20;
/** The installed interval from the shortest gap between fast consecutive
 * fixes: the longest configured interval that gap allows (reports never come
 * faster than the interval; 0.5 s for timestamp jitter). Without such a gap
 * the cadence is unknown, and nothing is inferred from silence. */
export const installedFixIntervalS = (movingGapS: number | null): number | null => movingGapS == null || !Number.isFinite(movingGapS) || movingGapS <= 0
  ? null : profileFixIntervalsS.filter(i => i <= movingGapS + 0.5).at(-1) ?? profileFixIntervalsS[0];
/** Current window for a reading while the cadence is unknown. */
export const defaultCurrentMs = 10_000;
/** How long a stream speed or power reading holds now. A moving car reports
 * at least once per interval, so one interval plus transit, but never under
 * the unknown-cadence window: 10 s on the 2 s profile, 12 s on economy.
 * Unlike the stillness window this never grows with the cadence, because an
 * inferred cadence can be too long (a normal-profile car whose only fast
 * pair spans a lost report looks like economy); then a stopped car's held
 * speed stays current for at most 12 s, and quiet is only inferred later. */
export const currentMs = (fixIntervalS: number | null) => fixIntervalS == null || !Number.isFinite(fixIntervalS) || fixIntervalS <= 0
  ? defaultCurrentMs : Math.max(defaultCurrentMs, Math.min(stillnessMs(fixIntervalS)!, fixIntervalS * 1000 + reportTransitMs));
/** A TeslaMate position from the open drive is current this long. */
export const teslamateCurrentMs = 30_000;

/** Latest means latest observation, including invalidation; never resurrect an older valid value. */
export class FleetLive {
  constructor(private sql: DB) {}
  async read(id: number) {
    const s = this.sql;
    // Validate the mapping and read all signals in one database snapshot. No
    // VIN or receiver identifiers are returned by the API or logged.
    const [row] = await s`SELECT b.vin_digest,c.vin,
      COALESCE((SELECT jsonb_agg(to_jsonb(l)) FROM volta_telemetry.latest_samples l
        WHERE l.vehicle_id=b.vehicle_id AND l.field=ANY(${liveFields}::text[])), '[]'::jsonb) AS samples,
      (SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT DISTINCT ON(connection_id) status,source_ts,received_at
        FROM volta_telemetry.connectivity WHERE vehicle_id=b.vehicle_id
          AND source_ts >= COALESCE((SELECT receiver_started_at FROM volta_telemetry.stream_health WHERE id=1),now()) - interval '1 second'
        ORDER BY connection_id,source_ts DESC,received_at DESC,status DESC) x) AS connections,
      (SELECT to_jsonb(h) FROM volta_telemetry.stream_health h WHERE id=1) AS health,
      (SELECT jsonb_build_object('start',s.start_ts,'open',s.end_reason='open','observed',s.start_reason='charge_state','dc',EXISTS(SELECT 1 FROM volta_telemetry.session_samples x
          WHERE x.vehicle_id=s.vehicle_id AND x.source_ts>=s.start_ts
            AND x.source_ts<=CASE WHEN s.end_reason='open' THEN now() ELSE LEAST(s.end_ts,now()) END AND x.dc_power_kw>0)) FROM volta_telemetry.sessions s
        WHERE s.vehicle_id=b.vehicle_id AND s.kind='charge' ORDER BY s.start_ts DESC LIMIT 1) AS last_charge,
      (SELECT sign FROM volta_telemetry.power_calibration WHERE vehicle_id=b.vehicle_id) AS power_sign,
      -- The shortest gap between consecutive recent fixes that were both
      -- moving fast enough to report every interval (see installedFixIntervalS).
      (SELECT extract(epoch FROM min(gap)) FROM (SELECT source_ts - lag(source_ts) OVER (ORDER BY source_ts) AS gap,
          speed_kph AS speed, lag(speed_kph) OVER (ORDER BY source_ts) AS prior
        FROM (SELECT source_ts,speed_kph FROM volta_telemetry.payload_points p WHERE p.vehicle_id=b.vehicle_id AND p.latitude IS NOT NULL
          AND p.source_ts > now() - interval '15 minutes' AND p.source_ts <= now() ORDER BY source_ts DESC LIMIT 30) f) g
        WHERE gap > interval '0' AND speed >= ${cadenceSpeedKph} AND prior >= ${cadenceSpeedKph}) AS moving_fix_gap_s
      FROM volta_telemetry.api_vehicle_bindings b JOIN public.cars c ON c.id=b.vehicle_id WHERE b.vehicle_id=${id}`;
    if (!row?.vin || !/^[A-HJ-NPR-Z0-9]{17}$/.test(row.vin)) return null;
    const digest = createHash('sha256').update('volta-telemetry-vin-binding-v1\0').update(row.vin, 'utf8').digest('hex');
    if (row.vin_digest !== digest) return null;
    return { samples: row.samples as Row[], connections: (row.connections ?? []) as Row[], health: row.health as Row | null,
      lastCharge: row.last_charge ? { start: new Date(row.last_charge.start), open: row.last_charge.open === true,
        observed: row.last_charge.observed === true, dc: row.last_charge.dc === true } : null,
      powerSign: (row.power_sign ?? null) as string | null,
      fixIntervalS: installedFixIntervalS(row.moving_fix_gap_s == null ? null : Number(row.moving_fix_gap_s)) };
  }
}

export function liveValues(live: Awaited<ReturnType<FleetLive['read']>>, now: Date) {
  if (!live) return null;
  const by = new Map(live.samples.map(s => [s.field, s]));
  const valid = (f: string) => { const s = by.get(f); return s && !s.invalid && s.quality === 'ok' && +new Date(s.source_ts) <= +now ? s : null; };
  const num = (f: string, units: Record<string, number>) => {
    const s = valid(f), factor = s && units[s.source_unit];
    return s && factor != null && typeof s.value_num === 'number' && Number.isFinite(s.value_num) ? s.value_num * factor : null;
  };
  const bool = (f: string) => valid(f)?.value_bool ?? null;
  const text = (f: string) => valid(f)?.value_text ?? null;
  const times = Object.fromEntries(live.samples.map(s => [s.field, s.source_ts]));
  const h = live.health;
  const recent = (at: any) => at != null && +now - +new Date(at) >= 0 && +now - +new Date(at) <= 120_000;
  const healthy = !!h?.receiver_generation && recent(h.receiver_seen_at) && recent(h.updated_at) && recent(h.caught_up_at) && h.lag_records != null && Number(h.lag_records) === 0;
  // Connections from before a receiver restart cannot prove this stream is connected.
  const connected = healthy && live.connections.some(c => c.status === 'CONNECTED' &&
    c.received_at != null && h!.receiver_started_at != null &&
    +new Date(c.received_at) >= +new Date(h!.receiver_started_at) && +new Date(c.source_ts) <= +now);
  const lastSeenAt = [...live.samples.map(s => s.source_ts), ...live.connections.map(c => c.source_ts)]
    .filter(t => t && +new Date(t) <= +now).sort((a,b) => +new Date(b)-+new Date(a))[0] ?? null;
  // User climate and departure preconditioning are climate on. Cabin overheat
  // protection is a separate mode with its own limit: calling it "on" would
  // offer Stop instead of Start and show the cabin set point, so it is unknown.
  const hvac = text('HvacPower');
  const climateOn = hvac === 'HvacPowerStateOff' ? false :
    ['HvacPowerStateOn','HvacPowerStatePrecondition'].includes(hvac) ? true : null;
  const sentry = text('SentryMode');
  const sentryMode = sentry === 'SentryModeStateOff' ? false :
    ['SentryModeStateIdle','SentryModeStateArmed','SentryModeStateAware','SentryModeStatePanic','SentryModeStateQuiet'].includes(sentry) ? true : null;
  // Charging is reported separately so status merges it as one unit. Charging
  // belongs to the open session; Complete or Stopped still describes the newest
  // one (the receiver closes it on that state). Readings from before that
  // session began are a previous session's: a held counter, a charger-type
  // flag, or a positive power whose drop to zero was missed. A session that
  // drew DC power at any point stays DC after its power falls to zero.
  const at = (f: string) => valid(f) ? new Date(by.get(f)!.source_ts) : null;
  const state = chargeStates[text('DetailedChargeState') ?? ''] ?? null, last = live.lastCharge ?? null;
  const session = last && (last.open || state === 'complete' || state === 'stopped') ? last.start : null;
  const current = (v: number | null, t: Date | null) => v != null && v > 0 && t != null && (!session || +t >= +session);
  const ac = num('ACChargingPower',{kW:1}), dc = num('DCChargingPower',{kW:1}), acAt = at('ACChargingPower'), dcAt = at('DCChargingPower');
  const flagAt = at('FastChargerPresent');
  const fast = (session != null && last!.dc) || (current(dc, dcAt) && (!current(ac, acAt) || +dcAt! >= +acAt!)) ||
    (bool('FastChargerPresent') === true && session != null && flagAt != null && +flagAt >= +session);
  const counter = fast ? 'DCChargingEnergyIn' : 'ACChargingEnergyIn', counted = at(counter);
  const eta = num('TimeToFullCharge',{h:60}), etaAt = at('TimeToFullCharge');
  const fields = ['DetailedChargeState', fast ? 'DCChargingPower' : 'ACChargingPower', 'TimeToFullCharge', counter, 'ChargeAmps', 'ChargerVoltage'];
  const charge = { state, at: at('DetailedChargeState'), powerKw: fast ? dc : ac, fast, minutesToFull: eta,
    // When the car expects to be full, anchored to the estimate's own observation.
    readyAt: eta != null && etaAt ? new Date(+etaAt + eta * 60_000) : null,
    observedAt: fields.map(at).filter(t => t != null).sort((a,b) => +b-+a)[0] ?? null,
    currentA: num('ChargeAmps',{A:1}), voltage: num('ChargerVoltage',{V:1}), cableType: text('ChargingCableType'), startedAt: session,
    // Whether the session began at an observed charge start, not mid-charge (after a split gap or a late join).
    startObserved: session ? last!.observed : null,
    energyAddedKwh: session && counted && +counted >= +session ? num(counter,{kWh:1}) : null };
  const drive = driveValues(live, by, valid, connected, healthy ? h! : null, now);
  const tire = (suffix: string) => ({ pressureBar: num(`TpmsPressure${suffix}`, {bar:1,psi:1/14.5037738,kPa:.01}), updatedAt: times[`TpmsPressure${suffix}`] ?? null });
  return { values: {
    batteryLevel:num('BatteryLevel',{'%':1}), usableBatteryLevel:num('Soc',{'%':1}),
    ratedRangeKm:num('RatedRange',{mi:1.609344,km:1}),estRangeKm:num('EstBatteryRange',{mi:1.609344,km:1}),chargeLimit:num('ChargeLimitSoc',{'%':1}),
    packTempMaxC:num('ModuleTempMax',{C:1}),packTempMinC:num('ModuleTempMin',{C:1}), locked:bool('Locked'),sentryMode,
    chargePortDoorOpen:bool('ChargePortDoorOpen'),chargePortLatch:text('ChargePortLatch'),
    insideTempC:num('InsideTemp',{C:1}),outsideTempC:num('OutsideTemp',{C:1}),climateOn,driverTempSettingC:num('HvacLeftTemperatureRequest',{C:1}),firmware:text('Version'),
    odometerKm:num('Odometer',{mi:1.609344,km:1}),energyRemainingKwh:num('EnergyRemaining',{kWh:1}),
  }, tpms:{fl:tire('Fl'),fr:tire('Fr'),rl:tire('Rl'),rr:tire('Rr')},
  // A recognized overheat-protection reading is current evidence, not a gap:
  // status uses it to clear an older recorded climate state.
  overheatProtect: hvac === 'HvacPowerStateOverheatProtect',
  freshness:{connected,lastSeenAt,recordedAt:times}, charge, drive: drive.drive, movementAt: drive.movementAt, by };
}

/** How long a report takes from the car to the broker, at most, when the
 * receiver is up. A pipeline proven through T has stored what the car sent
 * by T minus this. */
export const reportTransitMs = 2_000;
/** Proof older than this is not current: stream health is written every
 * 15 s, so three missed writes mean ingestion may have stopped. A quiet span
 * proven before then could have ended since, so none is reported. */
export const quietProofMs = 45_000;

/** Gear, speed and pack power from the stream. Gear is change-only, so a
 * connected stream's gear holds now; speed and power hold only while the car
 * keeps reporting (see stillnessMs). Power needs voltage and current from
 * the same payload and the operator's recorded PackCurrent sign.
 *
 * Silence counts only as far as the pipeline is proven to have stored
 * everything the car sent: the receiver seen alive and the consumer caught
 * up (`health`, written every 15 s). A receiver that dies after a highway
 * fix still looks connected for a while; its silence proves nothing, so the
 * readings go stale and no quiet span is inferred; nor is one proven
 * earlier once the proof is older than `quietProofMs`. `movementAt` is the
 * stream's newest position report, for merging with TeslaMate. */
function driveValues(live: NonNullable<Awaited<ReturnType<FleetLive['read']>>>, by: Map<string, Row>,
                     valid: (f: string) => Row | null, connected: boolean, health: Row | null, now: Date): { drive: LiveDrive; movementAt: Date | null } {
  const at = (s: Row) => new Date(s.source_ts);
  const reading = <T>(value: T | null, s: Row | null, current: boolean): LiveReading<T> | null =>
    value == null || !s ? null : { value, observedAt: at(s), current, source: 'fleet_telemetry' };
  const still = stillnessMs(live.fixIntervalS);
  const recent = (s: Row | null) => connected && s != null && +now - +at(s) <= currentMs(live.fixIntervalS);
  const g = valid('Gear'), gear = g ? gears[g.value_text] ?? null : null;
  const s = valid('VehicleSpeed'), mph = s?.source_unit === 'mph' ? 1.609344 : s?.source_unit === 'km/h' ? 1 : null;
  const speed = s && mph != null && Number.isFinite(s.value_num) ? s.value_num * mph : null;
  const v = valid('PackVoltage'), a = valid('PackCurrent');
  const sign = live.powerSign === 'discharge_positive' ? 1 : live.powerSign === 'discharge_negative' ? -1 : null;
  const power = v && a && sign && v.payload_id === a.payload_id && +at(v) === +at(a) && v.source_unit === 'V' && a.source_unit === 'A' &&
    Number.isFinite(v.value_num) && v.value_num > 0 && Number.isFinite(a.value_num) ? v.value_num * a.value_num / 1000 * sign : null;
  // The newest position report, valid or not; a car without a GPS fix (a
  // tunnel) may stop reporting while it moves, so only a valid fix bounds its speed.
  const report = ['Location','VehicleSpeed'].map(f => by.get(f)).filter((r): r is Row => r != null && +at(r) <= +now)
    .sort((x, y) => +at(y) - +at(x))[0] ?? null;
  const fix = by.get('Location');
  const proven = health ? Math.min(+now, +new Date(health.receiver_seen_at), +new Date(health.caught_up_at)) - reportTransitMs : null;
  const quietMs = report && proven != null ? proven - +at(report) : null;
  const quiet = still != null && connected && gear != null && gear !== 'P' && report && fix && !fix.invalid && fix.quality === 'ok' &&
    +at(fix) >= +at(report) && quietMs != null && quietMs > still && +now - proven! <= quietProofMs
    ? { since: new Date(Math.max(+at(report), +at(g!))), speedBelowKph: quietSpeedBelowKph(live.fixIntervalS!, quietMs) } : null;
  return { drive: { gear: reading(gear, g, connected), speedKph: reading(speed, s, recent(s)), powerKw: reading(power, power == null ? null : v, recent(v)), quiet },
           movementAt: report ? at(report) : null };
}
