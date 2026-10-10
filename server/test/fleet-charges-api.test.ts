import { afterAll, beforeEach, expect, spyOn, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { connect } from '../src/db';
import { Telemetry } from '../src/telemetry';
import { FleetCharges } from '../src/fleet-charges';
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
  await owner`UPDATE cars SET vin='5YJ3E1EA0XF000001' WHERE id=1`; // Synthetic VIN-shaped identity for the detail series binding.
  const [car]=await owner`SELECT vin FROM cars WHERE id=1`;
  const digest=createHash('sha256').update('volta-telemetry-vin-binding-v1\0').update(car!.vin).digest('hex');
  await owner`INSERT INTO volta_telemetry.vehicle_bindings(vehicle_id,vin_digest) VALUES (1,${digest})`;
  await owner`UPDATE geofences SET latitude=37.7,longitude=-122.4 WHERE id=1`;
  await owner`UPDATE addresses SET latitude=37.7,longitude=-122.4,city='Synthetic Bay City',road='Synthetic Road',house_number='1' WHERE id=1`;
  // Fixture TeslaMate charges are dated around now(); keep only the synthetic history.
  await owner`DELETE FROM charges`;await owner`DELETE FROM charging_processes`;
  token=(await auth.pair({code:await auth.createPairingCode(),deviceName:'Synthetic charges'})).token;
  // Raw charge session 0-1700s, the next drive at 1800s. Change-only fields.
  await owner`INSERT INTO volta_telemetry.sessions(vehicle_id,kind,start_ts,end_ts,start_reason,end_reason,membership,payloads) VALUES
    (1,'charge',${at(0)},${at(1700)},'charge_state','charge_state','complete',100),(1,'drive',${at(1800)},${at(2400)},'gear','gear','complete',100)`;
  const rows: [number,string,number|null][]=[[-240,'Location',null],[-240,'BatteryLevel',23.5],[-240,'EnergyRemaining',20],[-240,'DCChargingPower',0],[-240,'ACChargingPower',0],
    [-240,'OutsideTemp',12],[2,'DCChargingPower',1],[60,'DCChargingPower',150],[120,'DCChargingPower',196],[600,'BatteryLevel',60],[1500,'DCChargingPower',50],
    [1680,'DCChargingPower',0],[1690,'BatteryLevel',80.4],[1690,'EnergyRemaining',63.26],[1810,'BatteryLevel',79]];
  for (const [s,field,value] of rows) await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,latitude,longitude,invalid,quality,payload_id)
    VALUES (1,${field},${at(s)},${at(s)},${value},${field==='Location' ? 37.7001 : null},${field==='Location' ? -122.4001 : null},false,'ok',${'p'+s})`;
});
afterAll(async()=>{await owner`TRUNCATE volta_telemetry.samples,volta_telemetry.sessions,volta_telemetry.gaps,volta_telemetry.vehicle_bindings`;await Promise.all([owner.end(),reader.end(),authDB.end()]);});
async function get(path:string,status=200){const r=await app.request(path,{headers:{Authorization:`Bearer ${token}`}});expect(r.status).toBe(status);return await r.json() as any;}
async function tm(id:number,start:number,end:number,cost:number|null=null){
  await owner`INSERT INTO charging_processes(id,car_id,position_id,address_id,start_date,end_date,duration_min,charge_energy_added,start_battery_level,end_battery_level,cost)
    VALUES (${id},1,6,1,${at(start)},${at(end)},${Math.round((end-start)/60)},27.5,45,79,${cost})`;
}
test('telemetry charge replaces the overlapping TeslaMate process, paginates across sources, and serves negative-id detail',async()=>{
  await tm(10,420,2000,9.5);await tm(11,-7200,-3600);
  const first=await get('/v1/vehicles/1/charges?limit=1');const c=first.items[0];
  expect(c.id).toBeLessThan(0);expect(c.source).toBe('fleet_telemetry');
  expect(c.start).toBe(at(2).toISOString());expect(c.end).toBe(at(1680).toISOString());
  expect(c.startBatteryLevel).toBe(24);expect(c.endBatteryLevel).toBe(80);expect(c.energyAddedKwh).toBeCloseTo(43.26);
  expect(c.maxPowerKw).toBe(196);expect(c.fastCharger).toBe(true);expect(c.cost).toBe(9.5);expect(c.currency).toBe('USD');
  expect(c.placeName).toBe('Synthetic Home');expect(c.address).toBe('1 Synthetic Street');expect(c.city).toBe('Synthetic Bay City');expect(c.street).toBe('1 Synthetic Road');
  expect(c.latitude).toBe(37.7001);expect(c.energyFromGridKwh).toBeNull();expect(c.energyUsedKwh).toBeNull();expect(c.avgPowerKw).toBeGreaterThan(150);
  // Negative cursor id; TeslaMate 10 is replaced, uncovered 11 remains.
  const second=await get(`/v1/vehicles/1/charges?limit=1&cursor=${first.nextCursor}`);
  expect(second.items.map((r:any)=>r.id)).toEqual([11]);expect(second.items[0].source).toBe('teslamate');expect(second.nextCursor).toBeNull();
  const filtered=await get(`/v1/vehicles/1/charges?from=${at(-60).toISOString()}&to=${at(60).toISOString()}`);expect(filtered.items.map((r:any)=>r.id)).toEqual([c.id]);
  const detail=await get(`/v1/charges/${c.id}`);
  expect(detail.energyAddedKwh).toBe(c.energyAddedKwh);expect(detail.efficiency).toBeNull();expect(detail._cursorStart).toBeUndefined();
  expect(detail.samples.length).toBeGreaterThan(3);expect(detail.samples.length).toBeLessThanOrEqual(2000);
  expect(detail.samples.every((s:any)=>+new Date(s.t)>=+at(2) && +new Date(s.t)<=+at(1680) && (s.batteryLevel===null || Number.isInteger(s.batteryLevel)))).toBe(true);
  expect(detail.samples.find((s:any)=>s.powerKw===196)).toBeTruthy();
  expect(detail.telemetry.source).toBe('fleet_telemetry');expect(detail.telemetry.samples.length).toBeGreaterThan(0);
  expect((await get('/v1/charges/10')).id).toBe(10);
  await get(`/v1/charges/${c.id-1}`,404);await get('/v1/charges/0',400);
  const summary=await get('/v1/vehicles/1/summary?range=today&tz=UTC');expect(summary.chargeCount).toBe(1);expect(summary.energyAddedKwh).toBeCloseTo(43.26);expect(summary.chargeCost).toBe(9.5);
});
test('covered TeslaMate charge hides only without data loss; unmeasurable telemetry and disabled feature keep TeslaMate',async()=>{
  await tm(12,2000,2300);
  expect((await get('/v1/vehicles/1/charges')).items.map((r:any)=>r.source)).toEqual(['fleet_telemetry']);
  await owner`INSERT INTO volta_telemetry.gaps(vehicle_id,start_ts,end_ts,reason) VALUES (1,${at(1990)},${at(2005)},'disconnected'),(1,${at(2100)},${at(2200)},'disconnected')`;
  expect((await get('/v1/vehicles/1/charges')).items.map((r:any)=>r.id).at(0)).toBe(12);
  await tm(13,100,900);await owner`DELETE FROM volta_telemetry.samples WHERE field IN ('DCChargingPower','ACChargingPower')`;
  expect((await get('/v1/vehicles/1/charges')).items.map((r:any)=>r.id)).toEqual([12,13]);
  expect((await new Telemetry(reader).charges(1,{from:null,to:null,before:null,beforeId:null,limit:10,minMinutes:10})).map(r=>r.id)).toEqual([12,13]);
  await owner`UPDATE volta_telemetry.vehicle_bindings SET vin_digest=repeat('0',64)`;
  expect((await get('/v1/vehicles/1/charges')).items.map((r:any)=>r.id)).toEqual([12,13]);
});
const list=async(path='/v1/vehicles/1/charges')=>(await get(path)).items;
async function invalidSample(s:number,field:string){await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id)
  VALUES (1,${field},${at(s)},${at(s)},NULL,true,'invalid',${'i'+s+field})`;}
test('real loss or unknown power inside telemetry keeps the overlapping TeslaMate charge and drops the partial telemetry',async()=>{
  await tm(14,100,1750,4);
  await owner`INSERT INTO volta_telemetry.gaps(vehicle_id,start_ts,end_ts,reason) VALUES (1,${at(700)},${at(1400)},'disconnected')`;
  const rows=await list();expect(rows.map((r:any)=>r.id)).toEqual([14]);expect(rows[0].energyAddedKwh).toBe(27.5);
  const summary=await get('/v1/vehicles/1/summary?range=today&tz=UTC');expect(summary.chargeCount).toBe(1);expect(summary.energyAddedKwh).toBe(27.5);expect(summary.chargeCost).toBe(4);
  // Without a TeslaMate record the partial telemetry is all there is.
  await owner`DELETE FROM charging_processes`;expect((await list()).map((r:any)=>r.source)).toEqual(['fleet_telemetry']);
  await owner`DELETE FROM volta_telemetry.gaps`;await tm(14,100,1750,4);
  expect((await list()).map((r:any)=>r.source)).toEqual(['fleet_telemetry']);
  // Unknown DC power after the last positive reading: the stop is uncertain.
  await invalidSample(1600,'DCChargingPower');expect((await list()).map((r:any)=>r.id)).toEqual([14]);
});
test('each TeslaMate receipt counts once across telemetry fragments and several receipts sum onto one session',async()=>{
  // Split the session where power paused: two fragments, no lost data between.
  await owner`DELETE FROM volta_telemetry.sessions WHERE kind='charge'`;
  await owner`INSERT INTO volta_telemetry.sessions(vehicle_id,kind,start_ts,end_ts,start_reason,end_reason,membership,payloads) VALUES
    (1,'charge',${at(0)},${at(900)},'charge_state','charge_state','complete',50),(1,'charge',${at(900)},${at(1700)},'charge_state','charge_state','complete',50)`;
  await tm(15,100,1750,12);
  const rows=await list();expect(rows.map((r:any)=>r.source)).toEqual(['fleet_telemetry','fleet_telemetry']);
  expect(rows.map((r:any)=>r.cost)).toEqual([null,12]);expect(rows.reduce((s:number,r:any)=>s+(r.cost ?? 0),0)).toBe(12);
  expect((await get(`/v1/charges/${rows[1].id}`)).cost).toBe(12);expect((await get(`/v1/charges/${rows[0].id}`)).cost).toBeNull();
  expect((await get('/v1/vehicles/1/summary?range=today&tz=UTC')).chargeCost).toBe(12);
  // One session spanning two priced processes carries both receipts.
  await owner`DELETE FROM volta_telemetry.sessions WHERE kind='charge'`;await owner`DELETE FROM charging_processes`;
  await owner`INSERT INTO volta_telemetry.sessions(vehicle_id,kind,start_ts,end_ts,start_reason,end_reason,membership,payloads) VALUES (1,'charge',${at(0)},${at(1700)},'charge_state','charge_state','complete',100)`;
  await tm(16,100,800,5);await tm(17,900,1600,7);
  const one=await list();expect(one).toHaveLength(1);expect(one[0].cost).toBe(12);
  expect((await get(`/v1/charges/${one[0].id}`)).cost).toBe(12);expect((await get('/v1/vehicles/1/summary?range=today&tz=UTC')).chargeCost).toBe(12);
});
test('a telemetry cursor stays valid when the TeslaMate fallback takes over',async()=>{
  await tm(11,-7200,-3600);
  const first=await get('/v1/vehicles/1/charges?limit=1');expect(first.items[0].id).toBeLessThan(0);
  await owner`UPDATE volta_telemetry.vehicle_bindings SET vin_digest=repeat('0',64)`;
  expect((await get(`/v1/vehicles/1/charges?limit=1&cursor=${first.nextCursor}`)).items.map((r:any)=>r.id)).toEqual([11]);
});
test('an open telemetry session without an observed stop cannot replace TeslaMate',async()=>{
  await tm(22,100,1750,3);
  await owner`UPDATE volta_telemetry.sessions SET end_reason='open' WHERE kind='charge'`;
  await owner`DELETE FROM volta_telemetry.samples WHERE field='DCChargingPower' AND source_ts=${at(1680)}`;
  expect((await list()).map((r:any)=>r.id)).toEqual([22]);
});
test('a failed sibling hydration keeps the shared TeslaMate process',async()=>{
  await owner`DELETE FROM volta_telemetry.sessions WHERE kind='charge'`;
  await owner`INSERT INTO volta_telemetry.sessions(vehicle_id,kind,start_ts,end_ts,start_reason,end_reason,membership,payloads) VALUES
    (1,'charge',${at(0)},${at(900)},'charge_state','charge_state','complete',50),(1,'charge',${at(900)},${at(1700)},'charge_state','charge_state','complete',50)`;
  await tm(15,100,1750,12);
  const real=FleetCharges.prototype.row,spy=spyOn(FleetCharges.prototype,'row').mockImplementation(function(this:any,v:number,w:any,...rest:any[]){
    if (+w.start===+at(900)) return Promise.reject(new Error('timeout'));return (real as any).call(this,v,w,...rest);});
  try { expect((await list()).map((r:any)=>r.id)).toEqual([15]); } finally { spy.mockRestore(); }
});
test('an old open TeslaMate process neither joins every later charge nor gets hidden',async()=>{
  await owner`INSERT INTO charging_processes(id,car_id,position_id,address_id,start_date,charge_energy_added) VALUES (20,1,6,1,${at(-100000)},5)`;
  await owner`INSERT INTO charges(id,date,charge_energy_added,charger_power,ideal_battery_range_km,charging_process_id) VALUES (900,${at(-99000)},5,11,300,20)`;
  for (let k=1;k<=5;k++) {
    const s=-90000+k*10000;
    await owner`INSERT INTO volta_telemetry.sessions(vehicle_id,kind,start_ts,end_ts,start_reason,end_reason,membership,payloads) VALUES (1,'charge',${at(s)},${at(s+600)},'charge_state','charge_state','complete',10)`;
    for (const [t,v] of [[s,11],[s+600,0]] as const) await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id)
      VALUES (1,'ACChargingPower',${at(t)},${at(t)},${v},false,'ok',${'o'+t})`;
  }
  const spy=spyOn(FleetCharges.prototype,'row');
  try {
    const page=await get('/v1/vehicles/1/charges?limit=1');expect(page.items[0].id).toBeLessThan(0);
    expect(spy.mock.calls.length).toBeLessThanOrEqual(2);
  } finally { spy.mockRestore(); }
  expect((await list()).map((r:any)=>r.id)).toContain(20);
});
