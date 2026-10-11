import { expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { gzipSync } from 'node:zlib';
import { Dem, elevationMaxSamples, elevationProfile, gainLoss, median5, samplePath, tileName } from '../src/elevation';

/** Synthetic tile: value(r, c) in metres, -32768 = void. Never real terrain. */
function hgt(size: number, value: (r: number, c: number) => number) {
  const b=Buffer.alloc(size*size*2);
  for (let r=0;r<size;r++) for (let c=0;c<size;c++) b.writeInt16BE(value(r,c),(r*size+c)*2);
  return b;
}
function withDir(run: (dir: string) => void) {
  const dir=mkdtempSync(join(tmpdir(),'volta-dem-'));
  try { run(dir); } finally { rmSync(dir,{recursive:true,force:true}); }
}

test('tile names follow SRTM floor-of-corner naming',()=>{
  expect(tileName(37.7,-122.4)).toBe('N37W123');expect(tileName(-0.5,0.5)).toBe('S01E000');expect(tileName(5,-5)).toBe('N05W005');
});

test('reads 1201 and 3601 big-endian tiles with bilinear interpolation, voids and gzip',()=>withDir(dir=>{
  // 3 arc-second, Skadi layout: value = 10*column + row.
  mkdirSync(join(dir,'N37'));writeFileSync(join(dir,'N37','N37W123.hgt'),hgt(1201,(r,c)=>10*c+r));
  const dem=new Dem(dir);
  // Row 0 is the north edge (38N); column 0 the west edge (123W).
  expect(dem.elevation(37.999999999,-123)).toBeCloseTo(0,3);
  expect(dem.elevation(37.5,-122.5)).toBeCloseTo(10*600+600,6);
  // Halfway between posts interpolates both axes.
  expect(dem.elevation(38-1.5/1200,-123+2.5/1200)).toBeCloseTo(10*2.5+1.5,6);
  expect(dem.elevation(36.5,-122.5)).toBeNull(); // no tile: null, never a fetch
  // 1 arc-second flat layout, gzip, with a void post dropped from the weights.
  writeFileSync(join(dir,'N36W123.hgt.gz'),gzipSync(hgt(3601,(r,c)=>r===10 && c===10 ? -32768 : 500)));
  const fine=new Dem(dir); // a fresh reader: missing tiles are cached as absent
  expect(fine.elevation(37-10.5/3600,-123+10.5/3600)).toBe(500);
  expect(fine.elevation(37-10/3600,-123+10/3600)).toBeCloseTo(500,9);
  // Wrong size is not a tile.
  writeFileSync(join(dir,'N35W123.hgt'),Buffer.alloc(1000));
  expect(dem.elevation(35.5,-122.5)).toBeNull();
  expect(Dem.fromEnv({})).toBeNull();expect(Dem.fromEnv({ELEVATION_DEM_DIR:dir})).toBeInstanceOf(Dem);
}));

test('path sampling every 50 m never interpolates across a route break',()=>{
  const at=(s:number)=>new Date(Date.UTC(2026,0,2)+s*1000);
  // ~111 m per 0.001 degree latitude.
  const path=[{t:at(0),latitude:37.7,longitude:-122.4},{t:at(10),latitude:37.701,longitude:-122.4},
    {t:at(400),latitude:37.71,longitude:-122.4,routeBreakBefore:true},{t:at(410),latitude:37.711,longitude:-122.4}];
  const out=samplePath(path,50)!;
  expect(out[0]).toBe(path[0]!);expect(out.at(-1)).toBe(path[3]!);
  const across=out.filter(p=>p.latitude>37.701 && p.latitude<37.71);expect(across).toHaveLength(0);
  expect(out.filter(p=>p.latitude>37.7 && p.latitude<37.701)).toHaveLength(2);
  expect(+out[1]!.t).toBeGreaterThan(+at(0));expect(+out[1]!.t).toBeLessThan(+at(10));
});

test('gain and loss use a 5-point median then 2 m hysteresis',()=>{
  expect(median5([0,0,100,0,0])).toEqual([0,0,0,0,0]); // one-post spike removed
  expect(gainLoss([0,1,0,1,0,1,0,1,0])).toEqual({gain:0,loss:0}); // sub-threshold ripple
  expect(gainLoss([0,10,20,30,20,10,0])!.gain).toBeCloseTo(20);
  expect(gainLoss([0,10,20,30,40,30,20,10,0])).toEqual({gain:30,loss:30});
  expect(gainLoss([5])).toBeNull();
});

test('elevation profile is null without a DEM or with under 80% terrain coverage',()=>withDir(dir=>{
  writeFileSync(join(dir,'N37W123.hgt'),hgt(1201,r=>(1200-r)*10));
  const at=(s:number)=>new Date(Date.UTC(2026,0,2)+s*1000);
  const path=Array.from({length:61},(_,i)=>({t:at(i*10),latitude:37.7+i*.0001,longitude:-122.4}));
  const p=elevationProfile(new Dem(dir),path);
  expect(p.gainM).toBeCloseTo(72,0);expect(p.lossM).toBe(0);expect(p.points[0]!.v).toBeCloseTo(8400);
  expect(elevationProfile(null,path)).toEqual({points:[],gainM:null,lossM:null});
  // The path leaves the tile: most samples have no terrain.
  const off=[...path.slice(0,5),{t:at(700),latitude:38.5,longitude:-122.4},{t:at(705),latitude:38.6,longitude:-122.4}];
  expect(elevationProfile(new Dem(dir),off).gainM).toBeNull();
}));

test('gain and loss are counted per continuous run: route breaks and terrain voids never add climb',()=>withDir(dir=>{
  const at=(s:number)=>new Date(Date.UTC(2026,0,2)+s*1000);
  // Flat 100 m west of column 600, flat 500 m east of it.
  writeFileSync(join(dir,'N37W123.hgt'),hgt(1201,(_,c)=>c<600 ? 100 : 500));
  const run=(lon:number,from:number,breakFirst=false)=>Array.from({length:21},(_,i)=>({t:at(from+i*10),latitude:37.5+i*.0005,longitude:lon,routeBreakBefore:breakFirst && i===0}));
  const split=elevationProfile(new Dem(dir),[...run(-122.9,0),...run(-122.1,600,true)]);
  expect(split.gainM).toBe(0);expect(split.lossM).toBe(0);
  // The chart stays continuous across the break.
  expect(split.points[0]!.v).toBeCloseTo(100);expect(split.points.at(-1)!.v).toBeCloseTo(500);
  // A genuine climb within one run is still counted.
  const climb=Array.from({length:41},(_,i)=>({t:at(i*10),latitude:37.5,longitude:-122.52+i*.001}));
  expect(elevationProfile(new Dem(dir),climb).gainM).toBeCloseTo(400,0);
  // A void band between the two levels on one unbroken path splits the run too.
  writeFileSync(join(dir,'N36W123.hgt'),hgt(1201,(_,c)=>c<500 ? 100 : c<=700 ? -32768 : 500));
  const east=Array.from({length:101},(_,i)=>({t:at(i*20),latitude:36.5,longitude:-123+i*.01}));
  const voided=elevationProfile(new Dem(dir),east);
  expect(voided.points.length).toBeGreaterThanOrEqual(.8*samplePath(east,50)!.length);
  expect(voided.gainM).toBe(0);expect(voided.lossM).toBe(0);
}));

test('DEM resampling is bounded: GPS jumps are route breaks and an oversized path is unknown',()=>withDir(dir=>{
  writeFileSync(join(dir,'N37W123.hgt'),hgt(1201,(_,c)=>c<600 ? 100 : 500));
  const at=(s:number)=>new Date(Date.UTC(2026,0,2)+s*1000);
  // A position flipping 1000 km away and back every 10s would be ~20000
  // samples per segment if interpolated; as jumps it is only its own points.
  const jumps=Array.from({length:200},(_,i)=>({t:at(i*10),latitude:i%2 ? 46.7 : 37.5,longitude:-122.9}));
  const started=performance.now(),out=samplePath(jumps,50)!;
  expect(out.length).toBeLessThanOrEqual(2*jumps.length);
  expect(out.filter(p=>p.routeBreakBefore)).toHaveLength(jumps.length-1);
  const p=elevationProfile(new Dem(dir),jumps);
  expect(performance.now()-started).toBeLessThan(200);
  // Every run is a single point: nothing measurable, never a 400 m climb.
  expect(p.gainM).toBeNull();expect(p.lossM).toBeNull();
  // Plausible travel that would still need more lookups than the budget.
  expect(samplePath([{t:at(0),latitude:37.5,longitude:-122.9},{t:at(200),latitude:37.5,longitude:-122.82}],50,100)).toBeNull();
  const long=Array.from({length:800},(_,i)=>({t:at(i*100),latitude:37.5+i*.06,longitude:-122.9}));
  const before=performance.now();
  expect(elevationProfile(new Dem(dir),long)).toEqual({points:[],gainM:null,lossM:null});
  expect(performance.now()-before).toBeLessThan(200);
}));

test('path sampling crosses the antimeridian the short way and stays on the route',()=>{
  const at=(s:number)=>new Date(Date.UTC(2026,0,2)+s*1000);
  const out=samplePath([{t:at(0),latitude:10,longitude:179.995},{t:at(30),latitude:10,longitude:-179.995}],50)!;
  // ~1.1 km of travel: about 22 samples, never a trip around the globe.
  expect(out.length).toBeGreaterThan(15);expect(out.length).toBeLessThan(30);
  for (const p of out) {
    expect(p.longitude).toBeGreaterThanOrEqual(-180);expect(p.longitude).toBeLessThan(180);
    expect(Math.min(Math.abs(p.longitude-180),Math.abs(p.longitude+180))).toBeLessThan(.006);
  }
});

test('the resampling budget is exact: the preflight counts every emitted point',()=>{
  const at=(s:number)=>new Date(Date.UTC(2026,0,2)+s*1000);
  const short=[{t:at(0),latitude:37.5,longitude:-122.9},{t:at(10),latitude:37.5+120/111195,longitude:-122.9}]; // ~120 m: ends + 2 samples
  const singles=[0,1,2].map(i=>({t:at(i*600),latitude:37.5+i*.01,longitude:-122.9,routeBreakBefore:i>0})); // three one-point runs
  const mixed=[...Array.from({length:30},(_,i)=>({t:at(i*10),latitude:37.5+i*.001,longitude:-122.9})),
    {t:at(300),latitude:40,longitude:-122.9}, // jump
    ...Array.from({length:20},(_,i)=>({t:at(400+i*10),latitude:40+i*.0007,longitude:-122.9,routeBreakBefore:i===0}))];
  const long=Array.from({length:750},(_,i)=>({t:at(i*100),latitude:-60+i*.06,longitude:-122.9})); // ~5000 km of plausible travel
  for (const path of [short,singles,mixed,long]) {
    const n=samplePath(path,50,Infinity)!.length;
    expect(samplePath(path,50,n)).toHaveLength(n);
    expect(samplePath(path,50,n-1)).toBeNull();
  }
  expect(samplePath(short,50,Infinity)).toHaveLength(4);expect(samplePath(singles,50,3)).toHaveLength(3);
  const n=samplePath(long,50,Infinity)!.length;
  expect(samplePath(long)===null).toBe(n>elevationMaxSamples);
});
