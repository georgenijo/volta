import { expect, test } from 'bun:test';
import { simplifyRoute } from '../src/route-simplify';
const at=(s:number)=>new Date(Date.UTC(2026,0,1)+s*1000);
// Synthetic Bay Area coordinates; ~11 m per 0.0001 degree of latitude.
const line=(from:[number,number],to:[number,number],n:number,t0=0)=>Array.from({length:n},(_,i)=>({t:at(t0+i*2),
  latitude:from[0]+(to[0]-from[0])*i/(n-1),longitude:from[1]+(to[1]-from[1])*i/(n-1),routeBreakBefore:false}));
const join=(...runs:any[][])=>runs.reduce((all,run)=>[...all,...(all.length ? run.slice(1) : run)],[]);

test('keeps corners of an L-shaped and a zigzag route while collinear points drop',()=>{
  const l=join(line([37.7,-122.4],[37.71,-122.4],100),line([37.71,-122.4],[37.71,-122.39],100));
  const simple=simplifyRoute(l,{toleranceM:5,maxPoints:300});
  expect(simple.map(p=>[p.latitude,p.longitude])).toEqual([[37.7,-122.4],[37.71,-122.4],[37.71,-122.39]]);
  const vertices:[number,number][]=[[37.7,-122.4],[37.702,-122.398],[37.7,-122.396],[37.702,-122.394],[37.7,-122.392]];
  const zigzag=join(...vertices.slice(1).map((v,i)=>line(vertices[i]!,v,40)));
  expect(simplifyRoute(zigzag).map(p=>[p.latitude,p.longitude])).toEqual(vertices);
  // A 3 m wobble is below tolerance; a 30 m detour is kept.
  const wobble=l.map((p,i)=>i===50 ? {...p,longitude:p.longitude+.00003} : p);
  expect(simplifyRoute(wobble)).toHaveLength(3);
  const detour=l.map((p,i)=>i===50 ? {...p,longitude:p.longitude+.0003} : p);
  expect(simplifyRoute(detour).length).toBeGreaterThan(3);
});

test('never connects across a route break; the first point of every run stays flagged',()=>{
  const a=line([37.7,-122.4],[37.71,-122.4],50),b=line([37.72,-122.39],[37.73,-122.39],50,500).map((p,i)=>({...p,routeBreakBefore:i===0}));
  const simple=simplifyRoute([...a,...b]);
  expect(simple).toHaveLength(4);
  expect(simple.map(p=>p.routeBreakBefore)).toEqual([false,false,true,false]);
  expect(simple[1]!.t).toEqual(a.at(-1)!.t);expect(simple[2]!.t).toEqual(b[0]!.t);
  // A single-point run survives on its own.
  const lone=[...a,{...b[0]!},...b.slice(1).map((p,i)=>({...p,routeBreakBefore:i===0}))];
  expect(simplifyRoute(lone).filter(p=>p.routeBreakBefore)).toHaveLength(2);
});

test('respects the point cap: raises tolerance, then falls back to even thinning that carries breaks',()=>{
  // 5000-point 40 m zigzag: every vertex survives 5 m, so tolerance rises.
  const noisy=Array.from({length:5000},(_,i)=>({t:at(i*2),latitude:37.7+i*.0001,longitude:-122.4+(i%2)*.0004,routeBreakBefore:false}));
  const simple=simplifyRoute(noisy,{toleranceM:5,maxPoints:300});
  expect(simple.length).toBeLessThanOrEqual(300);expect(simple[0]).toBe(noisy[0]);expect(simple.at(-1)).toBe(noisy.at(-1));
  // 400 separate runs cannot be simplified under 300 points.
  const runs=Array.from({length:800},(_,i)=>({t:at(i*2),latitude:37.7+i*.001,longitude:-122.4,routeBreakBefore:i>0 && i%2===0}));
  const capped=simplifyRoute(runs,{maxPoints:300});
  expect(capped).toHaveLength(300);expect(capped.some(p=>p.routeBreakBefore)).toBe(true);
  expect(capped[0]).toEqual(runs[0]);expect(capped.at(-1)!.t).toEqual(runs.at(-1)!.t);
});
test('dense routes stay bounded in time: a 20k-point zigzag never runs unbounded RDP',()=>{
  for (const amplitude of [.0005,.005]) {
    const zigzag=Array.from({length:20000},(_,i)=>({t:new Date(i*1000),latitude:37.7+i*.00001,longitude:-122.4+(i%2 ? amplitude : 0),routeBreakBefore:false}));
    const started=performance.now(), out=simplifyRoute(zigzag);
    expect(performance.now()-started).toBeLessThan(200);
    expect(out.length).toBeLessThanOrEqual(300);expect(out[0]).toBe(zigzag[0]!);expect(out.at(-1)).toBe(zigzag.at(-1)!);
  }
  // An exhausted work budget falls back to thinning, still carrying breaks.
  const pts=Array.from({length:1000},(_,i)=>({t:new Date(i*1000),latitude:37.7+i*.0001,longitude:-122.4+(i%2 ? .001 : 0),routeBreakBefore:i===500}));
  const out=simplifyRoute(pts,{maxPoints:100,workBudget:10});
  expect(out).toHaveLength(100);expect(out.filter(p=>p.routeBreakBefore)).toHaveLength(1);
});
