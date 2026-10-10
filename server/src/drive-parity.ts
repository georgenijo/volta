import type { Row } from './db';

/** Net energy, never clamped to zero: a negative delta is not a costable drive. */
export function applyDriveEnergy(row: Row, fallback?: { energy: number | null; source: string | null }) {
  const rated = row.energyUsedKwh;
  const energy = typeof rated === 'number' && Number.isFinite(rated) && (rated > 0 || (rated === 0 && row.distanceKm === 0)) ? rated : fallback?.energy ?? null;
  row.energyUsedKwh = energy;
  row.energySource = energy === null ? null : energy === rated ? 'teslamate_rated_range' : fallback?.source;
  row.efficiencyWhPerKm = energy !== null && row.distanceKm > 0 ? energy * 1000 / row.distanceKm : null;
  return row;
}

/** Score v2 weights: efficiency 40%, smoothness 25%, acceleration 20%, speed
 * 15%. Normalize available components only; no guessed perfect values.
 * Efficiency: 100 at <=.85x rated, 40 at 2x rated (continuous exponential).
 * Acceleration: time share above .30g launch, below -.35g braking, or above
 * .35g lateral cornering. Smoothness: time-weighted jerk above .6 m/s³.
 * Speed: time-weighted excess above 130 km/h. Intervals >30s are unknown. */
export function efficiencyScore(whPerKm: number | null, ratedWhPerKm: number | null): number | null {
  if (whPerKm === null || ratedWhPerKm === null || !Number.isFinite(whPerKm) || !Number.isFinite(ratedWhPerKm)
    || whPerKm <= 0 || ratedWhPerKm <= 0) return null;
  return Math.round(100*Math.exp(-Math.log(2.5)/1.15*Math.max(0,whPerKm/ratedWhPerKm-.85)));
}
export function scoreFromStats(actual: number | null, rated: number | null, jerk: number | null, overspeed: number | null, harsh: number | null = null) {
  const measured=(n:number|null,scale:number)=>n !== null && Number.isFinite(n) && n>=0 ? Math.round(100*Math.exp(-n/scale)) : null;
  const scoreBreakdown={efficiency:efficiencyScore(actual,rated),smoothness:measured(jerk,.8),speed:measured(overspeed,20),acceleration:measured(harsh,.25)};
  const parts: [number | null,number][]=[[scoreBreakdown.efficiency,.4],[scoreBreakdown.smoothness,.25],[scoreBreakdown.speed,.15],[scoreBreakdown.acceleration,.2]];
  const known=parts.filter(([n])=>n !== null);
  return {scoreBreakdown,driveScore:known.length ? Math.round(known.reduce((sum,[n,w])=>sum+n!*w,0)/known.reduce((sum,[,w])=>sum+w,0)) : null};
}
export function driveStyleScore(actual: number | null, rated: number | null, points: Row[] = []) {
  let jerk=0,jerkTime=0,harsh=0,accelTime=0,speed=0,speedTime=0;
  const finite=(n:any): n is number=>typeof n==='number' && Number.isFinite(n);
  // Use one longitudinal source for the entire trip. Missing IMU readings
  // remain unknown; never difference an IMU value against a speed derivative.
  const recorded=points.some(p=>finite(p.longitudinalAccelerationMps2));
  for (let i=1;i<points.length;i++) {
    const a=points[i-1]!,b=points[i]!,dt=(+new Date(b.t)-+new Date(a.t))/1000;
    if (dt<=0 || dt>30 || b.routeBreakBefore) continue;
    const validSpeed=finite(a.speedKph) && finite(b.speedKph);
    const acceleration=recorded ? finite(b.longitudinalAccelerationMps2) ? b.longitudinalAccelerationMps2 : null
      : validSpeed ? (b.speedKph-a.speedKph)/3.6/dt : null;
    const lateral=finite(b.lateralAccelerationMps2) ? b.lateralAccelerationMps2 : null;
    if (acceleration !== null || lateral !== null) {
      if ((acceleration !== null && (acceleration>.3*9.80665 || acceleration<-.35*9.80665)) || (lateral !== null && Math.abs(lateral)>.35*9.80665)) harsh+=dt;
      accelTime+=dt;
    }

    if (validSpeed) {speed+=Math.max(0,(a.speedKph+b.speedKph)/2-130)*dt;speedTime+=dt;}
  }
  // Fixed 5-second means make smoothness insensitive to 0.5/1/2-second
  // speed quantization and telemetry cadence. Harsh-event share above still
  // uses full-resolution IMU observations so short launches are not erased.
  const buckets=new Map<number,Row>();
  for (const p of points) {
    const key=Math.floor(+new Date(p.t)/5000),b=buckets.get(key) ?? {t:new Date(key*5000),speed:0,speeds:0,accel:0,accels:0,routeBreakBefore:false};
    if (finite(p.speedKph)) {b.speed+=p.speedKph;b.speeds++;}
    if (finite(p.longitudinalAccelerationMps2)) {b.accel+=p.longitudinalAccelerationMps2;b.accels++;}
    b.routeBreakBefore ||= !!p.routeBreakBefore;buckets.set(key,b);
  }
  const grid=[...buckets.values()].sort((a,b)=>+a.t-+b.t);
  let previousAccel: number | null=null;
  for (let i=1;i<grid.length;i++) {
    const a=grid[i-1]!,b=grid[i]!,dt=(+b.t-+a.t)/1000;
    if (dt<=0 || dt>30 || b.routeBreakBefore) {previousAccel=null;continue;}
    const acceleration=recorded ? b.accels ? b.accel/b.accels : null
      : a.speeds && b.speeds ? (b.speed/b.speeds-a.speed/a.speeds)/3.6/dt : null;
    if (acceleration !== null && previousAccel !== null) {jerk+=Math.max(0,Math.abs(acceleration-previousAccel)/dt-.6)*dt;jerkTime+=dt;}
    previousAccel=acceleration;
  }
  return scoreFromStats(actual,rated,jerkTime ? jerk/jerkTime : null,speedTime ? speed/speedTime : null,accelTime ? harsh/accelTime : null);
}
export function driveScore(actual: number | null, rated: number | null, points: Row[] = []) { return driveStyleScore(actual,rated,points).driveScore; }
export function aggregateDriveScore(rows: Row[]) {
  const measured=rows.filter(r=>typeof r.driveScore==='number' && Number.isFinite(r.driveScore) && typeof r.distanceKm==='number' && r.distanceKm>0);
  const distance=measured.reduce((sum,r)=>sum+r.distanceKm,0);
  return distance>0 ? Math.round(measured.reduce((sum,r)=>sum+r.driveScore*r.distanceKm,0)/distance) : null;
}

export function endpointEnergy(first: Row | undefined, last: Row | undefined, start: Date, end: Date): number | null {
  if (!first || !last || +last.t <= +first.t || +first.t - +start > 120000 || +end - +last.t > 120000) return null;
  const delta = first.value - last.value;
  return Number.isFinite(delta) && delta > 0 ? delta : null;
}
