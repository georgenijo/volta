import { afterAll, beforeEach, expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { connect } from '../src/db';
import { Telemetry } from '../src/telemetry';
import { FleetDrives } from '../src/fleet-drives';
import { Auth } from '../src/auth';
import { createApp } from '../src/app';
import { DriveDetail } from '../src/drive-detail';
import { Dem } from '../src/elevation';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const url=process.env.TEST_DATABASE_URL;
if (!url || new URL(url).pathname!=='/volta_test' || !['127.0.0.1','localhost'].includes(new URL(url).hostname)) throw new Error('Isolated volta_test database required');
const owner=connect(url),reader=connect(process.env.TESLAMATE_DATABASE_URL!,true),authDB=connect(process.env.AUTH_DATABASE_URL!);
const auth=new Auth(authDB),telemetry=new Telemetry(reader,'USD',()=>new Date('2026-01-02T20:00:00Z'),true),app=createApp(auth,telemetry,()=>{});
const at=(s:number)=>new Date(Date.UTC(2026,0,2)+s*1000);
let token='';
beforeEach(async()=>{
  await owner`TRUNCATE volta_telemetry.samples,volta_telemetry.sessions,volta_telemetry.gaps,volta_telemetry.vehicle_bindings,volta_telemetry.power_calibration`;
  await owner`TRUNCATE public.charges,public.charging_processes,public.positions,public.drives,public.states,public.updates,public.cars,public.car_settings,public.addresses,public.geofences,volta.devices,volta.pairing_codes,volta.rate_limits RESTART IDENTITY CASCADE`;
  await owner.file(new URL('fixtures.sql',import.meta.url));
  const [car]=await owner`SELECT vin FROM cars WHERE id=1`;
  const digest=createHash('sha256').update('volta-telemetry-vin-binding-v1\0').update(car!.vin).digest('hex');
  await owner`INSERT INTO volta_telemetry.vehicle_bindings(vehicle_id,vin_digest) VALUES (1,${digest})`;
  await owner`UPDATE geofences SET latitude=37.7,longitude=-122.4 WHERE id=1`;
  await owner`UPDATE addresses SET latitude=37.7,longitude=-122.4,city='Synthetic Bay City' WHERE id=1`;
  await owner`DELETE FROM positions WHERE drive_id IS NOT NULL`;
  await owner`DELETE FROM drives`;
  token=(await auth.pair({code:await auth.createPairingCode(),deviceName:'Synthetic history'})).token;
});
afterAll(async()=>{await owner`TRUNCATE volta_telemetry.samples,volta_telemetry.sessions,volta_telemetry.gaps,volta_telemetry.vehicle_bindings`;await Promise.all([owner.end(),reader.end(),authDB.end()]);});
async function get(path:string){const r=await app.request(path,{headers:{Authorization:`Bearer ${token}`}});expect(r.status).toBe(200);return await r.json() as any;}
async function trip(start:number,end:number,offset=0){
  await owner`INSERT INTO volta_telemetry.sessions(vehicle_id,kind,start_ts,end_ts,start_reason,end_reason,membership,payloads) VALUES (1,'drive',${at(start)},${at(end)},'gear','gear','complete',100)`;
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,latitude,longitude,invalid,quality,payload_id,source_unit)
    SELECT 1,f.field,${at(start)}::timestamptz+i*interval '10 seconds',${at(start)}::timestamptz+i*interval '10 seconds',
      CASE f.field WHEN 'Odometer' THEN ${100+offset}+i*.05 WHEN 'VehicleSpeed' THEN 30 WHEN 'EnergyRemaining' THEN 50-i*.01 WHEN 'Soc' THEN 80-i*.02 END,
      CASE WHEN f.field='Location' THEN 37.7+i*.0001 END,CASE WHEN f.field='Location' THEN -122.4 END,false,'ok',${String(start)}||'-'||i,
      CASE f.field WHEN 'Odometer' THEN 'mi' WHEN 'VehicleSpeed' THEN 'mph' WHEN 'EnergyRemaining' THEN 'kWh' WHEN 'Soc' THEN '%' ELSE '' END
      FROM generate_series(0,${(end-start)/10}::integer) i CROSS JOIN (VALUES ('Location'),('Odometer'),('VehicleSpeed'),('EnergyRemaining'),('Soc')) f(field)`;
}
async function tm(id:number,start:number,end:number){await owner`INSERT INTO drives(id,car_id,start_date,end_date,distance,duration_min) VALUES (${id},1,${at(start)},${at(end)},5,10)`;}
test('API replaces inaccurate overlapping TeslaMate drive and paginates across sources with full telemetry detail',async()=>{
  await tm(1,-1000,-400);await tm(2,300,1000);await tm(3,2000,2600);
  await trip(0,600);await trip(1200,1800,3);
  const first=await get('/v1/vehicles/1/drives?limit=1');expect(first.items[0].id).toBe(3);
  const second=await get(`/v1/vehicles/1/drives?limit=1&cursor=${first.nextCursor}`);const fleet=second.items[0];expect(fleet.id).toBeLessThan(0);
  const third=await get(`/v1/vehicles/1/drives?limit=1&cursor=${second.nextCursor}`);expect(third.items[0].id).toBeLessThan(0);
  const fourth=await get(`/v1/vehicles/1/drives?limit=1&cursor=${third.nextCursor}`);expect(fourth.items[0].id).toBe(1);expect(fourth.nextCursor).toBeNull();
  expect(fleet.route.length).toBeGreaterThan(1);expect(fleet.route.length).toBeLessThanOrEqual(300);
  expect(fleet.distanceKm).toBeCloseTo(3*1.609344);expect(fleet.avgSpeedKph).toBeCloseTo(3*1.609344*6);
  const detail=await get(`/v1/drives/${fleet.id}`);expect(detail.driveScore).toBe(fleet.driveScore);expect(detail.scoreBreakdown).toEqual(fleet.scoreBreakdown);expect(detail.distanceKm).toBe(fleet.distanceKm);
  expect(detail.path[0].speedKph).toBeCloseTo(30*1.609344);expect(detail.path[0].socPct).toBe(80);expect(Number.isInteger(detail.startBatteryLevel)).toBe(true);expect(Number.isInteger(detail.endBatteryLevel)).toBe(true);
  expect(detail.path[0].elevationM).toBeNull();expect(detail.path).toHaveLength(61);expect(detail.path.every((p:any)=>typeof p.latitude==='number' && (p.batteryLevel===null || Number.isInteger(p.batteryLevel)))).toBe(true); // The fixture car identity is deliberately not a VIN.
  const filtered=await get(`/v1/vehicles/1/drives?from=${at(0).toISOString()}&to=${at(1200).toISOString()}`);expect(filtered.items).toHaveLength(1);
  expect(filtered.items[0].startAddress).toBe('Synthetic Home');
  const summary=await get('/v1/vehicles/1/summary?range=today');expect(summary.driveCount).toBe(3);expect(summary.distanceKm).toBeCloseTo(5+6*1.609344);
  const mileage=await get('/v1/vehicles/1/mileage?bucket=day');expect(mileage[0].driveCount).toBe(3);expect(mileage[0].distanceKm).toBeCloseTo(summary.distanceKm);
});
test('binding mismatch and feature disabled retain TeslaMate; isolated manoeuvre drops without truncating pagination',async()=>{
  await tm(1,-1000,-400);await tm(2,300,1000);
  await trip(0,600);await trip(1200,1210,3);
  const rows=await get('/v1/vehicles/1/drives?limit=1');expect(rows.items[0].id).toBeLessThan(0);expect(rows.nextCursor).not.toBeNull();
  const next=await get(`/v1/vehicles/1/drives?limit=1&cursor=${rows.nextCursor}`);expect(next.items[0].id).toBe(1);expect(next.nextCursor).toBeNull();
  await owner`UPDATE volta_telemetry.vehicle_bindings SET vin_digest=repeat('0',64)`;
  const mismatch=await get('/v1/vehicles/1/drives');expect(mismatch.items.map((r:any)=>r.id)).toEqual([2,1]);
  const disabled=await new Telemetry(reader).drives(1,{from:null,to:null,before:null,beforeId:null,limit:10,minMinutes:10});expect(disabled.map(r=>r.id)).toEqual([2,1]);
});
test('short Park resumes join one trip and known disconnect protects uncovered TeslaMate history',async()=>{
  await trip(0,600);await trip(720,1320,3);await trip(1600,2200,7);
  await owner`INSERT INTO volta_telemetry.gaps(vehicle_id,start_ts,end_ts,reason) VALUES (1,${at(1400)},${at(1550)},'disconnected')`;
  await tm(1,1410,1500);
  const list=await get('/v1/vehicles/1/drives');expect(list.items).toHaveLength(3);
  expect(list.items.at(-1).durationMin).toBe(22);expect(list.items[1].id).toBe(1);
});

test('history and detail keep continuous routes across short receiver cadence gaps',async()=>{
  await trip(0,600);
  // The database view marks these short gaps, but they are ordinary receiver
  // cadence rather than lost telemetry. API routes use the resolved loss rule.
  await owner`INSERT INTO volta_telemetry.gaps(vehicle_id,start_ts,end_ts,reason)
    SELECT 1,${at(5)}::timestamptz+i*interval '30 seconds',${at(6)}::timestamptz+i*interval '30 seconds','disconnected'
    FROM generate_series(0,19) i`;
  const list=await get('/v1/vehicles/1/drives'),detail=await get(`/v1/drives/${list.items[0].id}`);
  expect(list.items).toHaveLength(1);
  expect(detail.path).toHaveLength(61);
  expect(detail.path.every((p:any)=>!p.routeBreakBefore)).toBe(true);
  expect(list.items[0].route.every((p:any)=>!p.routeBreakBefore)).toBe(true);
  expect(detail.path[0]).toMatchObject({latitude:37.7,longitude:-122.4,speedKph:30*1.609344,batteryLevel:80,socPct:80});
  expect(detail.distanceKm).toBeCloseTo(3*1.609344);
  const summary=await get('/v1/vehicles/1/summary?range=today');
  expect(summary.distanceKm).toBeCloseTo(detail.distanceKm);
  expect(summary.driveScore).toBeCloseTo(detail.driveScore);
});

test('unmeasurable and truncated telemetry cannot erase a recorded TeslaMate trip',async()=>{
  await tm(1,0,600);await trip(200,600);
  await owner`UPDATE volta_telemetry.sessions SET start_reason='first_observed',membership='partial'`;
  let list=await get('/v1/vehicles/1/drives');expect(list.items.map((r:any)=>r.id)).toEqual([1]);
  await owner`UPDATE volta_telemetry.sessions SET start_ts=${at(0)},start_reason='gear',membership='complete'`;
  await owner`DELETE FROM volta_telemetry.samples`;
  list=await get('/v1/vehicles/1/drives');expect(list.items.map((r:any)=>r.id)).toEqual([1]);
});

test('a replaced long wrong TeslaMate drive cannot suppress a second reconnect trip',async()=>{
  // The reconnect trip follows a stop of more than ten minutes (a shorter one joins).
  await tm(1,0,2000);await trip(-400,900);await trip(1600,2000,7);
  await owner`UPDATE volta_telemetry.sessions SET start_reason='first_observed',membership='partial' WHERE start_ts=${at(1600)}`;
  const list=await get('/v1/vehicles/1/drives');expect(list.items).toHaveLength(2);expect(list.items.every((r:any)=>r.id<0)).toBe(true);
  const one=await get('/v1/vehicles/1/drives?limit=1');
  const two=await get(`/v1/vehicles/1/drives?limit=1&cursor=${one.nextCursor}`);expect(two.items).toHaveLength(1);expect(two.items[0].id).not.toBe(one.items[0].id);expect(two.nextCursor).toBeNull();
});
test('source preference crosses date bounds so adjacent periods and mileage cannot count one trip twice',async()=>{
  await tm(1,-180,600);await trip(60,600);
  await owner`UPDATE volta_telemetry.sessions SET start_reason='first_observed',membership='partial'`;
  const today=await get(`/v1/vehicles/1/drives?from=${at(0).toISOString()}&to=${at(1000).toISOString()}`);expect(today.items).toHaveLength(0);
  const yesterday=await get(`/v1/vehicles/1/drives?from=${at(-1000).toISOString()}&to=${at(0).toISOString()}`);expect(yesterday.items.map((r:any)=>r.id)).toEqual([1]);
  expect((await get('/v1/vehicles/1/summary?range=today')).driveCount).toBe(0);
  const mileage=await get('/v1/vehicles/1/mileage?bucket=day');expect(mileage).toHaveLength(1);expect(mileage[0].driveCount).toBe(1);
});
test('earlier first-observed telemetry ending in Park replaces a late TeslaMate segment extending past it',async()=>{
  await tm(1,420,2160);await trip(0,900);
  await owner`UPDATE volta_telemetry.sessions SET start_reason='first_observed',membership='partial',end_reason='gear'`;
  const list=await get('/v1/vehicles/1/drives');expect(list.items).toHaveLength(1);expect(list.items[0].id).toBeLessThan(0);expect(list.items[0].durationMin).toBe(15);
  expect((await get('/v1/vehicles/1/summary?range=today')).driveCount).toBe(1);
});

test('a hidden joined telemetry window cannot suppress the second TeslaMate trip',async()=>{
  await tm(1,0,1200);await tm(2,1320,3000);await trip(600,1200);await trip(1320,3000,4);
  await owner`UPDATE volta_telemetry.sessions SET start_reason='first_observed',membership='partial' WHERE start_ts=${at(600)}`;
  const list=await get('/v1/vehicles/1/drives');expect(list.items.map((r:any)=>r.id)).toEqual([2,1]);
  const first=await get('/v1/vehicles/1/drives?limit=1');const second=await get(`/v1/vehicles/1/drives?limit=1&cursor=${first.nextCursor}`);
  expect(first.items[0].id).toBe(2);expect(second.items[0].id).toBe(1);expect(second.nextCursor).toBeNull();
  const summary=await get('/v1/vehicles/1/summary?range=today');expect(summary.driveCount).toBe(2);expect(summary.distanceKm).toBe(10);
  const mileage=await get('/v1/vehicles/1/mileage?bucket=day');expect(mileage[0].driveCount).toBe(2);expect(mileage[0].distanceKm).toBe(10);
});
test('totals-only rows recompute efficiency and its score component after the route distance fallback',async()=>{
  await trip(0,600);await owner`DELETE FROM volta_telemetry.samples WHERE field='Odometer'`;
  const fleet=new FleetDrives(reader),catalog=(await fleet.catalog(1))!;
  const full=(await fleet.rows(1,catalog.windows,150,catalog.gaps,false))[0]!;
  const row=(await fleet.rows(1,catalog.windows,150,catalog.gaps,false,true))[0]!;
  expect(row.distanceKm).toBeGreaterThan(0);expect(row.energyUsedKwh).toBeCloseTo(.6);
  expect(row.efficiencyWhPerKm).toBeCloseTo(row.energyUsedKwh*1000/row.distanceKm);expect(row.efficiencyWhPerKm).toBeCloseTo(full.efficiencyWhPerKm);
  expect(row.avgSpeedKph).toBeCloseTo(row.distanceKm*6);
  expect(row.scoreBreakdown).toEqual({efficiency:full.scoreBreakdown.efficiency,smoothness:null,speed:null,acceleration:null});
  expect(row.scoreBreakdown.efficiency).not.toBeNull();expect(row.driveScore).toBe(row.scoreBreakdown.efficiency);
});
test('a 5.5-minute stop with a first-observed resume is one trip; list, summary and mileage share its odometer distance',async()=>{
  await trip(0,600);await trip(930,1110,3);
  await owner`UPDATE volta_telemetry.sessions SET start_reason='first_observed',membership='partial' WHERE start_ts=${at(930)}`;
  // The last change-only odometer report before the start, 13 minutes earlier;
  // the first report inside the trip arrives 10s after the start.
  await owner`DELETE FROM volta_telemetry.samples WHERE field='Odometer' AND source_ts=${at(0)}`;
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id,source_unit)
    VALUES (1,'Odometer',${at(-780)},${at(-780)},99.9,false,'ok','before','mi')`;
  const list=await get('/v1/vehicles/1/drives');expect(list.items).toHaveLength(1);
  const drive=list.items[0];expect(drive.durationMin).toBe(18.5);
  expect(drive.distanceKm).toBeCloseTo(4*1.609344);expect(drive.avgSpeedKph).toBeCloseTo(4*1.609344*60/18.5);
  expect(drive.regenKwh).toBeNull();
  expect(drive.route.filter((p:any)=>p.routeBreakBefore)).toHaveLength(1);
  const summary=await get('/v1/vehicles/1/summary?range=today');expect(summary.driveCount).toBe(1);expect(summary.distanceKm).toBeCloseTo(drive.distanceKm);
  const mileage=await get('/v1/vehicles/1/mileage?bucket=day');expect(mileage[0].driveCount).toBe(1);expect(mileage[0].distanceKm).toBeCloseTo(drive.distanceKm);
  const detail=await get(`/v1/drives/${drive.id}`);expect(detail.distanceKm).toBe(drive.distanceKm);expect(detail).toHaveProperty('regenKwh');
});
test('an endpoint without a geofence or nearby address takes the city of the nearest address within 3 km, never its address',async()=>{
  await trip(0,600);
  await owner`UPDATE geofences SET latitude=37.8 WHERE id=1`;
  await owner`UPDATE addresses SET latitude=37.71,longitude=-122.4,city='Synthetic Bay City' WHERE id=1`;
  let drive=(await get('/v1/vehicles/1/drives')).items[0];
  expect(drive.startCity).toBe('Synthetic Bay City');expect(drive.startAddress).toBeNull();
  expect(drive.endCity).toBe('Synthetic Bay City');expect(drive.endAddress).toBeNull();
  await owner`UPDATE addresses SET latitude=37.74 WHERE id=1`;
  drive=(await get('/v1/vehicles/1/drives')).items[0];expect(drive.startCity).toBeNull();expect(drive.endCity).toBeNull();
  await owner`UPDATE addresses SET latitude=37.7006 WHERE id=1`;
  drive=(await get('/v1/vehicles/1/drives')).items[0];expect(drive.startAddress).toBe('1 Synthetic Street');expect(drive.startCity).toBe('Synthetic Bay City');
});
test('drive detail adds forward-filled charts and DEM elevation for telemetry drives, charts null for TeslaMate',async()=>{
  // Synthetic 3-arc-second tile: terrain rises 10 m per post northwards.
  const dir=mkdtempSync(join(tmpdir(),'volta-dem-')),tile=Buffer.alloc(1201*1201*2);
  for (let r=0;r<1201;r++) for (let c=0;c<1201;c++) tile.writeInt16BE((1200-r)*10,(r*1201+c)*2);
  mkdirSync(join(dir,'N37'));writeFileSync(join(dir,'N37','N37W123.hgt'),tile);
  try {
    const detailed=createApp(auth,telemetry,()=>{},null,null,null,new DriveDetail(reader,new Dem(dir)));
    const read=async(path:string)=>{const r=await detailed.request(path,{headers:{Authorization:`Bearer ${token}`}});expect(r.status).toBe(200);return await r.json() as any;};
    await tm(5,2000,2600);await owner`UPDATE drives SET ascent=30,descent=12 WHERE id=5`;
    await trip(0,600);
    await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id,source_unit) VALUES
      (1,'OutsideTemp',${at(-3600)},${at(-3600)},12,false,'ok','seed-outside','C'),(1,'InsideTemp',${at(-13*3600)},${at(-13*3600)},20,false,'ok','stale-inside','C'),
      (1,'OutsideTemp',${at(300)},${at(300)},13,false,'ok','change-outside','C')`;
    const id=(await get('/v1/vehicles/1/drives')).items.find((r:any)=>r.id<0).id;
    const listed=(await get('/v1/vehicles/1/drives')).items.find((r:any)=>r.id===id);
    expect(listed.charts).toBeUndefined();expect(listed.elevationLossM).toBeUndefined();expect(listed.drivingMin).toBe(10);
    const d=await read(`/v1/drives/${id}`);
    expect(d.id).toBe(id);expect(d.charts.start).toBe(d.start);expect(d.charts.end).toBe(d.end);
    expect(d.charts.series.outsideTempC).toEqual([{t:at(0).toISOString(),v:12},{t:at(300).toISOString(),v:13},{t:at(600).toISOString(),v:13}]);
    expect(d.charts.series.speedKph).toEqual([{t:at(0).toISOString(),v:48.3},{t:at(600).toISOString(),v:48.3}]);
    expect(d.charts.series.energyRemainingKwh).toHaveLength(61);expect(d.charts.series.energyRemainingKwh.at(-1)).toEqual({t:at(600).toISOString(),v:49.4});
    // Seeds older than 12 h, metrics never observed and empty ones are omitted.
    expect(Object.keys(d.charts.series).sort()).toEqual(['elevationM','energyRemainingKwh','outsideTempC','speedKph']);
    expect(d.charts.series.elevationM[0]).toEqual({t:at(0).toISOString(),v:8400});expect(d.charts.series.elevationM.at(-1).t).toBe(at(600).toISOString());
    expect(d.elevationGainM).toBeCloseTo(72,0);expect(d.elevationLossM).toBe(0);
    expect(d.elevationMinM).toBeCloseTo(8400,6);expect(d.elevationMaxM).toBeCloseTo(8472,6);
    const plain=await get(`/v1/drives/${id}`);expect(plain.charts).toBeUndefined(); // no DriveDetail configured
    const noDem=createApp(auth,telemetry,()=>{},null,null,null,new DriveDetail(reader,null));
    const bare=await (await noDem.request(`/v1/drives/${id}`,{headers:{Authorization:`Bearer ${token}`}})).json() as any;
    expect(bare.elevationGainM).toBeNull();expect(bare.elevationLossM).toBeNull();
    expect(bare.elevationMinM).toBeNull();expect(bare.elevationMaxM).toBeNull();expect(bare.charts.series.elevationM).toBeUndefined();
    const legacy=await read('/v1/drives/5');expect(legacy.charts).toBeNull();expect(legacy.elevationGainM).toBe(30);expect(legacy.elevationLossM).toBe(12);
  } finally { rmSync(dir,{recursive:true,force:true}); }
});
test('joined-trip energy from pack power is the same in list, detail, summary and mileage',async()=>{
  await owner`INSERT INTO volta_telemetry.power_calibration(vehicle_id,sign,source,evidence_note) VALUES (1,'discharge_positive','operator_live_gate','synthetic fixture')`;
  await trip(0,600);await trip(930,1110,3);
  await owner`UPDATE volta_telemetry.sessions SET start_reason='first_observed',membership='partial' WHERE start_ts=${at(930)}`;
  // Dense pack power alternating 10/50 kW every 10s; EnergyRemaining only every
  // 20s (always on a 10 kW row) and once reported invalid, so it cannot be used.
  await owner`DELETE FROM volta_telemetry.samples WHERE field='EnergyRemaining' AND extract(epoch FROM source_ts)::integer%20<>0`;
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id,source_unit)
    SELECT 1,f.field,t,t,CASE f.field WHEN 'PackVoltage' THEN 400 ELSE CASE WHEN extract(epoch FROM t)::integer%20=0 THEN 25 ELSE 125 END END,false,'ok','pack-'||extract(epoch FROM t),''
    FROM (SELECT ${at(0)}::timestamptz+i*interval '10 seconds' AS t FROM generate_series(0,111) i) s CROSS JOIN (VALUES ('PackVoltage'),('PackCurrent')) f(field)
    WHERE t<=${at(600)}::timestamptz OR t>=${at(930)}::timestamptz`;
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id,source_unit)
    VALUES (1,'EnergyRemaining',${at(300)},${at(300)},NULL,true,'invalid','bad-energy','kWh'),(1,'EnergyRemaining',${at(1000)},${at(1000)},NULL,true,'invalid','bad-energy-b','kWh')`;
  const list=await get('/v1/vehicles/1/drives');expect(list.items).toHaveLength(1);
  const drive=list.items[0];expect(drive.energySource).toBe('fleet_pack_power');
  expect(drive.energyUsedKwh).toBeCloseTo(30*(600+180)/3600,6);
  expect((await get(`/v1/drives/${drive.id}`)).energyUsedKwh).toBeCloseTo(drive.energyUsedKwh,9);
  expect((await get('/v1/vehicles/1/summary?range=today')).energyUsedKwh).toBeCloseTo(drive.energyUsedKwh,9);
  expect((await get('/v1/vehicles/1/mileage?bucket=day'))[0].energyUsedKwh).toBeCloseTo(drive.energyUsedKwh,9);
});
test('a post-end odometer report counts only after an observed Park, in list and totals',async()=>{
  await trip(0,600);
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id,source_unit)
    VALUES (1,'Odometer',${at(630)},${at(630)},103.5,false,'ok','late','mi')`;
  const parked=(await get('/v1/vehicles/1/drives')).items[0];expect(parked.distanceKm).toBeCloseTo(3.5*1.609344);
  expect((await get('/v1/vehicles/1/summary?range=today')).distanceKm).toBeCloseTo(3.5*1.609344);
  for (const reason of ['gap','open']) {
    await owner`UPDATE volta_telemetry.sessions SET end_reason=${reason}`;
    const row=(await get('/v1/vehicles/1/drives')).items[0];expect(row.distanceKm).toBeCloseTo(3*1.609344);
    expect((await get('/v1/vehicles/1/summary?range=today')).distanceKm).toBeCloseTo(3*1.609344);
  }
});
test('drive detail charts an open drive whose window advanced after the detail was read; a real mismatch has no charts',async()=>{
  await trip(0,600);
  await owner`UPDATE volta_telemetry.sessions SET end_reason='open'`;
  const extras=new DriveDetail(reader,null);
  const id=(await get('/v1/vehicles/1/drives')).items[0].id;
  const detail=JSON.parse(JSON.stringify(await telemetry.drive(id)));
  expect(detail.end).toBe(at(600).toISOString());
  // The open session keeps streaming before the extras read the catalog.
  await owner`UPDATE volta_telemetry.sessions SET end_ts=${at(900)}`;
  const store=new FleetDrives(reader);expect(+(await store.catalog(1))!.windows.find(w=>w.id===id)!.end).toBe(+at(900));
  const d=await extras.extend(detail);
  expect(d.charts).not.toBeNull();expect(new Date(d.charts.start).toISOString()).toBe(detail.start);expect(new Date(d.charts.end).toISOString()).toBe(detail.end);
  expect(new Date(d.charts.series.speedKph.at(-1).t).toISOString()).toBe(detail.end);
  expect((await extras.extend({...detail,start:at(10).toISOString()})).charts).toBeNull();
  expect((await extras.extend({...detail,end:at(1200).toISOString()})).charts).toBeNull();
});
async function distanceParity(){
  const list=(await get('/v1/vehicles/1/drives')).items.filter((r:any)=>r.source==='fleet_telemetry');
  const sum=list.reduce((a:number,r:any)=>a+r.distanceKm,0);
  for (const r of list) expect((await get(`/v1/drives/${r.id}`)).distanceKm).toBeCloseTo(r.distanceKm,9);
  const summary=await get('/v1/vehicles/1/summary?range=today'),mileage=await get('/v1/vehicles/1/mileage?bucket=day');
  expect(summary.driveCount).toBe(list.length);expect(summary.distanceKm).toBeCloseTo(sum,9);
  expect(mileage.reduce((a:number,m:any)=>a+m.driveCount,0)).toBe(list.length);expect(mileage.reduce((a:number,m:any)=>a+m.distanceKm,0)).toBeCloseTo(sum,9);
  return list;
}
for (const stop of [60,120,300]) test(`a complete joined trip without odometer never counts GPS displacement across a ${stop}s parked stop, in list, detail and totals`,async()=>{
  await trip(0,600);await trip(600+stop,780+stop);
  await owner`DELETE FROM volta_telemetry.samples WHERE field='Odometer'`;
  // Session B is parked elsewhere: shift its positions 0.01 degrees east.
  await owner`UPDATE volta_telemetry.samples SET longitude=longitude+.01 WHERE field='Location' AND source_ts>=${at(600+stop)}`;
  const list=await distanceParity();expect(list).toHaveLength(1);
  // 60 + 18 steps of 0.0001 degrees latitude (~11.1 m each); the ~1 km stop edge is excluded.
  expect(list[0].distanceKm).toBeCloseTo(78*6371.0088*.0001*Math.PI/180,2);
});
test('a partial resume whose GPS starts late is measured per session in every path: unknown distance everywhere',async()=>{
  await trip(0,600);await trip(930,1110);
  await owner`DELETE FROM volta_telemetry.samples WHERE field='Odometer'`;
  await owner`UPDATE volta_telemetry.sessions SET start_reason='first_observed',membership='partial' WHERE start_ts=${at(930)}`;
  // Session B's positions start 150s after its start.
  await owner`DELETE FROM volta_telemetry.samples WHERE field='Location' AND source_ts>=${at(930)} AND source_ts<${at(1080)}`;
  const fleet=new FleetDrives(reader),catalog=(await fleet.catalog(1))!;expect(catalog.windows).toHaveLength(1);
  const full=(await fleet.rows(1,catalog.windows,150,catalog.gaps,false))[0]!,totals=(await fleet.rows(1,catalog.windows,150,catalog.gaps,false,true))[0]!;
  expect(full.distanceKm).toBeNull();expect(totals.distanceKm).toBeNull();
  expect(await distanceParity()).toHaveLength(0);
});
test('a complete drive without any eligible GPS edge has unknown distance everywhere and keeps the TeslaMate trip',async()=>{
  await tm(7,0,600);await trip(0,600);
  await owner`DELETE FROM volta_telemetry.samples WHERE field='Odometer' OR (field='Location' AND source_ts NOT IN (${at(0)},${at(600)}))`;
  const fleet=new FleetDrives(reader),catalog=(await fleet.catalog(1))!;
  expect((await fleet.rows(1,catalog.windows,150,catalog.gaps,false))[0]!.distanceKm).toBeNull();
  expect((await fleet.rows(1,catalog.windows,150,catalog.gaps,false,true))[0]!.distanceKm).toBeNull();
  const items=(await get('/v1/vehicles/1/drives')).items;expect(items.map((r:any)=>r.id)).toEqual([7]);
  const summary=await get('/v1/vehicles/1/summary?range=today');expect(summary.driveCount).toBe(1);expect(summary.distanceKm).toBe(5);
  const mileage=await get('/v1/vehicles/1/mileage?bucket=day');expect(mileage[0].driveCount).toBe(1);expect(mileage[0].distanceKm).toBe(5);
});
test('a recorded charge inside a short stop keeps the drives around it separate',async()=>{
  await owner`INSERT INTO volta_telemetry.sessions(vehicle_id,kind,start_ts,end_ts,start_reason,end_reason,membership,payloads) VALUES
    (1,'drive',${at(0)},${at(600)},'gear','gear','complete',100),(1,'drive',${at(900)},${at(1500)},'gear','gear','complete',100)`;
  const fleet=new FleetDrives(reader);
  expect((await fleet.catalog(1))!.windows).toHaveLength(1);
  await owner`INSERT INTO volta_telemetry.sessions(vehicle_id,kind,start_ts,end_ts,start_reason,end_reason,membership,payloads) VALUES
    (1,'charge',${at(630)},${at(870)},'charging','charging','complete',10)`;
  expect((await fleet.catalog(1))!.windows).toHaveLength(2);
});
for (const end of ['gear','open','gap']) test(`touching joined sessions keep the edge from their shared instant (second ends ${end}), with full parity`,async()=>{
  await owner`INSERT INTO volta_telemetry.sessions(vehicle_id,kind,start_ts,end_ts,start_reason,end_reason,membership,payloads) VALUES
    (1,'drive',${at(0)},${at(600)},'gear','gear','complete',100),(1,'drive',${at(600)},${at(1200)},'gear',${end},'complete',100)`;
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,latitude,longitude,invalid,quality,payload_id,source_unit)
    SELECT 1,'Location',${at(0)}::timestamptz+i*interval '10 seconds',${at(0)}::timestamptz+i*interval '10 seconds',NULL,37.7+i*.0001,-122.4,false,'ok','touch-'||i,''
    FROM generate_series(0,120) i`;
  const fleet=new FleetDrives(reader),catalog=(await fleet.catalog(1))!;expect(catalog.windows).toHaveLength(1);expect(catalog.windows[0]!.parts).toHaveLength(2);
  const list=await distanceParity();expect(list).toHaveLength(1);
  // All 120 steps of 0.0001 degrees latitude, including 590->600 and 600->610.
  expect(list[0].distanceKm).toBeCloseTo(120*6371.0088*.0001*Math.PI/180,3);
});

test('operator sign calibration unlocks existing same-payload power and regen without replaying data',async()=>{
  await trip(0,600);
  // The raw current is negative while discharging. The first half discharges;
  // the second half regenerates. Calibration must never be inferred by ingest.
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id,source_unit)
    SELECT 1,f.field,${at(0)}::timestamptz+i*interval '10 seconds',${at(0)}::timestamptz+i*interval '10 seconds',
      CASE f.field WHEN 'PackVoltage' THEN 400 ELSE CASE WHEN i<30 THEN -25 ELSE 25 END END,false,'ok','0-'||i,''
    FROM generate_series(0,60) i CROSS JOIN (VALUES ('PackVoltage'),('PackCurrent')) f(field)`;
  const id=(await get('/v1/vehicles/1/drives')).items[0].id;
  const detailed=createApp(auth,telemetry,()=>{},null,null,null,new DriveDetail(reader,null));
  const read=async()=>await (await detailed.request(`/v1/drives/${id}`,{headers:{Authorization:`Bearer ${token}`}})).json() as any;
  let d=await read();expect(d.regenKwh).toBeNull();expect(d.charts.series.powerKw).toBeUndefined();
  const [before]=await owner`SELECT count(*)::integer AS n FROM volta_telemetry.samples`;
  await owner`INSERT INTO volta_telemetry.power_calibration(vehicle_id,sign,source,evidence_note) VALUES (1,'discharge_negative','operator_live_gate','synthetic verified sign')`;
  d=await read();expect(d.regenKwh).toBeCloseTo((3000+25)/3600,6);
  expect(d.charts.series.powerKw.map((p:any)=>p.v)).toEqual([10,-10,-10]);
  expect(d.path[0].powerKw).toBe(10);expect(d.path.at(-1).powerKw).toBe(-10);
  const [points]=await owner`SELECT count(power_kw)::integer AS n FROM volta_telemetry.drive_points WHERE vehicle_id=1`;
  expect(points!.n).toBe(61);
  const [after]=await owner`SELECT count(*)::integer AS n FROM volta_telemetry.samples`;expect(after!.n).toBe(before!.n);
  await owner`DELETE FROM volta_telemetry.power_calibration`;
  d=await read();expect(d.regenKwh).toBeNull();expect(d.charts.series.powerKw).toBeUndefined();
});
