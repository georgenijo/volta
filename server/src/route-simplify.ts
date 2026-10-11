import type { Row } from './db';

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

const earthM = 6371008.8, rad = Math.PI/180;

/** Per-attempt limits: `left` = points it may still keep, `work` = remaining
 * point-to-segment evaluations. */
type Budget = { left: number; work: number };

/** Indices kept by Ramer–Douglas–Peucker on one continuous run, measured in
 * metres on a local equirectangular projection (distance to the segment, so a
 * loop that returns to its start keeps its far point). Iterative: no stack
 * depth limit on long drives. Returns null as soon as the attempt keeps more
 * points than `budget.left` or runs out of work. */
function rdp(run: Row[], toleranceM: number, budget: Budget): number[] | null {
  if (run.length <= 2) { budget.left -= run.length; return budget.left < 0 ? null : run.map((_,i) => i); }
  const lat0 = run.reduce((sum,p) => sum+p.latitude,0)/run.length*rad, kx = earthM*rad*Math.cos(lat0), ky = earthM*rad;
  const x = run.map(p => p.longitude*kx), y = run.map(p => p.latitude*ky);
  const keep = new Uint8Array(run.length); keep[0] = 1; keep[run.length-1] = 1;
  budget.left -= 2;
  if (budget.left < 0) return null;
  const stack: [number,number][] = [[0,run.length-1]];
  while (stack.length) {
    const [a,b] = stack.pop()!;
    budget.work -= b-a-1;
    if (budget.work < 0) return null;
    const dx = x[b]!-x[a]!, dy = y[b]!-y[a]!, len2 = dx*dx+dy*dy;
    let worst = -1, index = -1;
    for (let i=a+1;i<b;i++) {
      const t = len2 > 0 ? Math.max(0,Math.min(1,((x[i]!-x[a]!)*dx+(y[i]!-y[a]!)*dy)/len2)) : 0;
      const d = Math.hypot(x[i]!-x[a]!-t*dx,y[i]!-y[a]!-t*dy);
      if (d > worst) { worst = d; index = i; }
    }
    if (worst > toleranceM) {
      keep[index] = 1;
      if (--budget.left < 0) return null;
      stack.push([a,index],[index,b]);
    }
  }
  return [...keep.keys()].filter(i => keep[i]);
}

/** Point-to-segment evaluations allowed per simplification, split evenly
 * across the attempts so an expensive low tolerance (adversarial zigzags make
 * RDP quadratic) cannot starve the cheap higher ones (~tens of ms in total). */
export const routeWorkBudget = 4_000_000;

/** Route preview: RDP per continuous run (never across a `routeBreakBefore`;
 * each run's first point stays flagged). An attempt stops as soon as it keeps
 * more than `maxPoints` or spends its share of the work budget; the tolerance
 * then doubles (up to 10 times). When every attempt fails, thinning (which carries the breaks)
 * is the bounded fallback. */
export function simplifyRoute(points: Row[], {toleranceM = 5, maxPoints = 300, workBudget = routeWorkBudget}: {toleranceM?: number; maxPoints?: number; workBudget?: number} = {}): Row[] {
  if (points.length <= 2) return points;
  const runs: Row[][] = [];
  for (const p of points) if (!runs.length || p.routeBreakBefore) runs.push([p]); else runs.at(-1)!.push(p);
  const attempts = 11;
  for (let attempt=0, tolerance=toleranceM; attempt<attempts; attempt++, tolerance*=2) {
    const budget: Budget = {left:maxPoints,work:Math.floor(workBudget/attempts)};
    const out: Row[] = [];
    let complete = true;
    for (const run of runs) {
      const kept = rdp(run,tolerance,budget);
      if (!kept) { complete = false; break; }
      for (const i of kept) out.push(run[i]!);
    }
    if (complete) return out;
  }
  return thin(points,maxPoints);
}
