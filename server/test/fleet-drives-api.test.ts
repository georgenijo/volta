import { afterAll, beforeEach, expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { connect } from '../src/db';
import { Telemetry } from '../src/telemetry';
import { FleetDrives } from '../src/fleet-drives';
import { Auth } from '../src/auth';
import { createApp } from '../src/app';
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
  await trip(0,600);await trip(1200,1800,4);
  const first=await get('/v1/vehicles/1/drives?limit=1');expect(first.items[0].id).toBe(3);
  const second=await get(`/v1/vehicles/1/drives?limit=1&cursor=${first.nextCursor}`);const fleet=second.items[0];expect(fleet.id).toBeLessThan(0);
  const third=await get(`/v1/vehicles/1/drives?limit=1&cursor=${second.nextCursor}`);expect(third.items[0].id).toBeLessThan(0);
  const fourth=await get(`/v1/vehicles/1/drives?limit=1&cursor=${third.nextCursor}`);expect(fourth.items[0].id).toBe(1);expect(fourth.nextCursor).toBeNull();
  expect(fleet.route.length).toBeGreaterThan(1);expect(fleet.route.length).toBeLessThanOrEqual(64);
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
  await trip(0,600);await trip(1200,1210,4);
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

test('unmeasurable and truncated telemetry cannot erase a recorded TeslaMate trip',async()=>{
  await tm(1,0,600);await trip(200,600);
  await owner`UPDATE volta_telemetry.sessions SET start_reason='first_observed',membership='partial'`;
  let list=await get('/v1/vehicles/1/drives');expect(list.items.map((r:any)=>r.id)).toEqual([1]);
  await owner`UPDATE volta_telemetry.sessions SET start_ts=${at(0)},start_reason='gear',membership='complete'`;
  await owner`DELETE FROM volta_telemetry.samples`;
  list=await get('/v1/vehicles/1/drives');expect(list.items.map((r:any)=>r.id)).toEqual([1]);
});

test('a replaced long wrong TeslaMate drive cannot suppress a second reconnect trip',async()=>{
  await tm(1,0,2000);await trip(-400,900);await trip(1200,2000,10);
  await owner`UPDATE volta_telemetry.sessions SET start_reason='first_observed',membership='partial' WHERE start_ts=${at(1200)}`;
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
