import { expect, test } from 'bun:test';
import { deriveDrive, haversine, mergeSessions, partWindows, replacedDrive, sessionDistance, telemetryDriveId, telemetryDriveVehicle, thin, type Window } from '../src/fleet-drives';
import { realGaps } from '../src/fleet-gaps';
import { driveId, listInput, page } from '../src/validation';
const at=(s:number)=>new Date(Date.UTC(2026,0,1)+s*1000);
const session=(start:number,end:number,startReason='gear',endReason='gear')=>({start:at(start),end:at(end),startReason,endReason});
const window: Window={id:telemetryDriveId(2,at(0)),start:at(0),end:at(600),_cursorStart:at(0).toISOString(),endReason:'gear'};
const points=[0,60,120,180,240,300,360,420,480,540,600].map((s,i)=>({source_ts:at(s),latitude:37.7+i*.001,longitude:-122.4,speed_kph:60,power_kw:6,odometer_km:100+i,battery_level_pct:80-i,soc_pct:80-i}));
const samples=points.map((p,i)=>({...p,battery_level:80-i,energy_remaining_kwh:50-i*.2,invalid_fields:[]}));
test('a short stop containing a known charge never joins the drives around it',()=>{
  const parked=[session(0,600),session(900,1500)];
  expect(mergeSessions(2,parked,[])).toHaveLength(1);
  // Four-minute charge inside the five-minute stop: two drives, energy not netted against the charge.
  expect(mergeSessions(2,parked,[],undefined,[{start:at(630),end:at(870)}])).toHaveLength(2);
  // Rolling seams are blocked too; charges outside the stop do not block.
  expect(mergeSessions(2,[session(0,600),session(630,900)],[],()=>true,[{start:at(605),end:at(625)}])).toHaveLength(2);
  expect(mergeSessions(2,parked,[],undefined,[{start:at(-900),end:at(-60)},{start:at(1600),end:at(2000)}])).toHaveLength(1);
  // An open charge (end = start) recorded at the Park instant still splits.
  expect(mergeSessions(2,parked,[],undefined,[{start:at(600),end:at(600)}])).toHaveLength(2);
});
test('a stop under ten minutes joins trips, observed or first_observed resume; exactly ten minutes, gaps and unknown gear do not',()=>{
  const merged=mergeSessions(2,[session(0,60),session(659,1000),session(1010,1040)],[]);
  expect(merged).toHaveLength(1);expect(merged[0]!.start).toEqual(at(0));expect(merged[0]!.end).toEqual(at(1040));
  expect(merged[0]!.parts!.map(p=>p.start)).toEqual([at(0),at(659),at(1010)]);
  expect(mergeSessions(2,[session(0,60),session(660,1000)],[])).toHaveLength(2);
  expect(mergeSessions(2,[session(0,60),session(100,600,'first_observed')],[])).toHaveLength(1);
  // The previous session must have ended in an observed Park.
  expect(mergeSessions(2,[session(0,60,'gear','gap'),session(100,600,'first_observed')],[])).toHaveLength(2);
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
  // Without speed evidence the 3s P/D stop still joins as a short Park stop.
  expect(mergeSessions(2,split,[])).toHaveLength(1);
  expect(mergeSessions(2,[session(0,2237,'gear','gap'),session(2240,2760,'speed','gear')],[],moving)).toHaveLength(1);
  expect(mergeSessions(2,split,Array.from({length:6},(_,i)=>({start:at(2237+i*.5),end:at(2237.5+i*.5),reason:'disconnected'})),moving)).toHaveLength(1);
  // Park stop under ten minutes still joins without speed evidence.
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
  // The fixture route is a straight line: the preview keeps only its endpoints.
  expect(row.route).toHaveLength(2);expect(row.path).toHaveLength(11);expect(row.path[0]!.elevationM).toBeNull();
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

// Synthetic two-stop trip: session A, a 5.5-minute parked stop, session B
// resumed with first_observed (the gear was forgotten across the stop).
const tripA=session(0,1200,'first_observed','gear'),tripB=session(1530,1710,'first_observed','gear');
const moving=(from:number,to:number,step:number,f:(s:number)=>Record<string,any>):Record<string,any>[]=>Array.from({length:Math.floor((to-from)/step)+1},(_,i)=>({source_ts:at(from+i*step),...f(from+i*step)}));
test('a 5.5-minute stop joins one trip, a 12-minute stop or real loss splits it',()=>{
  const merged=mergeSessions(2,[{...tripA,membership:'partial'},{...tripB,membership:'partial'}],[]);
  expect(merged).toHaveLength(1);expect(merged[0]!.end).toEqual(at(1710));expect(merged[0]!.membership).toBe('partial');
  expect(merged[0]!.parts).toHaveLength(2);
  expect(mergeSessions(2,[tripA,session(1920,2100,'first_observed','gear')],[])).toHaveLength(2);
  // A disconnect of at least 90s during the stop is real loss: never joined.
  expect(mergeSessions(2,[tripA,tripB],[{start:at(1250),end:at(1400),reason:'disconnected'}])).toHaveLength(2);
  // Neighbouring windows bound borrowed odometer readings.
  const three=mergeSessions(2,[session(-3000,-2000),tripA,tripB,session(4000,4500)],[]);
  expect(three.map(w=>[w.previousStart,w.nextStart])).toEqual([[undefined,at(0)],[at(-3000),at(4000)],[at(0),undefined]]);
});
test('a joined trip spans the stop: duration, average speed, energy and route are recomputed across both parts',()=>{
  const [w]=mergeSessions(2,[{...tripA,membership:'partial'},{...tripB,membership:'partial'}],[]);
  const locations=[...moving(0,1200,10,s=>({latitude:37.7+s*.00001,longitude:-122.4,speed_kph:50})),
    ...moving(1530,1710,10,s=>({latitude:37.712,longitude:-122.4+(s-1530)*.00001,speed_kph:30}))];
  // Odometer: last reading 13 minutes before the start, change-only inside, and the
  // final report 13s after the Park end.
  const payloads=[...moving(30,1170,60,s=>({odometer_km:2000+s/100,battery_level_pct:80-s/600})),...moving(1560,1680,60,s=>({odometer_km:2012+(s-1530)/100,battery_level_pct:77}))];
  const bounds={odometerBefore:{source_ts:at(-780),odometer_km:1999.8},odometerAfter:{source_ts:at(1723),odometer_km:2014}};
  const energy=[...moving(0,1200,10,s=>({energy_remaining_kwh:50-s/1000,power_kw:10,speed_kph:50})),...moving(1530,1710,10,s=>({energy_remaining_kwh:48-(s-1530)/1000,power_kw:10,speed_kph:30}))];
  const row=deriveDrive(w!,locations,payloads,energy,150,[],undefined,bounds);
  expect(row.durationMin).toBe(28.5);
  expect(row.distanceKm).toBeCloseTo(14.2);expect(row.avgSpeedKph).toBeCloseTo(14.2*60/28.5);
  expect(row.energyUsedKwh).toBeCloseTo(50-(48-.18));expect(row.energySource).toBe('fleet_energy_remaining');
  expect(row.efficiencyWhPerKm).toBeCloseTo(row.energyUsedKwh*1000/14.2);
  expect(row.startBatteryLevel).toBe(80);expect(row.endBatteryLevel).toBe(77);expect(row.maxSpeedKph).toBe(50);
  // The route breaks at the parked stop instead of drawing across it.
  const breaks=row.route.filter((p:any)=>p.routeBreakBefore);
  expect(breaks).toHaveLength(1);expect(breaks[0].t).toEqual(at(1530));
  // Pack power with no samples during the stop: each part is integrated separately.
  const power=energy.map(({energy_remaining_kwh,...p})=>p);
  const parts=deriveDrive(w!,locations,payloads,power,150,[],undefined,bounds);
  expect(parts.energyUsedKwh).toBeCloseTo(10*(1200+180)/3600);expect(parts.energySource).toBe('fleet_pack_power');
  // Without any odometer, distance falls back to each part's GPS, never across the stop.
  const gpsOnly=deriveDrive(w!,locations,[],power,150,[]);
  expect(gpsOnly.distanceKm).toBeGreaterThan(1.3);expect(gpsOnly.distanceKm).toBeLessThan(1.6);
});
test('distance uses the last odometer reading at or before the start, bounded by lookback, previous trip and real loss',()=>{
  const w={...window,startReason:'first_observed',membership:'partial'};
  const inside=[{source_ts:at(20),odometer_km:100.1},{source_ts:at(300),odometer_km:105},{source_ts:at(590),odometer_km:110}];
  expect(deriveDrive(w,points,inside,[],200,[]).distanceKm).toBeCloseTo(9.9);
  const before={source_ts:at(-600),odometer_km:100};
  expect(deriveDrive(w,points,inside,[],200,[],undefined,{odometerBefore:before}).distanceKm).toBeCloseTo(10);
  expect(deriveDrive(w,points,inside,[],200,[],undefined,{odometerBefore:{...before,source_ts:at(-1801)}}).distanceKm).toBeCloseTo(9.9);
  expect(deriveDrive(w,points,inside,[],200,[{start:at(-500),end:at(-300),reason:'silence'}],undefined,{odometerBefore:before}).distanceKm).toBeCloseTo(9.9);
  expect(deriveDrive({...w,previousStart:at(-500)},points,inside,[],200,[],undefined,{odometerBefore:before}).distanceKm).toBeCloseTo(9.9);
  // A reading inside the previous trip is allowed (its last change-only report).
  expect(deriveDrive({...w,previousStart:at(-900)},points,inside,[],200,[],undefined,{odometerBefore:before}).distanceKm).toBeCloseTo(10);
  // A delayed report shortly after the Park end completes the drive.
  const after={source_ts:at(650),odometer_km:110.2};
  expect(deriveDrive(w,points,inside,[],200,[],undefined,{odometerBefore:before,odometerAfter:after}).distanceKm).toBeCloseTo(10.2);
  expect(deriveDrive(w,points,inside,[],200,[],undefined,{odometerBefore:before,odometerAfter:{...after,source_ts:at(721)}}).distanceKm).toBeCloseTo(10);
  expect(deriveDrive({...w,nextStart:at(640)},points,inside,[],200,[],undefined,{odometerBefore:before,odometerAfter:after}).distanceKm).toBeCloseTo(10);
  // Only an observed Park settles the drive: an open or gap-ended window may still be moving.
  expect(deriveDrive({...w,endReason:'gap'},points,inside,[],200,[],undefined,{odometerBefore:before,odometerAfter:after}).distanceKm).toBeCloseTo(10);
  expect(deriveDrive({...w,endReason:'open'},points,inside,[],200,[],undefined,{odometerBefore:before,odometerAfter:after}).distanceKm).toBeCloseTo(10);
  // A decreasing borrowed reading is not a valid delta; GPS fallback is still guarded.
  expect(deriveDrive(w,[],inside,[],200,[],undefined,{odometerBefore:{...before,odometer_km:101}}).distanceKm).toBeNull();
});
test('regen integrates negative pack power over dense samples and is unknown when sparse, lost or invalid',()=>{
  const dense=moving(0,600,2,s=>({power_kw:s<300 ? 20 : -10,invalid_fields:[]}));
  const row=deriveDrive(window,points,points,dense,200,[]);
  expect(row.regenKwh).toBeCloseTo((10*300+100/30/2*2)/3600,6);
  expect(deriveDrive(window,points,points,moving(0,600,60,()=>({power_kw:-10})),200,[]).regenKwh).toBeNull();
  // 75% coverage is not enough.
  expect(deriveDrive(window,points,points,dense.filter(p=>+p.source_ts<+at(450)),200,[]).regenKwh).toBeNull();
  expect(deriveDrive(window,points,points,dense,200,[{start:at(100),end:at(200),reason:'disconnected'}]).regenKwh).toBeNull();
  expect(deriveDrive(window,points,points,dense.map((p,i)=>i===5 ? {...p,invalid_fields:['PackCurrent']} : p),200,[]).regenKwh).toBeNull();
  expect(deriveDrive(window,points,points,moving(0,600,2,()=>({power_kw:15})),200,[]).regenKwh).toBe(0);
});
test('an intermediate part takes its own delayed post-Park odometer report from the joined stop',()=>{
  // Part A ends in Park; its last odometer change (110.0) arrives 30s into the stop.
  // Part B ends in a gap with GPS only, so the whole window cannot be measured.
  const [w]=mergeSessions(2,[tripA,{...session(1530,1710,'first_observed','gap')}],[]);
  expect(w!.parts).toHaveLength(2);
  const locB=moving(1530,1710,10,s=>({latitude:37.712,longitude:-122.4+(s-1530)*.00001,speed_kph:30}));
  const locations=[...moving(0,1200,10,s=>({latitude:37.7+s*.00001,longitude:-122.4,speed_kph:50})),...locB];
  const odometers=moving(0,1188,12,s=>({odometer_km:100+s/120}));
  const gpsB=deriveDrive(partWindows(w!)[1]!,locB,[],[],150,[]).distanceKm;
  expect(gpsB).toBeGreaterThan(.1);
  const delayed=deriveDrive(w!,locations,[...odometers,{source_ts:at(1230),odometer_km:110}],[],150,[]);
  expect(delayed.distanceKm).toBeCloseTo(10+gpsB,6);
  // The same 120s bound as the last part's tail: a later report is not used.
  expect(deriveDrive(w!,locations,[...odometers,{source_ts:at(1330),odometer_km:110}],[],150,[]).distanceKm).toBeCloseTo(9.9+gpsB,6);
});
test('regen is clipped to the moving parts: charging during a joined stop is not regeneration',()=>{
  // Part B starts between two samples, so the clipped edge is interpolated.
  const [w]=mergeSessions(2,[tripA,session(1531,1711,'first_observed','gear')],[]);
  const moving_=(s:number)=>s<=1200 || s>=1531;
  const power=moving(0,1710,2,s=>({power_kw:moving_(s) ? 10 : -50,invalid_fields:[]}));
  const row=deriveDrive(w!,[],[],power,150,[]);
  // Only [1531,1532] of the 1530 -> 1532 interval counts: -20 kW at 1531 rising to +10 kW.
  expect(row.regenKwh).toBeCloseTo(20*20/30/2/3600,9);
  // Without the stop samples' charging it is the same.
  expect(deriveDrive(w!,[],[],power.filter(p=>moving_((+p.source_ts-+at(0))/1000)),150,[]).regenKwh).toBe(0);
});
test('session distance: an edge counts when one session holds both ends; none eligible is unknown, not zero',()=>{
  const p=(s:number,lat:number,routeBreakBefore=false)=>({t:at(s),latitude:lat,longitude:-122.4,routeBreakBefore});
  const touching=[{start:at(0),end:at(600)},{start:at(600),end:at(1200)}];
  const path=[p(590,37.7),p(600,37.701),p(610,37.702)];
  expect(sessionDistance(path,touching)).toBeCloseTo(haversine(path[0]!,path[1]!)+haversine(path[1]!,path[2]!),9);
  // Across a stop, through it, or after a break: nothing measurable.
  const apart=[{start:at(0),end:at(600)},{start:at(660),end:at(1200)}];
  expect(sessionDistance([p(590,37.7),p(670,37.71)],apart)).toBeNull();
  expect(sessionDistance([p(590,37.7),p(630,37.705),p(670,37.71)],apart)).toBeNull();
  expect(sessionDistance([p(0,37.7),p(600,37.71,true)],[{start:at(0),end:at(600)}])).toBeNull();
  expect(sessionDistance([p(0,37.7)],[{start:at(0),end:at(600)}])).toBeNull();
  // A genuinely measured zero-length edge is 0.
  expect(sessionDistance([p(0,37.7),p(10,37.7)],[{start:at(0),end:at(600)}])).toBe(0);
});
test('session distance is linear in positions and sessions',()=>{
  const sessions=Array.from({length:100},(_,k)=>({start:at(k*1100),end:at(k*1100+1000)}));
  const path=Array.from({length:100000},(_,i)=>({t:at(i*1.1),latitude:37.7+(i%1000)*.00001,longitude:-122.4}));
  const started=performance.now(),d=sessionDistance(path,sessions);
  expect(performance.now()-started).toBeLessThan(100);expect(d).toBeGreaterThan(0);
});
