import type { Row } from './db';
import { lostBetween, realGaps, type Span } from './fleet-gaps';

export type ChartPoint = { t: Date; v: number };
export type DriveCharts = { start: Date; end: Date; series: Partial<Record<ChartKey,ChartPoint[]>> };

/** session_samples column, Fleet Telemetry field(s) whose invalid flag makes
 * the observation unknown, and display rounding (decimals). ratedRangeKm is
 * RatedRange (miles x 1.609344 in the view): the only range field the API's
 * read-only views expose; EstBatteryRange/IdealBatteryRange are not. */
export const chartMetrics = {
  energyRemainingKwh:{column:'energy_remaining_kwh',fields:['EnergyRemaining'],digits:2},
  batteryLevel:{column:'battery_level',fields:['BatteryLevel'],digits:1},
  batteryTempMinC:{column:'battery_temp_min_c',fields:['ModuleTempMin'],digits:1},
  batteryTempMaxC:{column:'battery_temp_max_c',fields:['ModuleTempMax'],digits:1},
  insideTempC:{column:'inside_temp_c',fields:['InsideTemp'],digits:1},
  outsideTempC:{column:'outside_temp_c',fields:['OutsideTemp'],digits:1},
  ratedRangeKm:{column:'rated_range_km',fields:['RatedRange'],digits:1},
  speedKph:{column:'speed_kph',fields:['VehicleSpeed'],digits:1},
  powerKw:{column:'power_kw',fields:['PackVoltage','PackCurrent'],digits:1},
} as const;
export type ChartKey = keyof typeof chartMetrics | 'elevationM';
/** Dense metrics are bucketed to this many points (min and max per bucket). */
export const chartMaxPoints = 600;
export const fastMetrics: ChartKey[] = ['speedKph','powerKw','elevationM'];
/** How far back a change-only value may seed the start (see seedLookbackMs). */
export const seedLookbackMs = 12*3600000;

const round = (v: number, digits: number) => { const k = 10**digits; return Math.round(v*k)/k; };
const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);

/** Bound a step series to `max` points: keep the first and last points and,
 * per equal-time bucket, the minimum and maximum (in time order), so peaks
 * and troughs survive. */
export function boundSeries(points: ChartPoint[], max = chartMaxPoints): ChartPoint[] {
  if (points.length<=max) return points;
  const first = points[0]!, last = points.at(-1)!, inner = points.slice(1,-1), buckets = Math.floor((max-2)/2);
  const span = +last.t-+first.t || 1, picked: ChartPoint[] = [];
  let bucket: ChartPoint[] = [], index = 0;
  const flush = () => {
    if (!bucket.length) return;
    let lo = bucket[0]!, hi = bucket[0]!;
    for (const p of bucket) { if (p.v<lo.v) lo = p; if (p.v>hi.v) hi = p; }
    picked.push(...(lo === hi ? [lo] : +lo.t<=+hi.t ? [lo,hi] : [hi,lo]));
    bucket = [];
  };
  for (const p of inner) {
    const b = Math.min(buckets-1,Math.floor((+p.t-+first.t)/span*buckets));
    if (b !== index) { flush(); index = b; }
    bucket.push(p);
  }
  flush();
  return changeOnly([first,...picked,last],true);
}

/** Drop points that repeat the previous value; `keepLast` keeps the final
 * (end-of-window) point even when unchanged. */
function changeOnly(points: ChartPoint[], keepLast = false): ChartPoint[] {
  return points.filter((p,i) => !i || p.v !== points[i-1]!.v || (keepLast && i === points.length-1));
}

/** Forward-filled step series for one metric over [start, end]: a seed at
 * `start` (the last value at or before it, if any), one point per change,
 * and a final point at `end` holding the last value. Observations reported
 * invalid are skipped (the step holds); there are never breaks. */
export function stepSeries(observations: ChartPoint[], start: Date, end: Date, seed?: number | null, fast = false): ChartPoint[] {
  const inside = observations.filter(p => +p.t>=+start && +p.t<=+end).sort((a,b) => +a.t-+b.t);
  const points: ChartPoint[] = [];
  if (finite(seed) && !(inside.length && +inside[0]!.t === +start)) points.push({t:start,v:seed});
  for (const p of inside) if (!points.length || p.v !== points.at(-1)!.v) points.push(p);
  if (!points.length) return [];
  if (+points.at(-1)!.t<+end) points.push({t:end,v:points.at(-1)!.v});
  return fast ? boundSeries(points) : points;
}

/** Latest pre-start value per metric, discarded when it was reported
 * invalid, is older than the lookback, or a real data loss separates it
 * from the start (the car resends every field when the stream resumes). */
export function seedValues(rows: Row[], start: Date, gaps: Span[]): Partial<Record<keyof typeof chartMetrics,number>> {
  const seeds: Partial<Record<keyof typeof chartMetrics,number>> = {};
  for (const r of rows) {
    const key = r.key as keyof typeof chartMetrics, t = new Date(r.source_ts);
    if (!(key in chartMetrics) || !finite(r.v) || +start-+t>seedLookbackMs || +t>+start || lostBetween(realGaps(gaps),t,start)) continue;
    seeds[key] = round(r.v,chartMetrics[key].digits);
  }
  return seeds;
}

/** `samples`: session_samples rows inside the window; `seeds` from
 * seedValues; `elevation`: DEM points along the path (already timed). */
export function driveCharts(start: Date, end: Date, samples: Row[], seeds: Partial<Record<keyof typeof chartMetrics,number>>, elevation: ChartPoint[] = []): DriveCharts {
  const series: DriveCharts['series'] = {};
  for (const [key,m] of Object.entries(chartMetrics) as [keyof typeof chartMetrics, typeof chartMetrics[keyof typeof chartMetrics]][]) {
    const observations = samples.filter(s => finite(s[m.column]) && !m.fields.some(f => s.invalid_fields?.includes(f)))
      .map(s => ({t:new Date(s.source_ts),v:round(s[m.column],m.digits)}));
    const points = stepSeries(observations,start,end,seeds[key],fastMetrics.includes(key));
    if (points.length) series[key] = points;
  }
  const terrain = stepSeries(elevation.map(p => ({t:p.t,v:round(p.v,1)})),start,end,null,true);
  if (terrain.length) series.elevationM = terrain;
  return {start,end,series};
}
