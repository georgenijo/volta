import { createHash } from 'node:crypto';
import type { DB, Row } from './db';
import { combineScore, efficiencyScore, endpointEnergy, driveStyleScore } from './drive-parity';
import { coverageGap, lossGap, lostBetween, realGaps } from './fleet-gaps';
import { simplifyRoute, thin } from './route-simplify';
import { chartMetrics, driveCharts, seedLookbackMs, seedValues, type DriveCharts } from './drive-charts';
import { elevationProfile, type Dem } from './elevation';
export { thin };

const idBase = 2097152;
/** Sessions joined into one trip keep their own boundaries and reasons. */
export type Part = { start: Date; end: Date; startReason?: string; endReason?: string; membership?: string };
/** `previousStart`/`nextStart`: neighbouring trip windows, bounding where a
 * change-only odometer reading may be borrowed from. */
export type Window = { id: number; start: Date; end: Date; _cursorStart: string; endReason: string; startReason?: string; membership?: string; parts?: Part[];
  previousStart?: Date; nextStart?: Date };
export type Gap = { start: Date; end: Date; reason: string };
export type Catalog = { windows: Window[]; gaps: Gap[]; start: Date | null; end: Date | null };
/** A stop shorter than this between telemetry sessions is part of one trip. */
export const parkJoinMs = 600000;
/** Change-only odometer: the reading at or before a start holds at the start
 * (no earlier than 30 min / the previous trip's start, never across real
 * loss); a reading up to 120s after a Park end is the drive's delayed report. */
export const odometerLookbackMs = 1800000, odometerTailMs = 120000;
/** Route preview: RDP tolerance and hard point cap. */
export const routeToleranceM = 5, routeMaxPoints = 300;
/** Fallback endpoint city: nearest local address within this many metres. */
export const nearestCityM = 3000;

/** Collision-free signed JS/Swift integer: 32-bit epoch seconds, 21-bit car ID.
 * Distinct trips start in distinct seconds. Valid through 2106; never hash/truncate IDs. */
export function telemetryDriveId(vehicle: number, start: Date) {
  const seconds = Math.floor(+start / 1000);
  if (!Number.isInteger(vehicle) || vehicle <= 0 || vehicle >= idBase || seconds < 0 || seconds > 4294967295) throw new Error('Telemetry drive identity out of range');
  return -(seconds * idBase + vehicle);
}
export function telemetryDriveVehicle(id: number) { return Number.isSafeInteger(id) && id < 0 ? -id % idBase : 0; }
const resumeReasons = ['gear','first_observed','speed'];
/** `moving(end,start)`: speed >5 km/h within 15s on both sides of a boundary.
 * `charges`: known charging intervals; a stop containing one never joins. */
export function mergeSessions(vehicle: number, sessions: Row[], gaps: Gap[], moving: (end: Date, start: Date) => boolean = () => false, charges: Row[] = []): Window[] {
  const out: Window[] = [];
  gaps=realGaps(gaps);
  for (const s of sessions) {
    const start = new Date(s.start), end = new Date(s.end), previous = out.at(-1);
    // A stop under ten minutes after an observed Park joins trips, whether the
    // resume was observed (gear) or not (first_observed/speed: the gear was
    // forgotten across a short unrecorded break), unless data was lost or gear
    // unknown. A <60s seam with the car rolling on both sides is one trip
    // whatever the reasons (brief P/D, forgotten gear); never join across real data loss.
    const parked = previous && previous.endReason === 'gear' && resumeReasons.includes(s.startReason) && +start - +previous.end < parkJoinMs
      && !gaps.some(g => coverageGap(g) && +g.start < +start && +g.end > +previous.end);
    const rolling = previous && +start - +previous.end < 60000 && !lostBetween(gaps,previous.end,start) && moving(previous.end,start);
    const charged = previous && charges.some(c => +new Date(c.start) < +start && +new Date(c.end) >= +previous.end);
    const part: Part = {start,end,startReason:s.startReason,endReason:s.endReason,membership:s.membership};
    if (previous && +start >= +previous.end && (parked || rolling) && !charged) {
      previous.end = end; previous.endReason = s.endReason; if (s.membership==='partial') previous.membership='partial'; previous.parts!.push(part);
    } else out.push({id:telemetryDriveId(vehicle,start),start,end,_cursorStart:s._cursorStart ?? start.toISOString(),endReason:s.endReason,startReason:s.startReason,membership:s.membership,parts:[part]});
  }
  out.forEach((w,i) => { w.previousStart = out[i-1]?.start; w.nextStart = out[i+1]?.start; });
  return out;
}
/** Each joined session as its own window, bounded by its neighbouring parts. */
export function partWindows(w: Window): Window[] {
  const parts = w.parts?.length ? w.parts : [{start:w.start,end:w.end}];
  return parts.map((p,i) => ({...w,start:p.start,end:p.end,startReason:p.startReason ?? w.startReason,endReason:p.endReason ?? w.endReason,
    membership:p.membership ?? w.membership,parts:undefined,previousStart:i ? parts[i-1]!.start : w.previousStart,nextStart:parts[i+1]?.start ?? w.nextStart}));
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
    && !catalog.gaps.some(g => coverageGap(g) && +g.start < end && +g.end > start);
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
/** Regenerated energy (kWh, positive): the negative part of calibrated pack
 * power (positive = discharge), integrated linearly between consecutive
 * samples no more than 30s apart. Null unless those intervals cover >=80% of
 * the trip's moving parts and the window has no real loss or invalid pack
 * voltage/current. */
export function regenEnergy(window: Window, samples: Row[], gaps: Gap[]): number | null {
  if (lostBetween(realGaps(gaps),window.start,window.end) || samples.some(p => p.invalid_fields?.some((f:string) => ['PackVoltage','PackCurrent'].includes(f)))) return null;
  const powers=samples.filter(p => finite(p.power_kw)).map(p => ({t:+new Date(p.source_ts),kw:p.power_kw as number}));
  const parts=window.parts?.length ? window.parts : [{start:window.start,end:window.end}];
  const moving=parts.reduce((sum,p) => sum+Math.max(0,+p.end-+p.start),0);
  if (powers.length<2 || moving<=0) return null;
  // Area below zero (kW x ms) of the linear segment between two readings.
  const below=(t0: number, kw0: number, t1: number, kw1: number)=>{
    const dt=t1-t0;
    return kw0<=0 && kw1<=0 ? -(kw0+kw1)/2*dt : kw0<0 ? kw0*kw0/(kw1-kw0)/2*dt : kw1<0 ? kw1*kw1/(kw0-kw1)/2*dt : 0;
  };
  let kwh=0, covered=0;
  for (let i=1;i<powers.length;i++) {
    const a=powers[i-1]!, b=powers[i]!, dt=b.t-a.t;
    if (dt<=0 || dt>30000) continue;
    // Only time inside the moving parts counts: a joined Park stop (where the
    // car may even charge) is clipped out, interpolating at the clipped edges.
    for (const p of parts) {
      const t0=Math.max(a.t,+p.start), t1=Math.min(b.t,+p.end);
      if (t1<=t0) continue;
      const at=(t: number)=>a.kw+(b.kw-a.kw)*(t-a.t)/dt;
      covered+=t1-t0; kwh+=below(t0,at(t0),t1,at(t1))/3600000;
    }
  }
  return covered>=.8*moving ? kwh : null;
}
/** GPS distance over edges that one joined session contains entirely
 * (start <= a.t and b.t <= end; touching sessions both contain their shared
 * instant) and that are not route breaks; null when no edge qualifies, so an
 * unmeasurable path is never reported as 0 km. Positions are ordered and
 * sessions ordered and nonoverlapping: the only candidate for an edge is the
 * first session ending at or after its later point, found by a monotonic cursor. */
export function sessionDistance(path: {t: Date; latitude: number; longitude: number; routeBreakBefore?: boolean}[], sessions: {start: Date; end: Date}[]): number | null {
  const starts=sessions.map(s=>+s.start), ends=sessions.map(s=>+s.end);
  let k=0, edges=0, sum=0;
  for (let i=1;i<path.length;i++) {
    const a=path[i-1]!, b=path[i]!, ta=+a.t, tb=+b.t;
    while (k<ends.length && ends[k]!<tb) k++;
    if (k===ends.length) break;
    if (b.routeBreakBefore || starts[k]!>ta) continue;
    edges++; sum+=haversine(a,b);
  }
  return edges ? sum : null;
}
/** `before`: latest EnergyRemaining observation in the 30 min before the window.
 * `bounds`: the latest odometer reading before the start (in the lookback) and
 * the first one in the tail after the end; validated here against real loss. */
export function deriveDrive(window: Window, locations: Row[], payloads: Row[], samples: Row[], rated: number | null, gaps: Gap[], before?: Row,
  bounds: {odometerBefore?: Row; odometerAfter?: Row} = {}, splitParts = true): Row {
  const allGaps=gaps, real=realGaps(gaps);
  // EnergyRemaining is change-only: absent real loss, the last value before a
  // parked start still holds at the start (a first_observed start often waits
  // minutes for the first in-window change).
  const held=before && finite(before.energy_remaining_kwh) && +window.start-+new Date(before.source_ts)<=1800000
    && !lostBetween(real,new Date(before.source_ts),window.start) ? before.energy_remaining_kwh as number : null;
  gaps=realGaps(gaps.filter(g=>+new Date(g.start)<=+window.end && +new Date(g.end)>=+window.start));
  const path = locations.filter(gps).map(p => ({t:new Date(p.source_ts),latitude:p.latitude,longitude:p.longitude,
    speedKph:p.speed_kph,powerKw:p.power_kw,batteryLevel:finite(p.battery_level_pct) ? Math.round(p.battery_level_pct) : finite(p.soc_pct) ? Math.round(p.soc_pct) : null,socPct:p.soc_pct,elevationM:null,routeBreakBefore:false}));
  // The view's route_break_before trusts every jitter row; break only at real
  // loss or >120s without a position (which also separates the parts of a
  // joined trip across a parked stop unless positions continued through it).
  for (let i=1;i<path.length;i++) path[i]!.routeBreakBefore = +path[i]!.t-+path[i-1]!.t>120000 || lostBetween(gaps,path[i-1]!.t,path[i]!.t);
  const ts=(p: Row)=>+new Date(p.source_ts);
  const odometers = payloads.filter(p => finite(p.odometer_km));
  // Odometer is change-only: the latest reading at or before the start is the
  // start value, the first reading shortly after a Park end its end value.
  const ob=bounds.odometerBefore, oa=bounds.odometerAfter;
  const lead=ob && finite(ob.odometer_km) && ts(ob)<+window.start && +window.start-ts(ob)<=odometerLookbackMs
    && (!window.previousStart || ts(ob)>=+window.previousStart) && !lostBetween(real,new Date(ob.source_ts),window.start) ? ob : undefined;
  const tail=window.endReason==='gear' && oa && finite(oa.odometer_km) && ts(oa)>+window.end && ts(oa)-+window.end<=odometerTailMs
    && (!window.nextStart || ts(oa)<+window.nextStart) && !lostBetween(real,window.end,new Date(oa.source_ts)) ? oa : undefined;
  const atStart=[...(lead ? [lead] : []),...odometers.filter(p => ts(p)<=+window.start)].at(-1);
  const sequence=[...(lead ? [lead] : []),...odometers,...(tail ? [tail] : [])];
  const first = atStart ?? odometers[0], last = tail ?? odometers.at(-1);
  const interrupted = lostBetween(gaps,window.start,window.end);
  const observed=window.startReason==='gear' && window.endReason==='gear' && window.membership !== 'partial' && !interrupted;
  const validDelta = first && last && first !== last && (atStart || observed || ts(first)-+window.start<=120000)
    && (tail || observed || +window.end-ts(last)<=120000) && sequence.every((p,i) => !i || p.odometer_km >= sequence[i-1]!.odometer_km);
  let distance = validDelta ? last!.odometer_km-first!.odometer_km : null;
  if (distance === null && path.length>=2 && !interrupted && (observed || (!path.some((p,i) => i>0 && p.routeBreakBefore)
    && +path[0]!.t-+window.start<=120000 && +window.end-+path.at(-1)!.t<=120000))) {
    // Count only edges within one joined session: never a route break, and
    // never an edge into, through or out of a parked stop, however short.
    distance=sessionDistance(path,window.parts?.length ? window.parts : [window]);
  }
  let energy: number | null = null, energySource: string | null = null;
  if (!interrupted) {
    const remaining = samples.filter(p => finite(p.energy_remaining_kwh)).map(p => ({t:new Date(p.source_ts),value:p.energy_remaining_kwh}));
    if (held !== null && (!remaining.length || +remaining[0]!.t-+window.start>120000)) remaining.unshift({t:window.start,value:held});
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
  // A joined Park stop is known stationary time, not a missing route span.
  // When the whole window cannot be measured, measure each joined session
  // independently and add them; never connect GPS across the parked interval.
  if (splitParts && (distance === null || (energy === null && !interrupted)) && window.parts && window.parts.length>1) {
    const subs=partWindows(window), prior=(rows: Row[], at: Date, keep: (p: Row) => boolean)=>rows.filter(p=>ts(p)<+at && keep(p)).at(-1);
    const rows=subs.map((part,i)=> {
      const inside=(rows: Row[])=>rows.filter(p=>ts(p)>=+part.start && ts(p)<=+part.end);
      // An intermediate part's delayed post-Park reading lies inside the
      // joined stop, so it is already loaded; deriveDrive applies the same
      // 120 s / nextStart / loss checks as the queried tail of the last part.
      const after=i===subs.length-1 ? oa : odometers.find(p=>ts(p)>+part.end);
      return deriveDrive(part,inside(locations),inside(payloads),inside(samples),rated,allGaps,
        i ? prior(samples,part.start,p=>finite(p.energy_remaining_kwh) || p.invalid_fields?.includes('EnergyRemaining')) ?? before : before,
        {odometerBefore:i ? prior(payloads,part.start,p=>finite(p.odometer_km)) ?? ob : ob,odometerAfter:after});
    });
    if (distance === null && rows.every(r=>r.distanceKm !== null)) distance=rows.reduce((sum,r)=>sum+r.distanceKm,0);
    if (energy === null && !interrupted && rows.every(r=>r.energyUsedKwh !== null)) {
      energy=rows.reduce((sum,r)=>sum+r.energyUsedKwh,0);
      energySource=rows.every(r=>r.energySource==='fleet_energy_remaining') ? 'fleet_energy_remaining' : 'fleet_pack_power';
    }
  }
  const duration=(+window.end-+window.start)/60000, driving=(window.parts?.length ? window.parts : [window]).reduce((sum,p)=>sum+Math.max(0,+p.end-+p.start),0)/60000, speeds=samples.filter(p => finite(p.speed_kph)).map(p => p.speed_kph);
  const batteries=payloads.filter(p => finite(p.battery_level_pct) || finite(p.soc_pct));
  const actual=energy !== null && distance !== null && distance>0 ? energy*1000/distance : null;
  const scorePoints=samples.map(p => ({t:new Date(p.source_ts),speedKph:p.speed_kph,longitudinalAccelerationMps2:p.longitudinal_acceleration_mps2,lateralAccelerationMps2:p.lateral_acceleration_mps2,
    routeBreakBefore:gaps.some(g=>lossGap(g) && +g.start<=+new Date(p.source_ts) && +g.end>=+new Date(p.source_ts))}));
  const socByTime=new Map(payloads.filter(p=>finite(p.soc_pct)).map(p=>[+new Date(p.source_ts),p.soc_pct]));
  const series=samples.map(p => ({t:new Date(p.source_ts),latitude:p.latitude,longitude:p.longitude,speedKph:p.speed_kph,
    powerKw:p.power_kw,batteryLevel:p.battery_level ?? socByTime.get(+new Date(p.source_ts)) ?? null,socPct:socByTime.get(+new Date(p.source_ts)) ?? null,energyRemainingKwh:p.energy_remaining_kwh,outsideTempC:p.outside_temp_c,
    longitudinalAccelerationMps2:p.longitudinal_acceleration_mps2,elevationM:null,routeBreakBefore:false,invalidFields:p.invalid_fields ?? []}));
  let previous: Row | null=null;
  for (const p of series) if (gps(p)) { p.routeBreakBefore=previous !== null && (+p.t-+previous.t>120000 || lostBetween(gaps,previous.t,p.t)); previous=p; }
  const temperatures=samples.filter(p => finite(p.outside_temp_c)).map(p => p.outside_temp_c);
  return {id:window.id,start:window.start,end:window.end,_cursorStart:window._cursorStart,source:'fleet_telemetry',
    startAddress:null,endAddress:null,startCity:null,endCity:null,
    startLatitude:path[0]?.latitude ?? null,startLongitude:path[0]?.longitude ?? null,endLatitude:path.at(-1)?.latitude ?? null,endLongitude:path.at(-1)?.longitude ?? null,ratedWhPerKm:rated,distanceKm:distance,durationMin:duration,drivingMin:driving,
    startBatteryLevel:batteries.length ? Math.round(batteries[0]!.battery_level_pct ?? batteries[0]!.soc_pct) : null,
    endBatteryLevel:batteries.length ? Math.round(batteries.at(-1)!.battery_level_pct ?? batteries.at(-1)!.soc_pct) : null,
    energyUsedKwh:energy,energySource,regenKwh:regenEnergy(window,samples,gaps),efficiencyWhPerKm:actual,maxSpeedKph:speeds.length ? speeds.reduce((a,b)=>Math.max(a,b),0) : null,
    avgSpeedKph:distance !== null && duration>0 ? distance*60/duration : null,
    outsideTempAvgC:temperatures.length ? temperatures.reduce((a,b)=>a+b,0)/temperatures.length : null,
    ...driveStyleScore(actual,rated,scorePoints),electricityRatePerKwh:null,rateCurrency:null,
    route:simplifyRoute(path.map(({speedKph,powerKw,batteryLevel,socPct,elevationM,...p})=>p),{toleranceM:routeToleranceM,maxPoints:routeMaxPoints}),path:thin(path,2000),
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
    const receiverGapCount=gaps.filter(g=>lossGap(g) && +g.start<+points.at(-1)!.t && +g.end>+points[0]!.t).length;
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
    const [sessions,gaps,bounds,charges]=await Promise.all([
      this.sql`SELECT start_ts AS start,end_ts AS end,start_reason AS "startReason",end_reason AS "endReason",membership,
        to_char(start_ts AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS "_cursorStart"
        FROM volta_telemetry.sessions WHERE vehicle_id=${id} AND kind='drive' ORDER BY start_ts`,
      this.sql`SELECT start_ts AS start,end_ts AS end,reason FROM volta_telemetry.gaps WHERE vehicle_id=${id} AND (reason NOT IN ('disconnected','silence') OR end_ts-start_ts>=interval '90 seconds') ORDER BY start_ts`,
      this.sql`SELECT
        (SELECT source_ts FROM volta_telemetry.connectivity WHERE vehicle_id=${id} AND status='CONNECTED' ORDER BY source_ts LIMIT 1) AS connected,
        (SELECT max(source_ts) FROM volta_telemetry.latest_samples WHERE vehicle_id=${id}) AS latest`,
      // Known charges (telemetry and TeslaMate) block joining the drives around them.
      // An open charge counts as its start instant (stale open TeslaMate rows must not block every later join).
      this.sql`SELECT start_ts AS start,COALESCE(end_ts,start_ts) AS end FROM volta_telemetry.sessions WHERE vehicle_id=${id} AND kind='charge'
        UNION ALL SELECT start_date AT TIME ZONE 'UTC',COALESCE(end_date,start_date) AT TIME ZONE 'UTC' FROM public.charging_processes WHERE car_id=${id}`
    ]);
    const spans=realGaps(gaps);
    // Speed evidence only for <60s seams; one query per catalog.
    const seams=sessions.slice(1).map((s,i)=>({end:sessions[i]!.end,start:s.start}))
      .filter(p=>+new Date(p.start)>=+new Date(p.end) && +new Date(p.start)-+new Date(p.end)<60000);
    const rolling=new Set((seams.length ? await this.sql`SELECT b.start FROM jsonb_to_recordset(${this.sql.json(seams)}::jsonb) AS b("end" timestamptz,start timestamptz)
      WHERE EXISTS(SELECT 1 FROM volta_telemetry.session_samples p WHERE p.vehicle_id=${id} AND p.speed_kph>5
          AND p.source_ts BETWEEN b."end"-interval '15 seconds' AND b."end")
        AND EXISTS(SELECT 1 FROM volta_telemetry.session_samples p WHERE p.vehicle_id=${id} AND p.speed_kph>5
          AND p.source_ts BETWEEN b.start AND b.start+interval '15 seconds')` : []).map(r=>+new Date(r.start)));
    const starts=[sessions[0]?.start,bounds[0]?.connected].filter(Boolean).map(t=>new Date(t));
    const ends=[sessions.at(-1)?.end,bounds[0]?.latest].filter(Boolean).map(t=>new Date(t));
    return {windows:mergeSessions(id,sessions,spans,(_,start)=>rolling.has(+start),charges),gaps:spans,
      start:starts.length ? starts.reduce((a,b)=>+a<+b?a:b) : null,end:ends.length ? ends.reduce((a,b)=>+a>+b?a:b) : null};
  }
  /** Mileage needs totals, not GPS/chart arrays. Aggregate dense route and
   * power observations in PostgreSQL; transfer only slow odometer/energy rows. */
  /** Change-only odometer readings bracketing a window (see odometerLookbackMs). */
  private async odometerBounds(vehicle: number,w: Window) {
    const from=new Date(Math.max(+w.start-odometerLookbackMs,w.previousStart ? +w.previousStart : -Infinity));
    const until=new Date(Math.min(+w.end+odometerTailMs,w.nextStart ? +w.nextStart-1 : Infinity));
    // A post-end reading only settles a drive that ended in an observed Park;
    // an open or gap-ended window may still be moving after its last sample.
    const [[before],[after]]=await Promise.all([
      this.sql`SELECT source_ts,odometer_km FROM volta_telemetry.payload_points WHERE vehicle_id=${vehicle} AND odometer_km IS NOT NULL
        AND source_ts<${w.start} AND source_ts>=${from} ORDER BY source_ts DESC LIMIT 1`,
      w.endReason==='gear' ? this.sql`SELECT source_ts,odometer_km FROM volta_telemetry.payload_points WHERE vehicle_id=${vehicle} AND odometer_km IS NOT NULL
        AND source_ts>${w.end} AND source_ts<=${until} ORDER BY source_ts LIMIT 1` : Promise.resolve([])
    ]);
    return {odometerBefore:before,odometerAfter:after};
  }
  private async totals(vehicle: number,w: Window,gaps: Gap[],rated: number | null): Promise<Row> {
    const parts=this.sql.json(w.parts ?? [{start:w.start,end:w.end}]),lost=this.sql.json(realGaps(gaps).filter(g=>lossGap(g) && +g.start<=+w.end && +g.end>=+w.start));
    const [payloads,route,power,held,bounds]=await Promise.all([
      this.sql`SELECT * FROM volta_telemetry.payload_points WHERE vehicle_id=${vehicle} AND source_ts BETWEEN ${w.start} AND ${w.end}
        AND (odometer_km IS NOT NULL OR battery_level_pct IS NOT NULL OR soc_pct IS NOT NULL) ORDER BY source_ts`,
      this.sql`WITH s AS MATERIALIZED (
        SELECT start,"end" FROM jsonb_to_recordset(${parts}::jsonb) AS a(start timestamptz,"end" timestamptz)
      ), lost AS MATERIALIZED (
        SELECT start,"end" FROM jsonb_to_recordset(${lost}::jsonb) AS g(start timestamptz,"end" timestamptz)
      ), p AS MATERIALIZED (
        SELECT source_ts,latitude,longitude,
          lag(source_ts) OVER t AS previous_ts,lag(latitude) OVER t AS previous_latitude,lag(longitude) OVER t AS previous_longitude
        FROM volta_telemetry.drive_points WHERE vehicle_id=${vehicle} AND source_ts BETWEEN ${w.start} AND ${w.end}
          AND latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180 WINDOW t AS (ORDER BY source_ts)
      ), e AS (
        -- An edge counts when one joined session contains both endpoints
        -- (sessionDistance in JS); the session list is parsed once.
        SELECT p.*,previous_ts IS NOT NULL AND source_ts-previous_ts<=interval '120 seconds'
          AND EXISTS(SELECT 1 FROM s WHERE previous_ts>=s.start AND source_ts<=s."end") AS eligible FROM p
      ) SELECT min(source_ts) AS start,max(source_ts) AS finish,count(*) AS count,count(*) FILTER (WHERE eligible) AS edges,
        -- Whole-window support, as in deriveDrive: no position gap at all. A
        -- joined trip with a gap at its parked stop is measured per session
        -- (each with its own coverage) by the partial totals below.
        bool_and(previous_ts IS NULL OR (source_ts-previous_ts<=interval '120 seconds' AND NOT EXISTS(
            SELECT 1 FROM lost g WHERE g.start<source_ts AND g."end">previous_ts))) AS supported,
        -- Edges count only within one joined session, never across a stop.
        sum(CASE WHEN eligible THEN
          6371*2*asin(least(1.0,sqrt(power(sin(radians((latitude-previous_latitude)/2)),2)
          +cos(radians(previous_latitude))*cos(radians(latitude))*power(sin(radians((longitude-previous_longitude)/2)),2)))) ELSE 0 END) AS distance
        FROM e`,
      this.sql`WITH p AS MATERIALIZED (SELECT * FROM volta_telemetry.session_samples WHERE vehicle_id=${vehicle}
        AND source_ts BETWEEN ${w.start} AND ${w.end}), powers AS (
        SELECT source_ts,power_kw,lag(source_ts) OVER t AS previous_ts,lag(power_kw) OVER t AS previous_power
        FROM p WHERE power_kw IS NOT NULL WINDOW t AS (ORDER BY source_ts)
      ) SELECT (SELECT jsonb_agg(to_jsonb(p) ORDER BY source_ts) FROM p WHERE energy_remaining_kwh IS NOT NULL OR invalid_fields IS NOT NULL) AS samples,
        sum((power_kw+previous_power)/2*extract(epoch FROM source_ts-previous_ts)/3600) AS energy,
        count(*)>1 AND min(source_ts)>=${w.start}::timestamptz AND min(source_ts)<=${w.start}::timestamptz+interval '120 seconds'
          AND max(source_ts)>=${w.end}::timestamptz-interval '120 seconds'
          AND max(source_ts-previous_ts)<=interval '30 seconds'
          AND NOT EXISTS(SELECT 1 FROM p WHERE invalid_fields && ARRAY['PackVoltage','PackCurrent']) AS valid FROM powers`,
      this.sql`SELECT source_ts,energy_remaining_kwh FROM volta_telemetry.session_samples WHERE vehicle_id=${vehicle}
        AND source_ts<${w.start} AND source_ts>=${w.start}::timestamptz-interval '30 minutes'
        AND (energy_remaining_kwh IS NOT NULL OR 'EnergyRemaining'=ANY(invalid_fields)) ORDER BY source_ts DESC LIMIT 1`,
      this.odometerBounds(vehicle,w)
    ]);
    // The reduced rows are only the sparse EnergyRemaining/invalid samples:
    // their power readings are not a continuous series, so power is taken
    // solely from the SQL aggregate over every sample. Same order as detail:
    // whole-window EnergyRemaining, then whole-window power, then the parts.
    const reduced=(power[0]?.samples ?? []).map((p: Row)=>({...p,power_kw:null}));
    const row=deriveDrive(w,[],payloads,reduced,rated,gaps,held[0],bounds,false),r=route[0];
    // Totals never load the dense power series: regeneration is detail-only.
    row.regenKwh=null;
    const interrupted=lostBetween(realGaps(gaps),w.start,w.end);
    if (row.distanceKm === null && !interrupted && r && Number(r.count)>1 && Number(r.edges)>0
      && ((w.startReason==='gear' && w.endReason==='gear' && w.membership !== 'partial')
        || (r?.supported && +new Date(r.start)-+w.start<=120000 && +w.end-+new Date(r.finish)<=120000))) row.distanceKm=r.distance;
    if (row.energyUsedKwh === null && !interrupted && power[0]?.valid && power[0]?.energy>0) {row.energyUsedKwh=power[0].energy;row.energySource='fleet_pack_power';}
    let partials: Row[] | null=null;
    if (w.parts && w.parts.length>1 && (row.distanceKm === null || (row.energyUsedKwh === null && !interrupted))) {
      partials=[];
      for (const part of partWindows(w)) partials.push(await this.totals(vehicle,part,gaps,rated));
      if (row.distanceKm === null && partials.every(p=>p.distanceKm !== null)) row.distanceKm=partials.reduce((sum,p)=>sum+p.distanceKm,0);
    }
    if (row.energyUsedKwh === null && !interrupted && partials?.every(p=>p.energyUsedKwh !== null)) {
      row.energyUsedKwh=partials.reduce((sum,p)=>sum+p.energyUsedKwh,0);
      row.energySource=partials.every(p=>p.energySource==='fleet_energy_remaining') ? 'fleet_energy_remaining' : 'fleet_pack_power';
    }
    // Distance/energy fallbacks above: re-derive everything that depends on
    // them. Totals never load the dense motion series, so style components are
    // unknown here (the energy-only rows would misjudge them), not guessed.
    row.efficiencyWhPerKm=row.energyUsedKwh !== null && row.distanceKm !== null && row.distanceKm>0 ? row.energyUsedKwh*1000/row.distanceKm : null;
    row.avgSpeedKph=row.distanceKm !== null && row.durationMin>0 ? row.distanceKm*60/row.durationMin : null;
    row.scoreBreakdown={efficiency:efficiencyScore(row.efficiencyWhPerKm,rated),smoothness:null,speed:null,acceleration:null};row.driveScore=combineScore(row.scoreBreakdown);
    return row;
  }
  /** Detail-only extras for one resolved window: forward-filled chart series
   * and DEM elevation gain/loss (null without a configured DEM). */
  async detailExtras(vehicle: number, w: Window, gaps: Gap[], dem: Dem | null): Promise<{charts: DriveCharts; elevationGainM: number | null; elevationLossM: number | null; elevationMinM: number | null; elevationMaxM: number | null}> {
    const cols=Object.entries(chartMetrics);
    const [samples,seeds,locations]=await Promise.all([
      this.sql`SELECT * FROM volta_telemetry.session_samples WHERE vehicle_id=${vehicle} AND source_ts BETWEEN ${w.start} AND ${w.end} ORDER BY source_ts`,
      // Latest observation (value, or null when reported invalid) per metric.
      this.sql`SELECT k.key,(array_agg(s.source_ts ORDER BY s.source_ts DESC))[1] AS source_ts,(array_agg(k.v ORDER BY s.source_ts DESC))[1] AS v
        FROM volta_telemetry.session_samples s CROSS JOIN LATERAL jsonb_each(jsonb_build_object(
          ${this.sql.unsafe(cols.map(([key,m])=>`'${key}',jsonb_build_object('v',s.${m.column},'bad',s.invalid_fields && ARRAY[${m.fields.map(f=>`'${f}'`).join(',')}])`).join(','))})) AS e(key,o)
          CROSS JOIN LATERAL (SELECT e.key,CASE WHEN (e.o->>'bad')::boolean THEN NULL ELSE (e.o->>'v')::float8 END AS v) k
        WHERE s.vehicle_id=${vehicle} AND s.source_ts<=${w.start} AND s.source_ts>=${new Date(+w.start-seedLookbackMs)}
          AND (e.o->>'v' IS NOT NULL OR (e.o->>'bad')::boolean)
        GROUP BY k.key`,
      this.sql`SELECT source_ts,latitude,longitude FROM volta_telemetry.drive_points WHERE vehicle_id=${vehicle} AND source_ts BETWEEN ${w.start} AND ${w.end}
        AND latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180 ORDER BY source_ts`
    ]);
    const real=realGaps(gaps), path=locations.map(p=>({t:new Date(p.source_ts),latitude:p.latitude,longitude:p.longitude,routeBreakBefore:false}));
    for (let i=1;i<path.length;i++) path[i]!.routeBreakBefore=+path[i]!.t-+path[i-1]!.t>120000 || lostBetween(real,path[i-1]!.t,path[i]!.t);
    const profile=elevationProfile(dem,path);
    return {charts:driveCharts(w.start,w.end,samples,seedValues(seeds,w.start,real),profile.points),elevationGainM:profile.gainM,elevationLossM:profile.lossM,
      elevationMinM:profile.points.length ? profile.points.reduce((min,p)=>Math.min(min,p.v),Infinity) : null,
      elevationMaxM:profile.points.length ? profile.points.reduce((max,p)=>Math.max(max,p.v),-Infinity) : null};
  }
  /** City only (never an address) of the nearest local TeslaMate address
   * within 3 km, for endpoints no geofence/150 m address labels. */
  private async nearestCity(p: Row): Promise<string | null> {
    const dLat=nearestCityM/111320, dLon=Math.min(180,nearestCityM/(111320*Math.max(.01,Math.cos(p.latitude*Math.PI/180))));
    const [row]=await this.sql`SELECT city FROM (SELECT NULLIF(city,'') AS city,id,
        6371000*2*asin(least(1.0,sqrt(power(sin(radians((latitude-${p.latitude})/2)),2)+cos(radians(${p.latitude}))*cos(radians(latitude))*power(sin(radians((longitude-${p.longitude})/2)),2)))) AS meters
        FROM public.addresses WHERE NULLIF(city,'') IS NOT NULL AND latitude BETWEEN ${p.latitude-dLat} AND ${p.latitude+dLat}
          AND longitude BETWEEN ${p.longitude-dLon} AND ${p.longitude+dLon}) a
      WHERE meters<=${nearestCityM} ORDER BY meters,id LIMIT 1`;
    return row?.city ?? null;
  }
  async rows(vehicle: number, windows: Window[], rated: number | null, gaps: Gap[], labels = true, totalsOnly = false): Promise<Row[]> {
    const rows: Row[]=[];
    // Seek only requested session windows, not the car's entire GPS history.
    for (const w of windows) {
      let row: Row;
      if (totalsOnly) row=await this.totals(vehicle,w,gaps,rated);
      else {
      const [locations,payloads,samples,held,bounds]=await Promise.all([
        this.sql`SELECT * FROM volta_telemetry.drive_points WHERE vehicle_id=${vehicle} AND source_ts BETWEEN ${w.start} AND ${w.end} ORDER BY source_ts`,
        this.sql`SELECT * FROM volta_telemetry.payload_points WHERE vehicle_id=${vehicle} AND source_ts BETWEEN ${w.start} AND ${w.end} ORDER BY source_ts`,
        this.sql`SELECT * FROM volta_telemetry.session_samples WHERE vehicle_id=${vehicle} AND source_ts BETWEEN ${w.start} AND ${w.end} ORDER BY source_ts`,
        this.sql`SELECT source_ts,energy_remaining_kwh FROM volta_telemetry.session_samples WHERE vehicle_id=${vehicle}
        AND source_ts<${w.start} AND source_ts>=${w.start}::timestamptz-interval '30 minutes'
        AND (energy_remaining_kwh IS NOT NULL OR 'EnergyRemaining'=ANY(invalid_fields)) ORDER BY source_ts DESC LIMIT 1`,
        this.odometerBounds(vehicle,w)
      ]);
      row=deriveDrive(w,locations,payloads,samples,rated,gaps,held[0],bounds);
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
        row[i===0?'startAddress':'endAddress']=label?.address ?? null; row[i===0?'startCity':'endCity']=label?.city ?? await this.nearestCity(p);
      }
      rows.push(row);
    }
    return rows;
  }
}
