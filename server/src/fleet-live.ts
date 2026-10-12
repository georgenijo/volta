import { createHash } from 'node:crypto';
import type { DB, Row } from './db';

export const liveFields = ['BatteryLevel','Soc','RatedRange','EstBatteryRange','ChargeLimitSoc','ModuleTempMax','ModuleTempMin','Locked','SentryMode','TpmsPressureFl','TpmsPressureFr','TpmsPressureRl','TpmsPressureRr','ChargePortDoorOpen','ChargePortLatch','InsideTemp','OutsideTemp','Version','Odometer','EnergyRemaining',
  'DetailedChargeState','ACChargingPower','DCChargingPower','ChargeAmps','ChargerVoltage','TimeToFullCharge','ACChargingEnergyIn','DCChargingEnergyIn','FastChargerPresent','ChargingCableType'];
/** Tesla's DetailedChargeState mapped onto the API's chargingState. */
const chargeStates: Record<string,string> = {DetailedChargeStateDisconnected:'disconnected',DetailedChargeStateNoPower:'stopped',
  DetailedChargeStateStarting:'charging',DetailedChargeStateCharging:'charging',DetailedChargeStateComplete:'complete',DetailedChargeStateStopped:'stopped'};

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
      (SELECT jsonb_build_object('start',s.start_ts,'open',s.end_reason='open') FROM volta_telemetry.sessions s
        WHERE s.vehicle_id=b.vehicle_id AND s.kind='charge' ORDER BY s.start_ts DESC LIMIT 1) AS last_charge
      FROM volta_telemetry.api_vehicle_bindings b JOIN public.cars c ON c.id=b.vehicle_id WHERE b.vehicle_id=${id}`;
    if (!row?.vin || !/^[A-HJ-NPR-Z0-9]{17}$/.test(row.vin)) return null;
    const digest = createHash('sha256').update('volta-telemetry-vin-binding-v1\0').update(row.vin, 'utf8').digest('hex');
    if (row.vin_digest !== digest) return null;
    return { samples: row.samples as Row[], connections: (row.connections ?? []) as Row[], health: row.health as Row | null,
      lastCharge: row.last_charge ? { start: new Date(row.last_charge.start), open: row.last_charge.open === true } : null };
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
  const sentry = text('SentryMode');
  const sentryMode = sentry === 'SentryModeStateOff' ? false :
    ['SentryModeStateIdle','SentryModeStateArmed','SentryModeStateAware','SentryModeStatePanic','SentryModeStateQuiet'].includes(sentry) ? true : null;
  // Charging is reported separately so status merges it as one unit. Charging
  // belongs to the open session; Complete or Stopped still describes the newest
  // one (the receiver closes it on that state). Readings from before that
  // session began are a previous session's: a held counter, or a positive
  // power whose drop to zero was missed.
  const at = (f: string) => valid(f) ? new Date(by.get(f)!.source_ts) : null;
  const state = chargeStates[text('DetailedChargeState') ?? ''] ?? null, last = live.lastCharge ?? null;
  const session = last && (last.open || state === 'complete' || state === 'stopped') ? last.start : null;
  const current = (v: number | null, t: Date | null) => v != null && v > 0 && t != null && (!session || +t >= +session);
  const ac = num('ACChargingPower',{kW:1}), dc = num('DCChargingPower',{kW:1}), acAt = at('ACChargingPower'), dcAt = at('DCChargingPower');
  const fast = bool('FastChargerPresent') ?? (current(dc, dcAt) && (!current(ac, acAt) || +dcAt! >= +acAt!));
  const counter = fast ? 'DCChargingEnergyIn' : 'ACChargingEnergyIn', counted = at(counter);
  const eta = num('TimeToFullCharge',{h:60}), etaAt = at('TimeToFullCharge');
  const fields = ['DetailedChargeState', fast ? 'DCChargingPower' : 'ACChargingPower', 'TimeToFullCharge', counter, 'ChargeAmps', 'ChargerVoltage'];
  const charge = { state, at: at('DetailedChargeState'), powerKw: fast ? dc : ac, fast, minutesToFull: eta,
    // When the car expects to be full, anchored to the estimate's own observation.
    readyAt: eta != null && etaAt ? new Date(+etaAt + eta * 60_000) : null,
    observedAt: fields.map(at).filter(t => t != null).sort((a,b) => +b-+a)[0] ?? null,
    currentA: num('ChargeAmps',{A:1}), voltage: num('ChargerVoltage',{V:1}), cableType: text('ChargingCableType'), startedAt: session,
    energyAddedKwh: session && counted && +counted >= +session ? num(counter,{kWh:1}) : null };
  const tire = (suffix: string) => ({ pressureBar: num(`TpmsPressure${suffix}`, {bar:1,psi:1/14.5037738,kPa:.01}), updatedAt: times[`TpmsPressure${suffix}`] ?? null });
  return { values: {
    batteryLevel:num('BatteryLevel',{'%':1}), usableBatteryLevel:num('Soc',{'%':1}),
    ratedRangeKm:num('RatedRange',{mi:1.609344,km:1}),estRangeKm:num('EstBatteryRange',{mi:1.609344,km:1}),chargeLimit:num('ChargeLimitSoc',{'%':1}),
    packTempMaxC:num('ModuleTempMax',{C:1}),packTempMinC:num('ModuleTempMin',{C:1}), locked:bool('Locked'),sentryMode,
    chargePortDoorOpen:bool('ChargePortDoorOpen'),chargePortLatch:text('ChargePortLatch'),
    insideTempC:num('InsideTemp',{C:1}),outsideTempC:num('OutsideTemp',{C:1}),firmware:text('Version'),
    odometerKm:num('Odometer',{mi:1.609344,km:1}),energyRemainingKwh:num('EnergyRemaining',{kWh:1}),
  }, tpms:{fl:tire('Fl'),fr:tire('Fr'),rl:tire('Rl'),rr:tire('Rr')},
  freshness:{connected,lastSeenAt,recordedAt:times}, charge, by };
}
