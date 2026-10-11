import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { gunzipSync } from 'node:zlib';

/** Offline terrain elevation from SRTM/Skadi `.hgt` tiles (1x1 degree,
 * 1201x1201 = 3 arc-second or 3601x3601 = 1 arc-second, big-endian int16
 * metres, -32768 = void, row 0 = north edge). Tiles live in
 * `ELEVATION_DEM_DIR` either flat (`N37W123.hgt`) or in the Skadi layout
 * (`N37/N37W123.hgt`); `.hgt.gz` is accepted too. Absent directory, tile or
 * data means null: never a network call at runtime. */
export const voidValue = -32768;
type Tile = { size: number; data: DataView } | null;

export function tileName(lat: number, lon: number) {
  const la = Math.floor(lat), lo = Math.floor(lon);
  return `${la<0?'S':'N'}${String(Math.abs(la)).padStart(2,'0')}${lo<0?'W':'E'}${String(Math.abs(lo)).padStart(3,'0')}`;
}

export class Dem {
  private tiles = new Map<string,Tile>();
  /** At most `maxTiles` decoded tiles stay cached (~26 MB each at 1 arc-second). */
  constructor(private dir: string, private maxTiles = 4) {}
  static fromEnv(env: Record<string,string | undefined> = process.env): Dem | null {
    const dir = env.ELEVATION_DEM_DIR?.trim();
    return dir ? new Dem(dir) : null;
  }
  private tile(name: string): Tile {
    if (this.tiles.has(name)) { const t = this.tiles.get(name)!; this.tiles.delete(name); this.tiles.set(name,t); return t; }
    let tile: Tile = null;
    for (const path of [join(this.dir,name.slice(0,3),`${name}.hgt`),join(this.dir,`${name}.hgt`),join(this.dir,name.slice(0,3),`${name}.hgt.gz`),join(this.dir,`${name}.hgt.gz`)]) {
      if (!existsSync(path)) continue;
      try {
        const raw = readFileSync(path), bytes = path.endsWith('.gz') ? gunzipSync(raw) : raw;
        const size = [1201,3601].find(n => n*n*2 === bytes.length);
        if (size) tile = {size,data:new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength)};
      } catch { tile = null; }
      break;
    }
    this.tiles.set(name,tile);
    if (this.tiles.size>this.maxTiles) this.tiles.delete(this.tiles.keys().next().value!);
    return tile;
  }
  /** Bilinear interpolation of the four surrounding posts; void posts are
   * dropped and the remaining weights renormalised (all void = null). */
  elevation(lat: number, lon: number): number | null {
    if (!Number.isFinite(lat) || !Number.isFinite(lon) || lat< -90 || lat>=90 || lon< -180 || lon>=180) return null;
    const tile = this.tile(tileName(lat,lon));
    if (!tile) return null;
    const n = tile.size-1, y = (Math.floor(lat)+1-lat)*n, x = (lon-Math.floor(lon))*n;
    const r0 = Math.min(n,Math.floor(y)), c0 = Math.min(n,Math.floor(x)), r1 = Math.min(n,r0+1), c1 = Math.min(n,c0+1), fy = y-r0, fx = x-c0;
    let sum = 0, weight = 0;
    for (const [r,c,w] of [[r0,c0,(1-fy)*(1-fx)],[r0,c1,(1-fy)*fx],[r1,c0,fy*(1-fx)],[r1,c1,fy*fx]] as const) {
      const v = tile.data.getInt16((r*tile.size+c)*2,false);
      if (v === voidValue || w <= 0) continue;
      sum += v*w; weight += w;
    }
    return weight>0 ? sum/weight : null;
  }
}

const earthM = 6371008.8, rad = Math.PI/180;
function meters(a: {latitude: number; longitude: number}, b: {latitude: number; longitude: number}) {
  const dLat = (b.latitude-a.latitude)*rad, dLon = (b.longitude-a.longitude)*rad;
  const h = Math.sin(dLat/2)**2+Math.cos(a.latitude*rad)*Math.cos(b.latitude*rad)*Math.sin(dLon/2)**2;
  return 2*earthM*Math.asin(Math.min(1,Math.sqrt(h)));
}

export type PathPoint = { t: Date; latitude: number; longitude: number; routeBreakBefore?: boolean };
/** Resampling budget: at most this many DEM lookups per drive (5000 km at 50 m). */
export const elevationMaxSamples = 100_000;
/** A segment implying more than this speed is a GPS jump, not travel. */
export const elevationMaxSpeedMps = 70;
const wrapLongitude = (lon: number) => ((lon+180)%360+360)%360-180;
/** Points every `spacingM` metres along each continuous run (never
 * interpolated across a route break or an implausible GPS jump, which also
 * starts a new run), plus each run's first and last point. Interpolation takes
 * the shorter way across the antimeridian. Null when the output would exceed
 * `maxSamples`; that is decided before anything is allocated. */
export function samplePath(path: PathPoint[], spacingM = 50, maxSamples = elevationMaxSamples): PathPoint[] | null {
  // One walk serves both passes: counting (no emit) stops as soon as the
  // budget is exceeded, so the emitting pass produces exactly what was counted.
  const walk = (emit?: (p: PathPoint) => void) => {
    let n = 0, last = -1, carried = 0; // last: index of the input point most recently emitted, -1 after an interpolated one
    const put = (p: PathPoint) => { n++; emit?.(p); };
    for (let i=0;i<path.length;i++) {
      const p = path[i]!;
      if (!i) { put(p); last = 0; continue; }
      const a = path[i-1]!, d = meters(a,p);
      if (p.routeBreakBefore || d>elevationMaxSpeedMps*Math.max(1,(+p.t-+a.t)/1000)) {
        if (last !== i-1) put(a);
        put(p.routeBreakBefore ? p : {...p,routeBreakBefore:true}); last = i; carried = 0;
      } else {
        const first = spacingM-carried, k = first<d ? Math.ceil((d-first)/spacingM) : 0;
        if (emit) {
          let dLon = p.longitude-a.longitude;
          if (dLon>180) dLon -= 360; else if (dLon<-180) dLon += 360;
          for (let j=0;j<k;j++) {
            const f = (first+j*spacingM)/d;
            put({t:new Date(+a.t+f*(+p.t-+a.t)),latitude:a.latitude+f*(p.latitude-a.latitude),longitude:wrapLongitude(a.longitude+f*dLon)});
          }
        } else n += k;
        if (k) last = -1;
        carried = d>0 ? (carried+d)%spacingM : carried;
      }
      if (!emit && n>maxSamples) return n;
    }
    if (path.length>1 && last !== path.length-1) put(path.at(-1)!);
    return n;
  };
  if (walk()>maxSamples) return null;
  const out: PathPoint[] = [];
  walk(p => out.push(p));
  return out;
}

/** Centred 5-point median; the window shrinks symmetrically at the ends, so
 * the first and last values are kept as observed. */
export function median5(values: number[]): number[] {
  return values.map((_,i) => {
    const half = Math.min(2,i,values.length-1-i);
    return values.slice(i-half,i+half+1).sort((a,b) => a-b)[half]!;
  });
}

/** Climb and descent after a 5-point median, counting a change only once it
 * moves `hysteresisM` away from the last counted level (DEM post noise and
 * bilinear ripple stay below it); the final sub-threshold residual is settled
 * at the end. */
export function gainLoss(values: number[], hysteresisM = 2): {gain: number; loss: number} | null {
  if (values.length<2) return null;
  const smooth = median5(values);
  let ref = smooth[0]!, gain = 0, loss = 0;
  for (const v of smooth.slice(1)) {
    if (v-ref >= hysteresisM) { gain += v-ref; ref = v; }
    else if (ref-v >= hysteresisM) { loss += ref-v; ref = v; }
  }
  // Settle the residual so gain - loss equals the smoothed net change.
  const rest = smooth.at(-1)!-ref;
  if (rest>0) gain += rest; else loss -= rest;
  return {gain,loss};
}

export const elevationSpacingM = 50, elevationHysteresisM = 2, elevationMinCoverage = .8;
/** DEM profile along a drive path. Gain/loss are summed over continuous runs
 * (split at route breaks and terrain voids) and are null unless at least 80%
 * of the sampled points have terrain data. */
export function elevationProfile(dem: Dem | null, path: PathPoint[]) {
  if (!dem || path.length<2) return {points:[] as {t: Date; v: number}[],gainM:null as number | null,lossM:null as number | null};
  const sampled = samplePath(path,elevationSpacingM);
  // Over the resampling budget: unknown, rather than an unbounded lookup.
  if (!sampled) return {points:[] as {t: Date; v: number}[],gainM:null as number | null,lossM:null as number | null};
  const samples = sampled.map(p => ({t:p.t,v:dem.elevation(p.latitude,p.longitude),routeBreakBefore:p.routeBreakBefore}));
  const points = samples.filter((p): p is {t: Date; v: number; routeBreakBefore: boolean | undefined} => p.v !== null).map(p => ({t:p.t,v:p.v}));
  // Smooth and count climb within each continuous run only: a route break or a
  // terrain void ends the run, so its level change is never counted as climb.
  // The chart series stays continuous.
  let gain = 0, loss = 0, counted = false, run: number[] = [];
  const flush = () => {
    const totals = gainLoss(run,elevationHysteresisM);
    if (totals) { gain += totals.gain; loss += totals.loss; counted = true; }
    run = [];
  };
  for (const p of samples) {
    if (p.v === null || p.routeBreakBefore) flush();
    if (p.v !== null) run.push(p.v);
  }
  flush();
  const ok = counted && points.length>=elevationMinCoverage*samples.length;
  return {points,gainM:ok ? Math.round(gain*10)/10 : null,lossM:ok ? Math.round(loss*10)/10 : null};
}
