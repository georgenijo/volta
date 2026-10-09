import { createHash } from 'node:crypto';
import type { DB, Row } from './db';

export const liveFields = ['BatteryLevel','Soc','RatedRange','EstBatteryRange','ChargeLimitSoc','ModuleTempMax','ModuleTempMin','Locked','SentryMode','TpmsPressureFl','TpmsPressureFr','TpmsPressureRl','TpmsPressureRr','ChargePortDoorOpen','ChargePortLatch','InsideTemp','OutsideTemp','Version','Odometer','EnergyRemaining'];

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
      (SELECT to_jsonb(h) FROM volta_telemetry.stream_health h WHERE id=1) AS health
      FROM volta_telemetry.api_vehicle_bindings b JOIN public.cars c ON c.id=b.vehicle_id WHERE b.vehicle_id=${id}`;
    if (!row?.vin || !/^[A-HJ-NPR-Z0-9]{17}$/.test(row.vin)) return null;
    const digest = createHash('sha256').update('volta-telemetry-vin-binding-v1\0').update(row.vin, 'utf8').digest('hex');
    if (row.vin_digest !== digest) return null;
    return { samples: row.samples as Row[], connections: (row.connections ?? []) as Row[], health: row.health as Row | null };
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
  const tire = (suffix: string) => ({ pressureBar: num(`TpmsPressure${suffix}`, {bar:1,psi:1/14.5037738,kPa:.01}), updatedAt: times[`TpmsPressure${suffix}`] ?? null });
  return { values: {
    batteryLevel:num('BatteryLevel',{'%':1}), usableBatteryLevel:num('Soc',{'%':1}),
    ratedRangeKm:num('RatedRange',{mi:1.609344,km:1}),estRangeKm:num('EstBatteryRange',{mi:1.609344,km:1}),chargeLimit:num('ChargeLimitSoc',{'%':1}),
    packTempMaxC:num('ModuleTempMax',{C:1}),packTempMinC:num('ModuleTempMin',{C:1}), locked:bool('Locked'),sentryMode,
    chargePortDoorOpen:bool('ChargePortDoorOpen'),chargePortLatch:text('ChargePortLatch'),
    insideTempC:num('InsideTemp',{C:1}),outsideTempC:num('OutsideTemp',{C:1}),firmware:text('Version'),
    odometerKm:num('Odometer',{mi:1.609344,km:1}),energyRemainingKwh:num('EnergyRemaining',{kWh:1}),
  }, tpms:{fl:tire('Fl'),fr:tire('Fr'),rl:tire('Rl'),rr:tire('Rr')},
  freshness:{connected,lastSeenAt,recordedAt:times}, by };
}
