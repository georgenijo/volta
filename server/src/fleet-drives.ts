import { createHash } from 'node:crypto';
import type { DB, Row } from './db';
import { endpointEnergy, driveStyleScore } from './drive-parity';

const idBase = 2097152;
export type Window = { id: number; start: Date; end: Date; _cursorStart: string; endReason: string; startReason?: string; membership?: string; parts?: {start: Date; end: Date}[] };
export type Gap = { start: Date; end: Date; reason: string };
export type Catalog = { windows: Window[]; gaps: Gap[]; start: Date | null; end: Date | null };

/** Collision-free signed JS/Swift integer: 32-bit epoch seconds, 21-bit car ID.
 * Distinct trips are >=180s apart. Valid through 2106; never hash/truncate IDs. */
export function telemetryDriveId(vehicle: number, start: Date) {
  const seconds = Math.floor(+start / 1000);
  if (!Number.isInteger(vehicle) || vehicle <= 0 || vehicle >= idBase || seconds < 0 || seconds > 4294967295) throw new Error('Telemetry drive identity out of range');
  return -(seconds * idBase + vehicle);
}
export function telemetryDriveVehicle(id: number) { return Number.isSafeInteger(id) && id < 0 ? -id % idBase : 0; }
export function mergeSessions(vehicle: number, sessions: Row[], gaps: Gap[]): Window[] {
  const out: Window[] = [];
  for (const s of sessions) {
    const start = new Date(s.start), end = new Date(s.end), previous = out.at(-1);
    // Only an observed Park stop may join trips. Disconnect/silence/invalid
    // gear never proves the driver stayed parked or resumed the same trip.
    if (previous && previous.endReason === 'gear' && s.startReason === 'gear' && +start - +previous.end < 180000
      && +start >= +previous.end && !gaps.some(g => +g.start < +start && +g.end > +previous.end && g.reason !== 'charge_invalid')) {
      previous.end = end; previous.endReason = s.endReason; if (s.membership==='partial') previous.membership='partial'; previous.parts!.push({start,end});
    } else out.push({id:telemetryDriveId(vehicle,start),start,end,_cursorStart:s._cursorStart ?? start.toISOString(),endReason:s.endReason,startReason:s.startReason,membership:s.membership,parts:[{start,end}]});
  }
  return out;
}
/** Windows are ordered and nonoverlapping; seek the first possible overlap. */
export function overlappingWindows(row: Row, windows: Window[]) {
  const start=+new Date(row.start),end=row.end ? +new Date(row.end) : Infinity;
  let lo=0,hi=windows.length;
  while (lo<hi) {const mid=(lo+hi)>>>1;if (+windows[mid]!.end<=start) lo=mid+1;else hi=mid;}
  const out: Window[]=[];
  for (let i=lo;i<windows.length && +windows[i]!.start<end;i++) out.push(windows[i]!);
  return out;
}
/** A partial reconnection may not truncate a better observed TeslaMate trip.
 * A telemetry trip that starts BEFORE TM's late/wrong segment still wins. */
export function preferTeslaMate(row: Row, w: Window) {
  return ((w.startReason==='first_observed' || w.startReason==='speed') && +new Date(row.start)<+w.start-120000)
    || ((w.endReason==='gap' || w.endReason==='open') && row.end && +new Date(row.end)>+w.end+120000);
}
export function replacedDrive(row: Row, catalog: Catalog) {
  const start = +new Date(row.start), end = row.end ? +new Date(row.end) : Infinity;
  const overlaps=overlappingWindows(row,catalog.windows);
  if (overlaps.length) return overlaps.some(w=>!preferTeslaMate(row,w));
  return catalog.start !== null && catalog.end !== null && start >= +catalog.start && end <= +catalog.end
    && !catalog.gaps.some(g => g.reason !== 'charge_invalid' && +g.start < end && +g.end > start);
}
/** Resolve a connected overlap group. Edges point from the preferred source
 * to the row it replaces. Select unopposed rows, remove only their losers,
 * and repeat. For a preference cycle Fleet wins the oldest remaining window,
 * giving the same result regardless of the requested date/cursor/page. */
export function resolveDriveSources(legacy: Row[], windows: Window[], measured: Set<number>, catalog: Catalog) {
  const remaining=new Set<number>(),incoming=new Map<number,number[]>(),outgoing=new Map<number,number[]>(),selected=new Set<number>();
  for (const w of windows) if (measured.has(w.id)) remaining.add(w.id);
  for (const row of legacy) {
    const overlaps=overlappingWindows(row,windows);
    if (!overlaps.length && replacedDrive(row,catalog)) continue;
    remaining.add(row.id);
    for (const w of overlaps) if (measured.has(w.id)) {
      const [winner,loser]=preferTeslaMate(row,w) ? [row.id,w.id] : [w.id,row.id];
      incoming.set(loser,[...(incoming.get(loser) ?? []),winner]);outgoing.set(winner,[...(outgoing.get(winner) ?? []),loser]);
    }
  }
  while (remaining.size) {
    let winners=[...remaining].filter(id=>!(incoming.get(id) ?? []).some(other=>remaining.has(other)));
    if (!winners.length) winners=[windows.find(w=>remaining.has(w.id))!.id];
    const removed=new Set<number>();
    for (const winner of winners) {selected.add(winner);removed.add(winner);for (const loser of outgoing.get(winner) ?? []) removed.add(loser);}
    for (const id of removed) remaining.delete(id);
  }
  return selected;
}
export function haversine(a: Row, b: Row) {
  const r = Math.PI / 180, dlat = (b.latitude-a.latitude)*r, dlon = (b.longitude-a.longitude)*r;
  return 6371*2*Math.asin(Math.min(1,Math.sqrt(Math.sin(dlat/2)**2+Math.cos(a.latitude*r)*Math.cos(b.latitude*r)*Math.sin(dlon/2)**2)));
}
const finite = (n: any): n is number => typeof n === 'number' && Number.isFinite(n);
const gps = (p: Row) => finite(p.latitude) && finite(p.longitude) && Math.abs(p.latitude)<=90 && Math.abs(p.longitude)<=180;
/** Bound previews and detail series while carrying every skipped route break. */
export function thin(points: Row[], limit: number): Row[] {
  if (points.length <= limit) return points;
  const out: Row[] = []; let previous = -1;
  for (let i=0;i<limit;i++) {
    const index = Math.round(i*(points.length-1)/(limit-1));
    out.push({...points[index],routeBreakBefore:points.slice(previous+1,index+1).some(p => p.routeBreakBefore)});
    previous=index;
  }
  return out;
}
export function deriveDrive(window: Window, locations: Row[], payloads: Row[], samples: Row[], rated: number | null, gaps: Gap[]): Row {
  gaps=gaps.filter(g=>+g.start<=+window.end && +g.end>=+window.start);
  const path = locations.filter(gps).map(p => ({t:new Date(p.source_ts),latitude:p.latitude,longitude:p.longitude,
    speedKph:p.speed_kph,powerKw:p.power_kw,batteryLevel:finite(p.battery_level_pct) ? Math.round(p.battery_level_pct) : finite(p.soc_pct) ? Math.round(p.soc_pct) : null,socPct:p.soc_pct,elevationM:null,routeBreakBefore:!!p.route_break_before}));
  for (let i=1;i<path.length;i++) path[i]!.routeBreakBefore ||= +path[i]!.t-+path[i-1]!.t>120000
    || gaps.some(g => g.reason !== 'charge_invalid' && +g.start < +path[i]!.t && +g.end > +path[i-1]!.t);
  const odometers = payloads.filter(p => finite(p.odometer_km));
  const first = odometers[0], last = odometers.at(-1);
  const interrupted = gaps.some(g => g.reason !== 'charge_invalid' && +g.start < +window.end && +g.end > +window.start);
  const observed=window.startReason==='gear' && window.endReason==='gear' && window.membership !== 'partial' && !interrupted;
  const validDelta = first && last && first !== last && (observed || (+new Date(first.source_ts)-+window.start<=120000
    && +window.end-+new Date(last.source_ts)<=120000)) && odometers.every((p,i) => !i || p.odometer_km >= odometers[i-1]!.odometer_km);
  let distance = validDelta ? last!.odometer_km-first!.odometer_km : null;
  if (distance === null && path.length>=2 && !interrupted && (observed || (!path.some((p,i) => i>0 && p.routeBreakBefore)
    && +path[0]!.t-+window.start<=120000 && +window.end-+path.at(-1)!.t<=120000))) distance=path.slice(1).reduce((sum,p,i) => sum+haversine(path[i]!,p),0);
  // A merged Park stop is known stationary time, not a missing route span.
  // When no odometer brackets the whole trip, measure each moving session
  // independently; never connect GPS across the intervening parked interval.
  if (distance === null && window.parts && window.parts.length>1) {
    const deltas: (number | null)[]=window.parts.map(part=> {
      const inside=(rows: Row[])=>rows.filter(p=>+new Date(p.source_ts)>=+part.start && +new Date(p.source_ts)<=+part.end);
      return deriveDrive({...window,...part,parts:undefined},inside(locations),inside(payloads),inside(samples),rated,gaps).distanceKm;
    });
    if (deltas.every(d=>d !== null)) distance=deltas.reduce((sum,d)=>sum+d!,0);
  }
  let energy: number | null = null, energySource: string | null = null;
  if (!interrupted) {
    const remaining = samples.filter(p => finite(p.energy_remaining_kwh)).map(p => ({t:new Date(p.source_ts),value:p.energy_remaining_kwh}));
    if (!samples.some(p => p.invalid_fields?.includes('EnergyRemaining'))) energy=endpointEnergy(remaining[0],remaining.at(-1),window.start,window.end);
    if (energy !== null) energySource='fleet_energy_remaining';
    // Integrate calibrated signed pack power only over continuous observations.
    const powers=samples.filter(p => finite(p.power_kw));
    if (energy === null && powers.length>1 && !samples.some(p => p.invalid_fields?.some((f:string) => ['PackVoltage','PackCurrent'].includes(f)))
      && +new Date(powers[0]!.source_ts)-+window.start<=120000 && +window.end-+new Date(powers.at(-1)!.source_ts)<=120000
      && powers.every((p,i) => !i || +new Date(p.source_ts)-+new Date(powers[i-1]!.source_ts)<=30000)) {
      const net=powers.slice(1).reduce((sum,p,i) => sum+(p.power_kw+powers[i]!.power_kw)/2*(+new Date(p.source_ts)-+new Date(powers[i]!.source_ts))/3600000,0);
      if (net>0) { energy=net; energySource='fleet_pack_power'; }
    }
  }
  const duration=(+window.end-+window.start)/60000, speeds=samples.filter(p => finite(p.speed_kph)).map(p => p.speed_kph);
  const batteries=payloads.filter(p => finite(p.battery_level_pct) || finite(p.soc_pct));
  const actual=energy !== null && distance !== null && distance>0 ? energy*1000/distance : null;
  const scorePoints=samples.map(p => ({t:new Date(p.source_ts),speedKph:p.speed_kph,longitudinalAccelerationMps2:p.longitudinal_acceleration_mps2,lateralAccelerationMps2:p.lateral_acceleration_mps2,
    routeBreakBefore:gaps.some(g=>g.reason !== 'charge_invalid' && +g.start<=+new Date(p.source_ts) && +g.end>=+new Date(p.source_ts))}));
  const socByTime=new Map(payloads.filter(p=>finite(p.soc_pct)).map(p=>[+new Date(p.source_ts),p.soc_pct]));
  const series=samples.map(p => ({t:new Date(p.source_ts),latitude:p.latitude,longitude:p.longitude,speedKph:p.speed_kph,
    powerKw:p.power_kw,batteryLevel:p.battery_level ?? socByTime.get(+new Date(p.source_ts)) ?? null,socPct:socByTime.get(+new Date(p.source_ts)) ?? null,energyRemainingKwh:p.energy_remaining_kwh,outsideTempC:p.outside_temp_c,
    longitudinalAccelerationMps2:p.longitudinal_acceleration_mps2,elevationM:null,routeBreakBefore:false,invalidFields:p.invalid_fields ?? []}));
  let previous: Row | null=null;
  for (const p of series) if (gps(p)) { p.routeBreakBefore=previous !== null && (+p.t-+previous.t>120000 || gaps.some(g => +g.start<+p.t && +g.end>+previous!.t && g.reason !== 'charge_invalid')); previous=p; }
  const temperatures=samples.filter(p => finite(p.outside_temp_c)).map(p => p.outside_temp_c);
  return {id:window.id,start:window.start,end:window.end,_cursorStart:window._cursorStart,source:'fleet_telemetry',
    startAddress:null,endAddress:null,startCity:null,endCity:null,
    startLatitude:path[0]?.latitude ?? null,startLongitude:path[0]?.longitude ?? null,endLatitude:path.at(-1)?.latitude ?? null,endLongitude:path.at(-1)?.longitude ?? null,ratedWhPerKm:rated,distanceKm:distance,durationMin:duration,
    startBatteryLevel:batteries.length ? Math.round(batteries[0]!.battery_level_pct ?? batteries[0]!.soc_pct) : null,
    endBatteryLevel:batteries.length ? Math.round(batteries.at(-1)!.battery_level_pct ?? batteries.at(-1)!.soc_pct) : null,
    energyUsedKwh:energy,energySource,efficiencyWhPerKm:actual,maxSpeedKph:speeds.length ? speeds.reduce((a,b)=>Math.max(a,b),0) : null,
    avgSpeedKph:distance !== null && duration>0 ? distance*60/duration : null,
    outsideTempAvgC:temperatures.length ? temperatures.reduce((a,b)=>a+b,0)/temperatures.length : null,
    ...driveStyleScore(actual,rated,scorePoints),electricityRatePerKwh:null,rateCurrency:null,
    route:thin(path.map(({speedKph,powerKw,batteryLevel,socPct,elevationM,...p})=>p),64),path:thin(path,2000),
    telemetry:{source:'fleet_telemetry',samples:thin(series,2000),gaps:gaps.filter(g=>+g.start<+window.end && +g.end>+window.start),
      coverage:seriesCoverage(series,thin(series,2000),window,gaps),downsampled:series.length>2000,truncated:false},elevationGainM:null};
}

/** Match the established detail-series contract; never infer coverage from the
 * downsampled points. Slow/invalid signals retain their own coverage metadata. */
function seriesCoverage(source: Row[], returned: Row[], window: Window, gaps: Gap[]) {
  const fields: Record<string,string>={speedKph:'VehicleSpeed',powerKw:'Power',batteryLevel:'BatteryLevel',energyRemainingKwh:'EnergyRemaining',
    outsideTempC:'OutsideTemp',longitudinalAccelerationMps2:'LongitudinalAcceleration'};
  const metrics: Row={};
  const maxInterval=(points: Row[])=>points.length>1 ? points.slice(1).reduce((max,p,i)=>Math.max(max,(+p.t-+points[i]!.t)/1000),0) : null;
  for (const [key,field] of Object.entries(fields)) {
    const points=source.filter(p=>finite(p[key])), selected=returned.filter(p=>finite(p[key]));
    if (!points.length) continue;
    const receiverGapCount=gaps.filter(g=>g.reason !== 'charge_invalid' && +g.start<+points.at(-1)!.t && +g.end>+points[0]!.t).length;
    let invalidGapCount=0, invalid=false;
    for (const p of source) { const bad=p.invalidFields.includes(field) || (key==='powerKw' && p.invalidFields.some((f:string)=>['PackVoltage','PackCurrent'].includes(f))); if (bad && !invalid) invalidGapCount++; if (bad || finite(p[key])) invalid=bad; }
    metrics[key]={start:points[0]!.t,end:points.at(-1)!.t,sourceSampleCount:points.length,returnedSampleCount:selected.length,
      densityPerMinute:+window.end>+window.start ? points.length*60000/(+window.end-+window.start) : null,
      maxIntervalSeconds:maxInterval(points),returnedMaxIntervalSeconds:maxInterval(selected),receiverGapCount,invalidGapCount,
      gapCount:receiverGapCount+invalidGapCount,downsampled:selected.length<points.length,truncated:returned.length<source.length && invalidGapCount>0};
  }
  return {sessionStart:window.start,sessionEnd:window.end,sampleStart:source[0]?.t ?? null,sampleEnd:source.at(-1)?.t ?? null,
    sourceSampleCount:source.length,returnedSampleCount:returned.length,metrics};
}

export class FleetDrives {
  constructor(private sql: DB) {}
  async catalog(id: number): Promise<Catalog | null> {
    const [binding]=await this.sql`SELECT b.vin_digest,c.vin FROM volta_telemetry.api_vehicle_bindings b JOIN public.cars c ON c.id=b.vehicle_id WHERE b.vehicle_id=${id}`;
    if (!binding?.vin || binding.vin_digest!==createHash('sha256').update('volta-telemetry-vin-binding-v1\0').update(binding.vin).digest('hex')) return null;
    const [sessions,gaps,bounds]=await Promise.all([
      this.sql`SELECT start_ts AS start,end_ts AS end,start_reason AS "startReason",end_reason AS "endReason",membership,
        to_char(start_ts AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS "_cursorStart"
        FROM volta_telemetry.sessions WHERE vehicle_id=${id} AND kind='drive' ORDER BY start_ts`,
      this.sql`SELECT start_ts AS start,end_ts AS end,reason FROM volta_telemetry.gaps WHERE vehicle_id=${id} ORDER BY start_ts`,
      this.sql`SELECT
        (SELECT source_ts FROM volta_telemetry.connectivity WHERE vehicle_id=${id} AND status='CONNECTED' ORDER BY source_ts LIMIT 1) AS connected,
        (SELECT max(source_ts) FROM volta_telemetry.latest_samples WHERE vehicle_id=${id}) AS latest`
    ]);
    const spans=gaps.map(g=>({start:new Date(g.start),end:new Date(g.end),reason:g.reason as string}));
    const starts=[sessions[0]?.start,bounds[0]?.connected].filter(Boolean).map(t=>new Date(t));
    const ends=[sessions.at(-1)?.end,bounds[0]?.latest].filter(Boolean).map(t=>new Date(t));
    return {windows:mergeSessions(id,sessions,spans),gaps:spans,
      start:starts.length ? starts.reduce((a,b)=>+a<+b?a:b) : null,end:ends.length ? ends.reduce((a,b)=>+a>+b?a:b) : null};
  }
  /** Mileage needs totals, not GPS/chart arrays. Aggregate dense route and
   * power observations in PostgreSQL; transfer only slow odometer/energy rows. */
  private async totals(vehicle: number,w: Window,gaps: Gap[]) {
    const parts=this.sql.json(w.parts ?? [{start:w.start,end:w.end}]);
    const [payloads,route,power]=await Promise.all([
      this.sql`SELECT * FROM volta_telemetry.payload_points WHERE vehicle_id=${vehicle} AND source_ts BETWEEN ${w.start} AND ${w.end}
        AND (odometer_km IS NOT NULL OR battery_level_pct IS NOT NULL OR soc_pct IS NOT NULL) ORDER BY source_ts`,
      this.sql`WITH p AS MATERIALIZED (
        SELECT source_ts,latitude,longitude,route_break_before,
          lag(source_ts) OVER t AS previous_ts,lag(latitude) OVER t AS previous_latitude,lag(longitude) OVER t AS previous_longitude
        FROM volta_telemetry.drive_points WHERE vehicle_id=${vehicle} AND source_ts BETWEEN ${w.start} AND ${w.end}
          AND latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180 WINDOW t AS (ORDER BY source_ts)
      ) SELECT min(source_ts) AS start,max(source_ts) AS finish,count(*) AS count,
        bool_and(previous_ts IS NULL OR (NOT route_break_before AND source_ts-previous_ts<=interval '120 seconds')
          OR EXISTS(SELECT 1 FROM jsonb_to_recordset(${parts}::jsonb) AS a(start timestamptz,"end" timestamptz)
            JOIN jsonb_to_recordset(${parts}::jsonb) AS b(start timestamptz,"end" timestamptz) ON a."end"<b.start
            WHERE previous_ts<=a."end" AND source_ts>=b.start AND source_ts-previous_ts>interval '120 seconds'
              AND b.start-a."end"<interval '180 seconds')) AS supported,
        sum(CASE WHEN previous_ts IS NOT NULL AND source_ts-previous_ts<=interval '120 seconds' THEN
          6371*2*asin(least(1.0,sqrt(power(sin(radians((latitude-previous_latitude)/2)),2)
          +cos(radians(previous_latitude))*cos(radians(latitude))*power(sin(radians((longitude-previous_longitude)/2)),2)))) ELSE 0 END) AS distance
        FROM p`,
      this.sql`WITH p AS MATERIALIZED (SELECT * FROM volta_telemetry.session_samples WHERE vehicle_id=${vehicle}
        AND source_ts BETWEEN ${w.start} AND ${w.end}), powers AS (
        SELECT source_ts,power_kw,lag(source_ts) OVER t AS previous_ts,lag(power_kw) OVER t AS previous_power
        FROM p WHERE power_kw IS NOT NULL WINDOW t AS (ORDER BY source_ts)
      ) SELECT (SELECT jsonb_agg(to_jsonb(p) ORDER BY source_ts) FROM p WHERE energy_remaining_kwh IS NOT NULL OR invalid_fields IS NOT NULL) AS samples,
        sum((power_kw+previous_power)/2*extract(epoch FROM source_ts-previous_ts)/3600) AS energy,
        count(*)>1 AND min(source_ts)>=${w.start}::timestamptz AND min(source_ts)<=${w.start}::timestamptz+interval '120 seconds'
          AND max(source_ts)>=${w.end}::timestamptz-interval '120 seconds'
          AND max(source_ts-previous_ts)<=interval '30 seconds'
          AND NOT EXISTS(SELECT 1 FROM p WHERE invalid_fields && ARRAY['PackVoltage','PackCurrent']) AS valid FROM powers`
    ]);
    const row=deriveDrive(w,[],payloads,power[0]?.samples ?? [],null,gaps),r=route[0];
    const interrupted=gaps.some(g=>g.reason !== 'charge_invalid' && +g.start<+w.end && +g.end>+w.start);
    if (row.distanceKm === null && w.parts && w.parts.length>1) {
      const partials=[];
      for (const part of w.parts) partials.push(await this.totals(vehicle,{...w,...part,parts:undefined},gaps.filter(g=>+g.start<=+part.end && +g.end>=+part.start)));
      if (partials.every(p=>p.distanceKm !== null)) row.distanceKm=partials.reduce((sum,p)=>sum+p.distanceKm,0);
    }
    if (row.distanceKm === null && !interrupted && r && Number(r.count)>1
      && ((w.startReason==='gear' && w.endReason==='gear' && w.membership !== 'partial')
        || (r?.supported && +new Date(r.start)-+w.start<=120000 && +w.end-+new Date(r.finish)<=120000))) row.distanceKm=r.distance;
    if (row.energyUsedKwh === null && !interrupted && power[0]?.valid && power[0]?.energy>0) {row.energyUsedKwh=power[0].energy;row.energySource='fleet_pack_power';}
    return row;
  }
  async rows(vehicle: number, windows: Window[], rated: number | null, gaps: Gap[], labels = true, totalsOnly = false): Promise<Row[]> {
    const rows: Row[]=[];
    // Seek only requested session windows, not the car's entire GPS history.
    for (const w of windows) {
      let row: Row;
      if (totalsOnly) row=await this.totals(vehicle,w,gaps.filter(g=>+g.start<=+w.end && +g.end>=+w.start));
      else {
      const [locations,payloads,samples]=await Promise.all([
        this.sql`SELECT * FROM volta_telemetry.drive_points WHERE vehicle_id=${vehicle} AND source_ts BETWEEN ${w.start} AND ${w.end} ORDER BY source_ts`,
        this.sql`SELECT * FROM volta_telemetry.payload_points WHERE vehicle_id=${vehicle} AND source_ts BETWEEN ${w.start} AND ${w.end} ORDER BY source_ts`,
        this.sql`SELECT * FROM volta_telemetry.session_samples WHERE vehicle_id=${vehicle} AND source_ts BETWEEN ${w.start} AND ${w.end} ORDER BY source_ts`
      ]);
      row=deriveDrive(w,locations,payloads,samples,rated,gaps);
      }
      // Isolated parking manoeuvres are noise; joined ones already belong to
      // their trip. Keep unknown distances unknown rather than inventing zero.
      row._omitReason=row.distanceKm === null ? 'unknown' : row.distanceKm<0.1609344 && row.durationMin<2 ? 'manoeuvre' : null;
      if (row._omitReason) {rows.push(row);continue;}
      const endpoints=[row.route[0],row.route.at(-1)];
      for (let i=0;labels && i<2;i++) {
        const p=endpoints[i]; if (!p) continue;
        const [label]=await this.sql`WITH nearby AS (
          SELECT name AS address,name AS city,0 AS priority,
            6371000*2*asin(least(1.0,sqrt(power(sin(radians((latitude-${p.latitude})/2)),2)+cos(radians(${p.latitude}))*cos(radians(latitude))*power(sin(radians((longitude-${p.longitude})/2)),2)))) AS meters,radius AS radius_m,id FROM public.geofences
          UNION ALL SELECT display_name,COALESCE(NULLIF(city,''),NULLIF(neighbourhood,''),NULLIF(name,'')),1,
            6371000*2*asin(least(1.0,sqrt(power(sin(radians((latitude-${p.latitude})/2)),2)+cos(radians(${p.latitude}))*cos(radians(latitude))*power(sin(radians((longitude-${p.longitude})/2)),2)))),150,id FROM public.addresses
        ) SELECT address,city FROM nearby WHERE meters<=radius_m ORDER BY priority,meters,id LIMIT 1`;
        row[i===0?'startAddress':'endAddress']=label?.address ?? null; row[i===0?'startCity':'endCity']=label?.city ?? null;
      }
      rows.push(row);
    }
    return rows;
  }
}
