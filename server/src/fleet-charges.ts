import { createHash } from 'node:crypto';
import type { DB, Row } from './db';
import { coverageGap, lossGap, lostBetween, realGaps, type Span } from './fleet-gaps';
import { telemetryDriveId, telemetryDriveVehicle } from './fleet-drives';

/** Same collision-free encoding as drives; charge and drive IDs are separate
 * namespaces (distinct routes). Keyed by the RAW session start so the ID and
 * cursor stay stable while the displayed start is trimmed to power. */
export const telemetryChargeId = telemetryDriveId;
export const telemetryChargeVehicle = telemetryDriveVehicle;
export type ChargeWindow = { id: number; start: Date; end: Date; _cursorStart: string; nextDrive: Date | null };
export type ChargeCatalog = { windows: ChargeWindow[]; gaps: Span[]; start: Date | null; end: Date | null };

const margin = 300000, finite = (n: any): n is number => typeof n === 'number' && Number.isFinite(n);
const invalid = (s: Row, field: string) => Array.isArray(s.invalid_fields) && s.invalid_fields.includes(field);
/** Fleet Telemetry is change-only: AC/DC input power hold until the next
 * report; an invalid report makes that field unknown. DC wins, then AC. */
export function chargePowers(samples: Row[]) {
  let dc: number | null = null, ac: number | null = null;
  return samples.map(s => {
    if (invalid(s,'DCChargingPower')) dc = null; else if (finite(s.dc_power_kw)) dc = s.dc_power_kw;
    if (invalid(s,'ACChargingPower')) ac = null; else if (finite(s.ac_power_kw)) ac = s.ac_power_kw;
    const reported = finite(s.dc_power_kw) || finite(s.ac_power_kw) || invalid(s,'DCChargingPower') || invalid(s,'ACChargingPower');
    const p = dc !== null && dc > 0 ? dc : ac !== null && ac > 0 ? ac : dc === 0 || ac === 0 ? 0 : null;
    return {t:new Date(s.t), p, dc: dc !== null && dc > 0, reported, held:{dc,ac}};
  });
}
/** Derive one session from samples spanning [start-5min, min(end+5min, next drive)].
 * Start: first reported power>0 in the session. End: first explicitly
 * non-positive power of the charging source (DC or AC) after the last reported
 * positive power, else the session end; never past the next drive. Unknown
 * power is never a stop: it leaves `_uncertain` set and no integrated energy.
 * Null when power never rose (nothing measurable charged). */
export function deriveCharge(w: { start: Date; end: Date; nextDrive?: Date | null }, rows: Row[], gaps: Span[] = []): Row | null {
  const samples = [...rows].sort((a,b) => +new Date(a.t)-+new Date(b.t)), powers = chargePowers(samples), lost = realGaps(gaps);
  const limit = Math.min(+w.end, w.nextDrive ? +w.nextDrive : Infinity), first = powers.findIndex(p => p.reported && p.p !== null && p.p > 0 && +p.t >= +w.start && +p.t <= limit);
  if (first < 0) return null;
  let last = first;
  for (let i = first; i < powers.length && +powers[i]!.t <= limit; i++) if (powers[i]!.reported && powers[i]!.p! > 0) last = i;
  // The charging source's own reading decides: AC holding 0 says nothing about unknown DC.
  const source = powers[last]!.dc ? 'dc' : 'ac', power = (p: typeof powers[number]) => p.p !== null && p.p > 0 ? p.p : p.held[source] === null ? null : 0;
  const stop = powers.findIndex((p,i) => i > last && +p.t <= limit && power(p) === 0);
  const start = powers[first]!.t, end = new Date(stop >= 0 ? +powers[stop]!.t : limit);
  const uncertain = powers.some((p,i) => i > last && +p.t <= +end && (stop < 0 || i < stop) && power(p) === null);
  // Slow change-only signals hold until the next observation, but never across
  // an invalid observation of that field or real loss. At the end prefer the
  // first report within 5 min after (SoC lags the stop), at the start the held value.
  const pick = (key: string, field: string, at: Date, after: boolean) => {
    const seen = samples.filter(s => (finite(s[key]) || invalid(s,field)) && (!w.nextDrive || +new Date(s.t) < +w.nextDrive));
    const held = seen.filter(s => +new Date(s.t) <= +at).at(-1), next = seen.find(s => +new Date(s.t) >= +at);
    const ok = (s: Row | undefined, near: boolean) => s && finite(s[key]) && (!near || +new Date(s.t)-+at <= margin)
      && !lostBetween(lost,new Date(Math.min(+new Date(s.t),+at)),new Date(Math.max(+new Date(s.t),+at))) ? s[key] as number : null;
    return after ? ok(next,true) ?? ok(held,false) : ok(held,false) ?? ok(next,true);
  };
  const level = (n: number | null) => n === null ? null : Math.round(n);
  const kwhStart = pick('energy_remaining_kwh','EnergyRemaining',start,false), kwhEnd = pick('energy_remaining_kwh','EnergyRemaining',end,true);
  const delta = kwhStart !== null && kwhEnd !== null ? kwhEnd-kwhStart : null;
  // Held-step integration over [start,end]: max, energy-weighted mean, and a
  // fallback energy only when no power interval is unknown or lost.
  let energy = 0, weighted = 0, unknown = false, max: number | null = null, fast = false;
  for (let i = 0; i < powers.length; i++) {
    const p = powers[i]!, t = +p.t, next = Math.min(+end, i+1 < powers.length ? +powers[i+1]!.t : +end);
    if (t > +end) break;
    if (t >= +start && p.p !== null && p.reported) { max = Math.max(max ?? 0, p.p); fast ||= p.dc; }
    const from = Math.max(t,+start), dt = (next-from)/3600000, kw = power(p);
    if (dt <= 0) continue;
    if (kw === null) { unknown = true; continue; }
    energy += kw*dt; weighted += kw*kw*dt;
  }
  const integrated = !unknown && !lostBetween(lost,start,end) && energy > 0 ? energy : null;
  // Held (time-weighted) outside temperature, seeded by the reading at start.
  const known = samples.filter(s => finite(s.outside_temp_c) && +new Date(s.t) <= +end), seed = known.filter(s => +new Date(s.t) <= +start).at(-1);
  const temps = [...(seed ? [seed] : []),...known.filter(s => +new Date(s.t) > +start)];
  let tempSum = 0, tempTime = 0;
  temps.forEach((s,i) => { const dt = Math.min(+end,i+1 < temps.length ? +new Date(temps[i+1]!.t) : +end)-Math.max(+start,+new Date(s.t)); if (dt > 0) { tempSum += s.outside_temp_c*dt; tempTime += dt; } });
  const gps = samples.filter(s => finite(s.latitude) && finite(s.longitude) && +new Date(s.t) <= +end).at(-1);
  return {start,end,startBatteryLevel:level(pick('battery_level','BatteryLevel',start,false)),endBatteryLevel:level(pick('battery_level','BatteryLevel',end,true)),
    energyAddedKwh:delta !== null && delta > 0 ? delta : integrated,maxPowerKw:max,avgPowerKw:energy > 0 ? weighted/energy : null,fastCharger:fast,
    outsideTempAvgC:tempTime > 0 ? tempSum/tempTime : temps.length ? temps.at(-1)!.outside_temp_c : null,
    latitude:gps?.latitude ?? null,longitude:gps?.longitude ?? null,durationMin:(+end-+start)/60000,_uncertain:uncertain};
}
/** A TeslaMate process is replaced by an overlapping measured telemetry
 * charge; otherwise only when telemetry fully covered it with no lost data or
 * unknown charge state (telemetry saw no charging there). */
export function coveredCharge(row: Row, catalog: ChargeCatalog) {
  const start = +new Date(row.start), end = row.end ? +new Date(row.end) : Infinity;
  return catalog.start !== null && catalog.end !== null && start >= +catalog.start && end <= +catalog.end
    && !catalog.gaps.some(g => (lossGap(g) || !coverageGap(g)) && +g.start < end && +g.end > start);
}
const bounds = (r: Row) => [+new Date(r.start), r.end ? +new Date(r.end) : Infinity] as const;
const hits = (w: { start: Date; end: Date }, r: Row) => +w.start < bounds(r)[1] && +w.end > bounds(r)[0];
/** One overlap group (raw telemetry windows and TeslaMate processes linked by
 * overlap). Telemetry replaces the group's TeslaMate processes only when every
 * measured row has measurable energy, a certain stop and no real loss, and no
 * real loss falls inside any process's telemetry-covered span; otherwise the
 * overlapping partial telemetry is dropped and TeslaMate stays. Each replaced
 * receipt counts once: on the shown row with the largest measured overlap
 * (then more energy, then earlier). Row cost = its receipts' sum, null when it
 * has none or any is unpriced; `_priced` = every receipt overlapping it is
 * priced (a sibling may carry them), so totals stay exact. */
export function resolveCharges(group: { window: ChargeWindow; row: Row | null }[], legacy: Row[], gaps: Span[]) {
  const measured = group.filter((g): g is { window: ChargeWindow; row: Row } => g.row !== null);
  const trusted = measured.every(({row}) => row.energyAddedKwh !== null && !row._uncertain && !lostBetween(gaps,new Date(row.start),new Date(row.end)))
    && legacy.every(p => {
      const ws = group.filter(g => hits(g.window,p)).map(g => g.window);
      if (!ws.length) return true;
      const from = Math.max(bounds(p)[0],...ws.map(w => +w.start)), to = Math.min(bounds(p)[1],...ws.map(w => +w.end));
      return !lostBetween(gaps,new Date(from),new Date(to));
    });
  const replaced = new Set(trusted ? legacy.filter(p => measured.some(g => hits(g.window,p))).map(p => p.id as number) : []);
  const shown = new Map(measured.filter(g => trusted || !legacy.some(p => hits(g.window,p))).map(g => [g.window.id,{...g.row,cost:null,_priced:false} as Row]));
  const priced = (p: Row) => p.cost !== null && p.cost !== undefined, receipts = new Map<number,Row[]>();
  for (const p of legacy.filter(p => replaced.has(p.id))) {
    const overlap = (r: Row) => Math.max(0,Math.min(bounds(p)[1],+new Date(r.end))-Math.max(bounds(p)[0],+new Date(r.start)));
    const owner = measured.filter(g => shown.has(g.window.id) && hits(g.window,p)).map(g => shown.get(g.window.id)!)
      .sort((a,b) => overlap(b)-overlap(a) || (b.energyAddedKwh ?? 0)-(a.energyAddedKwh ?? 0) || +new Date(a.start)-+new Date(b.start))[0];
    if (owner) receipts.set(owner.id,[...(receipts.get(owner.id) ?? []),p]);
  }
  for (const [id,row] of shown) {
    const own = receipts.get(id) ?? [], all = legacy.filter(p => replaced.has(p.id) && hits(group.find(g => g.window.id === id)!.window,p));
    row.cost = own.length && own.every(priced) ? Number(own.reduce((sum,p) => sum+Number(p.cost),0).toFixed(9)) : null;
    row._priced = all.length > 0 && all.every(priced);
  }
  return {shown,replaced};
}
/** Resolve the complete overlap group of any seed (window or process) once;
 * groups never depend on the requested page or date range. */
export function chargeGroups(catalog: ChargeCatalog, legacy: Row[], hydrate: (w: ChargeWindow) => Promise<Row | null>) {
  const done = new Map<number,Promise<ReturnType<typeof resolveCharges>>>();
  return (seed: Row) => {
    if (done.has(seed.id)) return done.get(seed.id)!;
    const windows = new Map<number,ChargeWindow>(), tm = new Map<number,Row>(), pending: Row[] = [seed];
    for (let i = 0; i < pending.length; i++) {
      const r = pending[i]!;
      if (r.id < 0) { if (windows.has(r.id)) continue; windows.set(r.id,r as ChargeWindow); pending.push(...legacy.filter(p => hits(r as ChargeWindow,p))); }
      else { if (tm.has(r.id)) continue; tm.set(r.id,r); pending.push(...catalog.windows.filter(w => hits(w,r))); }
    }
    const group = [...windows.values()].sort((a,b) => +a.start-+b.start || a.id-b.id);
    const result = Promise.all(group.map(hydrate)).then(rows => resolveCharges(group.map((window,i) => ({window,row:rows[i]!})),[...tm.values()],catalog.gaps));
    for (const id of [...windows.keys(),...tm.keys()]) done.set(id,result);
    return result;
  };
}
export class FleetCharges {
  constructor(private sql: DB) {}
  async catalog(id: number): Promise<ChargeCatalog | null> {
    const [binding]=await this.sql`SELECT b.vin_digest,c.vin FROM volta_telemetry.api_vehicle_bindings b JOIN public.cars c ON c.id=b.vehicle_id WHERE b.vehicle_id=${id}`;
    if (!binding?.vin || binding.vin_digest!==createHash('sha256').update('volta-telemetry-vin-binding-v1\0').update(binding.vin).digest('hex')) return null;
    const [sessions,gaps,bounds]=await Promise.all([
      this.sql`SELECT c.start_ts AS start,c.end_ts AS end,to_char(c.start_ts AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS "_cursorStart",
        (SELECT d.start_ts FROM volta_telemetry.sessions d WHERE d.vehicle_id=c.vehicle_id AND d.kind='drive' AND d.start_ts>=c.start_ts ORDER BY d.start_ts LIMIT 1) AS "nextDrive"
        FROM volta_telemetry.sessions c WHERE c.vehicle_id=${id} AND c.kind='charge' ORDER BY c.start_ts`,
      this.sql`SELECT start_ts AS start,end_ts AS end,reason FROM volta_telemetry.gaps WHERE vehicle_id=${id} AND (reason NOT IN ('disconnected','silence') OR end_ts-start_ts>=interval '90 seconds') ORDER BY start_ts`,
      this.sql`SELECT
        (SELECT source_ts FROM volta_telemetry.connectivity WHERE vehicle_id=${id} AND status='CONNECTED' ORDER BY source_ts LIMIT 1) AS connected,
        (SELECT max(source_ts) FROM volta_telemetry.latest_samples WHERE vehicle_id=${id}) AS latest,
        (SELECT min(start_ts) FROM volta_telemetry.sessions WHERE vehicle_id=${id}) AS first,(SELECT max(end_ts) FROM volta_telemetry.sessions WHERE vehicle_id=${id}) AS last`
    ]);
    const starts=[bounds[0]?.first,bounds[0]?.connected].filter(Boolean).map(t=>new Date(t));
    const ends=[bounds[0]?.last,bounds[0]?.latest].filter(Boolean).map(t=>new Date(t));
    return {windows:sessions.map(s=>({id:telemetryChargeId(id,new Date(s.start)),start:new Date(s.start),end:new Date(s.end),_cursorStart:s._cursorStart,nextDrive:s.nextDrive ? new Date(s.nextDrive) : null})),
      gaps:realGaps(gaps),start:starts.length ? starts.reduce((a,b)=>+a<+b?a:b) : null,end:ends.length ? ends.reduce((a,b)=>+a>+b?a:b) : null};
  }
  private samples(vehicle: number, w: ChargeWindow) {
    const to = Math.min(+w.end+margin, w.nextDrive ? +w.nextDrive : Infinity);
    return this.sql`SELECT source_ts AS t,latitude,longitude,battery_level,energy_remaining_kwh,outside_temp_c,voltage,current_a,rated_range_km,ac_power_kw,dc_power_kw,invalid_fields
      FROM volta_telemetry.session_samples WHERE vehicle_id=${vehicle} AND source_ts>=${new Date(+w.start-margin)} AND source_ts<=${new Date(to)} ORDER BY source_ts`;
  }
  /** Measured summary (null when no power). `legacy` = TeslaMate processes
   * (id,start,end,cost,latitude,longitude) for a location fallback; cost is
   * reconciled per overlap group by resolveCharges. */
  async row(vehicle: number, w: ChargeWindow, gaps: Span[], legacy: Row[], currency: string | null, withSamples = false) {
    const samples = await this.samples(vehicle,w), derived = deriveCharge(w,samples,gaps);
    if (!derived) return null;
    const overlap = legacy.filter(r => +new Date(r.start) < +derived.end && (!r.end || +new Date(r.end) > +derived.start));
    if (derived.latitude === null) {
      // Change-only GPS: a parked charge reports no Location; use the last
      // fix (12 h bound keeps the pivot scan small), else TeslaMate's.
      const [fix] = await this.sql`SELECT latitude,longitude FROM volta_telemetry.payload_points WHERE vehicle_id=${vehicle}
        AND source_ts<=${derived.end} AND source_ts>=${derived.end}::timestamptz-interval '12 hours' AND latitude IS NOT NULL ORDER BY source_ts DESC LIMIT 1`;
      const tm = overlap.find(r => finite(r.latitude) && finite(r.longitude));
      if (fix) { derived.latitude = fix.latitude; derived.longitude = fix.longitude; }
      else if (tm) { derived.latitude = tm.latitude; derived.longitude = tm.longitude; }
    }
    // TeslaMate's own geofence/address tables; never an external geocoder.
    const [place] = derived.latitude === null ? [] : await this.sql`WITH here AS (SELECT ${derived.latitude}::double precision AS lat,${derived.longitude}::double precision AS lon)
      SELECT (SELECT g.name FROM public.geofences g WHERE 6371000*2*asin(least(1.0,sqrt(power(sin(radians((g.latitude-lat)/2)),2)
          +cos(radians(lat))*cos(radians(g.latitude))*power(sin(radians((g.longitude-lon)/2)),2))))<=g.radius ORDER BY g.radius,g.id LIMIT 1) AS "placeName",
        a.display_name AS address,COALESCE(NULLIF(a.city,''),NULLIF(a.neighbourhood,''),NULLIF(a.name,'')) AS city,
        CASE WHEN NULLIF(a.road,'') IS NULL THEN NULL ELSE concat_ws(' ',NULLIF(a.house_number,''),a.road) END AS street
      FROM here LEFT JOIN LATERAL (SELECT a.*,6371000*2*asin(least(1.0,sqrt(power(sin(radians((a.latitude-lat)/2)),2)
          +cos(radians(lat))*cos(radians(a.latitude))*power(sin(radians((a.longitude-lon)/2)),2)))) AS m
        FROM public.addresses a WHERE a.latitude BETWEEN lat-.002 AND lat+.002 AND a.longitude BETWEEN lon-.003 AND lon+.003 ORDER BY m,a.id LIMIT 1) a ON a.m<=150`;
    const row: Row = {id:w.id,_cursorStart:w._cursorStart,start:derived.start,end:derived.end,address:place?.address ?? null,placeName:place?.placeName ?? null,
      energyAddedKwh:derived.energyAddedKwh,energyUsedKwh:null,startBatteryLevel:derived.startBatteryLevel,endBatteryLevel:derived.endBatteryLevel,
      latitude:derived.latitude,longitude:derived.longitude,durationMin:derived.durationMin,maxPowerKw:derived.maxPowerKw,fastCharger:derived.fastCharger,
      cost:null,currency,outsideTempAvgC:derived.outsideTempAvgC,
      source:'fleet_telemetry',avgPowerKw:derived.avgPowerKw,city:place?.city ?? null,street:place?.street ?? null,energyFromGridKwh:null,_uncertain:derived._uncertain};
    if (withSamples) {
      const powers = chargePowers(samples), inside = samples.map((s,i) => ({s,p:powers[i]!})).filter(({s}) => +new Date(s.t) >= +derived.start && +new Date(s.t) <= +derived.end
        && [s.battery_level,s.voltage,s.current_a,s.rated_range_km,s.ac_power_kw,s.dc_power_kw].some(finite));
      const step = Math.max(1,Math.ceil(inside.length/1999)), kept = inside.filter((_,i) => i%step===0);
      if (inside.length && kept.at(-1) !== inside.at(-1)) kept.push(inside.at(-1)!);
      row.samples = kept.map(({s,p}) => ({t:new Date(s.t),
        batteryLevel:finite(s.battery_level) ? Math.round(s.battery_level) : null,powerKw:p.p,voltage:s.voltage ?? null,currentA:s.current_a ?? null,ratedRangeKm:s.rated_range_km ?? null}));
    }
    return row;
  }
}
