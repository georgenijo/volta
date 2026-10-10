import { expect, test } from 'bun:test';
import { deriveDrive, mergeSessions, replacedDrive, telemetryDriveId, telemetryDriveVehicle, thin, type Window } from '../src/fleet-drives';
import { realGaps } from '../src/fleet-gaps';
import { driveId, listInput, page } from '../src/validation';
const at=(s:number)=>new Date(Date.UTC(2026,0,1)+s*1000);
const session=(start:number,end:number,startReason='gear',endReason='gear')=>({start:at(start),end:at(end),startReason,endReason});
const window: Window={id:telemetryDriveId(2,at(0)),start:at(0),end:at(600),_cursorStart:at(0).toISOString(),endReason:'gear'};
const points=[0,60,120,180,240,300,360,420,480,540,600].map((s,i)=>({source_ts:at(s),latitude:37.7+i*.001,longitude:-122.4,speed_kph:60,power_kw:6,odometer_km:100+i,battery_level_pct:80-i,soc_pct:80-i}));
const samples=points.map((p,i)=>({...p,battery_level:80-i,energy_remaining_kwh:50-i*.2,invalid_fields:[]}));
test('Park under three minutes joins manoeuvres; exactly three minutes, gaps and unobserved starts do not',()=>{
  const merged=mergeSessions(2,[session(0,60),session(239,600),session(610,640)],[]);
  expect(merged).toHaveLength(1);expect(merged[0]!.start).toEqual(at(0));expect(merged[0]!.end).toEqual(at(640));
  expect(mergeSessions(2,[session(0,60),session(240,600)],[])).toHaveLength(2);
  expect(mergeSessions(2,[session(0,60),session(100,600,'first_observed')],[])).toHaveLength(2);
  expect(mergeSessions(2,[session(0,60),session(160,600)], [{start:at(61),end:at(159),reason:'disconnected'}])).toHaveLength(2);
  expect(mergeSessions(2,[session(0,60),session(100,600)], [{start:at(70),end:at(71),reason:'gear_invalid'}])).toHaveLength(2);
});
test('cadence jitter is not data loss: rows below a minute vanish, real seams coalesce',()=>{
  const jitter=Array.from({length:600},(_,i)=>({start:at(i),end:at(i+1),reason:'disconnected'}));
  expect(realGaps(jitter)).toEqual([]);
  expect(realGaps([{start:at(0),end:at(30),reason:'silence'},{start:at(30),end:at(59.9),reason:'silence'}])).toEqual([]);
  const real=realGaps([{start:at(0),end:at(95),reason:'disconnected'},{start:at(95.5),end:at(190),reason:'silence'},
    {start:at(300),end:at(301),reason:'gear_invalid'},{start:at(400),end:at(491),reason:'disconnected'},{start:at(500),end:at(561),reason:'disconnected'}]);
  expect(real).toEqual([{start:at(0),end:at(190),reason:'disconnected'},{start:at(300),end:at(301),reason:'gear_invalid'},{start:at(400),end:at(491),reason:'disconnected'}]);
  expect(realGaps(real)).toEqual(real);
  // A flood of sub-second rows inside a drive keeps energy, score and the route intact.
  const flood=Array.from({length:1200},(_,i)=>({start:at(i/2),end:at(i/2+.5),reason:'disconnected'}));
  const row=deriveDrive({...window,startReason:'gear',membership:'complete'},points,points,samples,200,flood);
  expect(row.energyUsedKwh).toBe(2);expect(row.driveScore).not.toBeNull();expect(row.efficiencyWhPerKm).toBe(200);
  expect(row.route.some((p:any)=>p.routeBreakBefore)).toBe(false);expect(row.telemetry.gaps).toEqual([]);
  expect(deriveDrive(window,points,points,samples,200,[{start:at(250),end:at(345),reason:'disconnected'}]).energyUsedKwh).toBeNull();
});
test('a short seam while rolling joins whatever the reasons; Park stops still join; real loss never does',()=>{
  const moving=(end:Date,start:Date)=>+end===+at(2237) && +start===+at(2240);
  // 3-second P/D blip, second half lost its gear (first_observed): one trip.
  const split=[session(0,2237,'gear','gear'),session(2240,2760,'first_observed','open')];
  const one=mergeSessions(2,split,[],moving);
  expect(one).toHaveLength(1);expect(one[0]!.end).toEqual(at(2760));expect(one[0]!.parts).toHaveLength(2);
  expect(mergeSessions(2,split,[])).toHaveLength(2);
  expect(mergeSessions(2,[session(0,2237,'gear','gap'),session(2240,2760,'speed','gear')],[],moving)).toHaveLength(1);
  expect(mergeSessions(2,split,Array.from({length:6},(_,i)=>({start:at(2237+i*.5),end:at(2237.5+i*.5),reason:'disconnected'})),moving)).toHaveLength(1);
  // Park stop under three minutes still joins without speed evidence.
  expect(mergeSessions(2,[session(0,60),session(100,600)],[])).toHaveLength(1);
  // Real loss across the seam never joins, rolling or parked; a 60s heartbeat row is not loss.
  const lost=[session(0,2237),session(2297,2760)],gap=[{start:at(2200),end:at(2297),reason:'disconnected'}];
  expect(mergeSessions(2,lost,[{start:at(2237),end:at(2297),reason:'disconnected'}])).toHaveLength(1);
  expect(mergeSessions(2,lost,gap,()=>true)).toHaveLength(2);
  expect(mergeSessions(2,[session(0,2237),session(2240,2760,'first_observed')],[{start:at(2237),end:at(2240),reason:'disconnected'}],()=>true)).toHaveLength(1);
  expect(mergeSessions(2,[session(0,2237,'gear','open'),session(2296,2760,'first_observed')],[],()=>true)).toHaveLength(1);
  expect(mergeSessions(2,[session(0,2237,'gear','open'),session(2297,2760,'first_observed')],[],()=>true)).toHaveLength(2);
});
test('IDs are stable under continued points, separate vehicles and never collide with TeslaMate',()=>{
  const id=telemetryDriveId(2,at(0));expect(id).toBeLessThan(0);expect(Number.isSafeInteger(id)).toBe(true);
  expect(telemetryDriveVehicle(id)).toBe(2);expect(telemetryDriveId(3,at(0))).not.toBe(id);
  expect(mergeSessions(2,[session(0,60),session(100,600)],[])[0]!.id).toBe(id);
  expect(driveId(String(id))).toBe(id);
  for (const value of ['0','-0','1.5','-9007199254740992','2147483648']) expect(()=>driveId(value)).toThrow();
});
test('overlap wins, fully observed phantom trips disappear, outside history and receiver gaps remain',()=>{
  const catalog={windows:[window],gaps:[],start:at(-100),end:at(1000)};
  expect(replacedDrive({start:at(300),end:at(1200)},catalog)).toBe(true);
  expect(replacedDrive({start:at(700),end:at(800)},catalog)).toBe(true);
  expect(replacedDrive({start:at(-500),end:at(-200)},catalog)).toBe(false);
  expect(replacedDrive({start:at(1100),end:at(1200)},catalog)).toBe(false);
  expect(replacedDrive({start:at(700),end:at(800)},{...catalog,gaps:[{start:at(650),end:at(900),reason:'silence'}]})).toBe(false);
});
test('metric odometer is never converted twice; distance, energy, route and detail are equivalent',()=>{
  const row=deriveDrive(window,points,points,samples,200,[]);
  expect(row.distanceKm).toBe(10);expect(row.durationMin).toBe(10);expect(row.energyUsedKwh).toBe(2);
  expect(row.efficiencyWhPerKm).toBe(200);expect(row.avgSpeedKph).toBe(60);
  expect(row.route).toHaveLength(11);expect(row.path[0]!.elevationM).toBeNull();
  expect(row.telemetry.coverage.sourceSampleCount).toBe(11);expect(row.driveScore).toBeLessThan(100);
});
test('haversine fallback never crosses an unknown route span; energy invalidation stays unknown',()=>{
  const missing=points.map(p=>({...p,odometer_km:null}));
  expect(deriveDrive(window,missing,missing,samples,200,[]).distanceKm).toBeGreaterThan(1);
  expect(deriveDrive(window,missing,missing,samples,200,[{start:at(250),end:at(350),reason:'silence'}]).distanceKm).toBeNull();
  const invalid=samples.map((p,i)=>({...p,power_kw:null,invalid_fields:i===2?['EnergyRemaining']:[]}));
  expect(deriveDrive(window,points,points,invalid,200,[]).energyUsedKwh).toBeNull();
});
test('downsampling keeps endpoints and hidden route breaks',()=>{
  const full=Array.from({length:500},(_,i)=>({t:at(i),latitude:37.7,longitude:-122.4,routeBreakBefore:i===251}));
  const route=thin(full,64);expect(route).toHaveLength(64);expect(route[0]!.t).toEqual(at(0));expect(route.at(-1)!.t).toEqual(at(499));
  expect(route.some(p=>p.routeBreakBefore)).toBe(true);
});
test('mixed signed cursor IDs round trip while other endpoints reject negative IDs',()=>{
  const q=listInput({limit:'1'},'2/drives'), id=telemetryDriveId(2,at(600));
  const rows=[{id,start:at(600),_cursorStart:'2026-01-01T00:10:00.000123Z'},{id:1,start:at(0)}];
  const result=page(rows,q,'2/drives');expect(result.nextCursor).not.toBeNull();
  const continuation=listInput({cursor:result.nextCursor!,limit:'1'},'2/drives');
  expect(continuation.beforeId).toBe(id);expect(continuation.before).toBe('2026-01-01T00:10:00.000123Z');
  expect(()=>listInput({cursor:result.nextCursor!},'2/charges')).toThrow();
});

test('a known short Park stop cannot discard a trip whose first manoeuvre has no odometer',()=>{
  const windows=mergeSessions(2,[session(0,60),session(239,600)],[]);
  const route=[0,30,60,239,269,299,329,359,389,419,449,479,509,539,569,600].map((s,i)=>({source_ts:at(s),latitude:37.7+i*.001,longitude:-122.4,odometer_km:null}));
  const row=deriveDrive(windows[0]!,route,route,[],200,[]);
  expect(row.distanceKm).toBeGreaterThan(1);expect(row.route.some((p:any)=>p.routeBreakBefore)).toBe(true);
});

test('observed closed sessions retain change-only measurements during stationary boundary time',()=>{
  const w={...window,startReason:'gear',membership:'complete',end:at(1000)};
  const delayed=points.map(p=>({...p,source_ts:new Date(+p.source_ts+200000)}));
  expect(deriveDrive(w,delayed,delayed,[],200,[]).distanceKm).toBe(10);
  expect(deriveDrive(w,delayed,delayed,[],200,[{start:at(0),end:at(199),reason:'disconnected'}]).distanceKm).toBeNull();
});

test('change-only EnergyRemaining held from before a parked start; real loss or stale values do not hold',()=>{
  const w={...window,startReason:'first_observed',membership:'partial'};
  const late=samples.map(p=>+p.source_ts<+at(200) ? {...p,energy_remaining_kwh:null} : p);
  expect(deriveDrive(w,points,points,late,200,[]).energyUsedKwh).toBeNull();
  const before={source_ts:at(-600),energy_remaining_kwh:50.5};
  expect(deriveDrive(w,points,points,late,200,[],before).energyUsedKwh).toBeCloseTo(2.5);
  expect(deriveDrive(w,points,points,late,200,[{start:at(-300),end:at(-100),reason:'silence'}],before).energyUsedKwh).toBeNull();
  expect(deriveDrive(w,points,points,late,200,[],{...before,source_ts:at(-1801)}).energyUsedKwh).toBeNull();
  // The latest pre-start observation is an invalid EnergyRemaining: nothing to hold.
  expect(deriveDrive(w,points,points,late,200,[],{source_ts:at(-300),energy_remaining_kwh:null,invalid_fields:['EnergyRemaining']}).energyUsedKwh).toBeNull();
  expect(deriveDrive(w,points,points,samples,200,[],before).energyUsedKwh).toBe(2);
});
