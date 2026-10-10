import { afterAll, beforeEach, expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { connect } from '../src/db';
import { Auth } from '../src/auth';
import { FleetSeries } from '../src/fleet-series';
import { Telemetry } from '../src/telemetry';
import { createApp } from '../src/app';

const url=process.env.TEST_DATABASE_URL;
if (!url || new URL(url).pathname!=='/volta_test' || !['localhost','127.0.0.1'].includes(new URL(url).hostname)) throw new Error('Isolated volta_test database required');
const owner=connect(url),reader=connect(process.env.TESLAMATE_DATABASE_URL!,true),authDB=connect(process.env.AUTH_DATABASE_URL!);
const vin='5YJ3E1EA0XF000001';
const digest=createHash('sha256').update('volta-telemetry-vin-binding-v1\0').update(vin).digest('hex');
const auth=new Auth(authDB),app=createApp(auth,new Telemetry(reader,'USD',undefined,true),()=>{});
let start:Date,chargeStart:Date,token:string;
beforeEach(async()=>{
  await owner`TRUNCATE volta_telemetry.latest_samples,volta_telemetry.connectivity,volta_telemetry.stream_health,volta_telemetry.samples,volta_telemetry.gaps,volta_telemetry.power_calibration,volta_telemetry.vehicle_bindings`;
  await owner`TRUNCATE public.charges,public.charging_processes,public.positions,public.drives,public.states,public.updates,public.cars,public.car_settings,public.addresses,public.geofences,volta.devices,volta.pairing_codes,volta.rate_limits RESTART IDENTITY CASCADE`;
  await owner.file(new URL('fixtures.sql',import.meta.url));
  await owner`UPDATE cars SET vin=${vin} WHERE id=1`;
  await owner`INSERT INTO volta_telemetry.vehicle_bindings(vehicle_id,vin_digest) VALUES (1,${digest})`;
  start=(await owner`SELECT start_date FROM drives WHERE id=1`)[0]!.start_date;
  chargeStart=(await owner`SELECT start_date FROM charging_processes WHERE id=1`)[0]!.start_date;
  token=(await auth.pair({code:await auth.createPairingCode(),deviceName:'Synthetic telemetry'})).token;
});
afterAll(async()=>{await Promise.all([owner.end(),reader.end(),authDB.end()]);});
const get=async(path:string)=>{
  const r=await app.request(path,{headers:{Authorization:`Bearer ${token}`}});
  expect(r.status).toBe(200);return await r.json() as any;
};
const at=(seconds:number,base=start)=>new Date(+base+seconds*1000);
async function datum(field:string,n:number|null,t=start,payload='p1',vehicle=1,location:{latitude:number,longitude:number}|null=null,invalid=false){
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,latitude,longitude,invalid,quality,payload_id)
    VALUES (${vehicle},${field},${t},${t},${n},${location?.latitude??null},${location?.longitude??null},${invalid},${invalid?'invalid':'ok'},${payload})`;
}

test('exact vehicle binding is required; disabled and historical APIs preserve sparse data',async()=>{
  expect(digest).toBe('1805a6f5184419493be9727a11fc7b3576f2647ef7dcf2c8d591d00a84adfd7f');
  await datum('VehicleSpeed',20);
  expect((await get('/v1/drives/1')).telemetry.samples[0].speedKph).toBeCloseTo(32.18688);
  await owner`UPDATE cars SET vin='5YJ3E1EA0XF000002' WHERE id=1`;
  const mismatch=await get('/v1/drives/1');expect(mismatch.telemetry).toBeNull();expect(mismatch.path).toHaveLength(3);
  const legacy=await new Telemetry(reader).drive(1);expect(legacy).not.toHaveProperty('telemetry');expect(legacy.path).toHaveLength(3);
});

test('dense series is co-timed, metric, bounded to the vehicle and drive; slow data needs no GPS',async()=>{
  for(let i=0;i<12;i++){
    const t=at(i*2),p=`p${i}`;
    await datum('Location',null,t,p,1,{latitude:40,longitude:-74});
    await datum('VehicleSpeed',30+i,t,p);
    await datum('PackVoltage',400,t,p);await datum('PackCurrent',20,t,p);
    await datum('BatteryLevel',80,t,p);
  }
  await datum('EnergyRemaining',42.5,at(30),'slow');await datum('ModuleTempMin',22,at(30),'slow');await datum('ModuleTempMax',25,at(30),'slow');
  await datum('InsideTemp',0,at(30),'slow');await datum('OutsideTemp',-5,at(30),'slow');
  await datum('LongitudinalAcceleration',.5,start,'p0');await datum('LateralAcceleration',-.2,start,'p0');
  await datum('VehicleSpeed',99,at(-1),'before');await datum('VehicleSpeed',99,at(3601),'after');await datum('VehicleSpeed',99,start,'other',2);
  let detail=await get('/v1/drives/1');
  expect(detail.telemetry.source).toBe('fleet_telemetry');expect(detail.telemetry.samples).toHaveLength(13);expect(detail.telemetry.truncated).toBe(false);
  expect(detail.telemetry.samples[0].powerKw).toBeNull(); // Sign cannot be guessed from charging.
  expect(detail.telemetry.samples[0].longitudinalAccelerationMps2).toBe(.5);expect(detail.telemetry.samples[0].lateralAccelerationMps2).toBe(-.2);
  expect(detail.telemetry.samples[0].elevationM).toBe(10); // Same private SRTM location/time.
  expect(detail.telemetry.samples.at(-1)).toMatchObject({latitude:null,energyRemainingKwh:42.5,batteryTempMinC:22,batteryTempMaxC:25,insideTempC:0,outsideTempC:-5});
  await owner`INSERT INTO volta_telemetry.power_calibration(vehicle_id,sign,source,evidence_note) VALUES (1,'discharge_positive','operator_live_gate','synthetic fixture')`;
  detail=await get('/v1/drives/1');expect(detail.telemetry.samples[0].powerKw).toBe(8);
});

test('conflicting values are unknown, and electricity never pairs across separate payloads',async()=>{
  await datum('VehicleSpeed',10,start,'a');await datum('VehicleSpeed',20,start,'b');
  await datum('PackVoltage',400,start,'a');await datum('PackCurrent',30,start,'b');
  await datum('EnergyRemaining',40,start,'a');await datum('EnergyRemaining',null,start,'b',1,null,true);
  await owner`INSERT INTO volta_telemetry.power_calibration(vehicle_id,sign,source,evidence_note) VALUES(1,'discharge_positive','operator_live_gate','test')`;
  const p=(await get('/v1/drives/1')).telemetry.samples[0];
  expect(p.speedKph).toBeNull();expect(p.powerKw).toBeNull();expect(p.energyRemainingKwh).toBeNull();
  expect(p.invalidFields).toContain('VehicleSpeed');expect(p.invalidFields).toContain('EnergyRemaining');
});

test('real data loss breaks GPS, cadence jitter does not; distant SRTM coordinates stay unknown',async()=>{
  await datum('Location',null,start,'a',1,{latitude:40,longitude:-74});
  await datum('Location',null,at(100),'b',1,{latitude:42,longitude:-72});
  await owner`INSERT INTO volta_telemetry.gaps(vehicle_id,start_ts,end_ts,reason)
    SELECT 1,${start}::timestamptz+n*interval '0.5 second',${start}::timestamptz+(n+1)*interval '0.5 second','disconnected' FROM generate_series(0,19) n`;
  expect((await get('/v1/drives/1')).telemetry.samples[1].routeBreakBefore).toBe(false);
  await owner`INSERT INTO volta_telemetry.gaps(vehicle_id,start_ts,end_ts,reason) VALUES(1,${at(10.2)},${at(100.2)},'disconnected')`;
  const telemetry=(await get('/v1/drives/1')).telemetry;
  expect(telemetry.samples[0].routeBreakBefore).toBe(false);expect(telemetry.samples[1].routeBreakBefore).toBe(true);
  expect(telemetry.samples[1].elevationM).toBeNull();expect(telemetry.gaps).toHaveLength(1);
  expect(telemetry.coverage.metrics.latitude).toMatchObject({sourceSampleCount:2,returnedSampleCount:2,gapCount:1,downsampled:false,truncated:false});
  expect(telemetry.coverage.metrics.latitude.densityPerMinute).toBeCloseTo(2/60);
  expect(telemetry.coverage.metrics.latitude.maxIntervalSeconds).toBe(100);
});

test('conflicting electrical inputs cannot become known power even when their products coincide',async()=>{
  await datum('PackVoltage',400,start,'a');await datum('PackCurrent',10,start,'a');
  await datum('PackVoltage',200,start,'b');await datum('PackCurrent',20,start,'b');
  await owner`INSERT INTO volta_telemetry.power_calibration(vehicle_id,sign,source,evidence_note) VALUES(1,'discharge_positive','operator_live_gate','test')`;
  const point=(await get('/v1/drives/1')).telemetry.samples[0];
  expect(point.powerKw).toBeNull();expect(point.invalidFields).toContain('Power');
  expect((await get('/v1/drives/1')).telemetry.coverage.metrics.powerKw).toBeUndefined();
});

test('charge series uses recorded charging power and temperatures, with null for missing fields',async()=>{
  await datum('ACChargingPower',11,chargeStart);await datum('EnergyRemaining',48,chargeStart);await datum('RatedRange',200,chargeStart);
  await datum('BatteryLevel',70,chargeStart);await datum('ChargerVoltage',230,chargeStart);await datum('ChargeAmps',16,chargeStart);
  const d=await get('/v1/charges/1');expect(d.samples).toHaveLength(2);
  expect(d.telemetry.samples[0]).toMatchObject({powerKw:11,energyRemainingKwh:48,batteryLevel:70,voltage:230,currentA:16,batteryTempMinC:null,elevationM:null});
  expect(d.telemetry.samples[0].ratedRangeKm).toBeCloseTo(321.8688);
});

test('invalid DC power and zero AC power stay unknown and disclose invalid Power',async()=>{
  await datum('ACChargingPower',0,chargeStart,'ac');
  await datum('DCChargingPower',null,chargeStart,'dc',1,null,true);
  const telemetry=(await get('/v1/charges/1')).telemetry;
  expect(telemetry.samples[0].powerKw).toBeNull();
  expect(telemetry.samples[0].invalidFields).toEqual(expect.arrayContaining(['DCChargingPower','Power']));
  expect(telemetry.coverage.metrics.powerKw).toBeUndefined();
});

test('charge power uses the valid alternate input without turning its raw invalid peer into a Power gap',async()=>{
  await datum('ACChargingPower',7.2,chargeStart,'ac-valid');
  await datum('DCChargingPower',null,chargeStart,'dc-invalid',1,null,true);
  await datum('DCChargingPower',150,at(1,chargeStart),'dc-valid');
  await datum('ACChargingPower',null,at(1,chargeStart),'ac-invalid',1,null,true);
  const telemetry=(await get('/v1/charges/1')).telemetry;
  expect(telemetry.samples.map((p:any)=>p.powerKw)).toEqual([7.2,150]);
  expect(telemetry.samples[0].invalidFields).toContain('DCChargingPower');
  expect(telemetry.samples[1].invalidFields).toContain('ACChargingPower');
  expect(telemetry.samples.every((p:any)=>!p.invalidFields.includes('Power'))).toBe(true);
  expect(telemetry.coverage.metrics.powerKw).toMatchObject({
    sourceSampleCount:2,returnedSampleCount:2,invalidGapCount:0,gapCount:0,downsampled:false,truncated:false,
  });
});

test('large histories cover the whole session and retain every metric boundary and extrema',async()=>{
  await owner`UPDATE drives SET end_date=start_date+interval '8 hours' WHERE id=1`;
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id)
    SELECT 1,'VehicleSpeed',${start}::timestamptz+n*interval '1 second',${start},
      CASE n WHEN 12345 THEN 999 WHEN 12346 THEN 1 ELSE 10+n%100 END,false,'ok','speed'||n
    FROM generate_series(0,25000) n`;
  await datum('VehicleSpeed',null,at(7777),'invalid-speed',1,null,true);
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id)
    SELECT 1,'BatteryLevel',${start}::timestamptz+n*interval '1 second',${start},value,false,'ok','battery'||n
    FROM (VALUES (100,55),(10000,1),(20000,99),(24900,56)) AS v(n,value)`;
  const t=(await get('/v1/drives/1')).telemetry;
  expect(t.samples.length).toBeLessThanOrEqual(2000);expect(t.samples.length).toBeGreaterThan(1900);
  expect(t.downsampled).toBe(true);expect(t.truncated).toBe(false);
  expect(t.coverage).toMatchObject({sourceSampleCount:25001,returnedSampleCount:t.samples.length});
  expect(Date.parse(t.coverage.sampleStart)).toBe(+start);expect(Date.parse(t.coverage.sampleEnd)).toBe(+at(25000));
  expect(Date.parse(t.samples[0].t)).toBe(+start);expect(Date.parse(t.samples.at(-1).t)).toBe(+at(25000));
  expect(t.samples.map((p:any)=>p.speedKph)).toEqual(expect.arrayContaining([999*1.609344,1*1.609344]));
  expect(t.samples.filter((p:any)=>[7776,7777,7778].includes((Date.parse(p.t)-+start)/1000)).map((p:any)=>p.speedKph))
    .toEqual([86*1.609344,null,88*1.609344]);
  const battery=t.samples.filter((p:any)=>p.batteryLevel!=null);
  expect(battery.map((p:any)=>p.batteryLevel)).toEqual([55,1,99,56]);
  expect(battery.map((p:any)=>Date.parse(p.t))).toEqual([100,10000,20000,24900].map(n=>+at(n)));
  expect(t.coverage.metrics.speedKph).toMatchObject({sourceSampleCount:25000,downsampled:true,truncated:false,gapCount:1,invalidGapCount:1,receiverGapCount:0});
  expect(t.coverage.metrics.batteryLevel).toMatchObject({sourceSampleCount:4,returnedSampleCount:4,downsampled:false,truncated:false});
  await expect((async()=>await reader`SELECT raw FROM volta_telemetry.records`)()).rejects.toMatchObject({code:'42501'});
  await expect((async()=>await reader`DELETE FROM volta_telemetry.samples`)()).rejects.toThrow();
},30000);

test('time buckets cover a sparse tail instead of spending the budget on a short dense burst',async()=>{
  await owner`UPDATE drives SET end_date=start_date+interval '11 minutes' WHERE id=1`;
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id)
    SELECT 1,'VehicleSpeed',${start}::timestamptz+n*interval '1 millisecond',${start},20+n%100,false,'ok','dense'||n
    FROM generate_series(0,10000) n`;
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id)
    SELECT 1,'VehicleSpeed',${start}::timestamptz+n*interval '1 second',${start},200+n,false,'ok','sparse'||n
    FROM generate_series(11,610) n`;
  const telemetry=(await get('/v1/drives/1')).telemetry;
  const seconds=telemetry.samples.map((p:any)=>(Date.parse(p.t)-+start)/1000);
  const dense=seconds.filter((n:number)=>n<=10),sparse=seconds.filter((n:number)=>n>=11);
  expect(telemetry.coverage).toMatchObject({sourceSampleCount:10601,returnedSampleCount:telemetry.samples.length});
  expect(telemetry.samples.length).toBeLessThanOrEqual(2000);expect(telemetry.downsampled).toBe(true);
  expect(dense.length).toBeLessThanOrEqual(40);
  expect(sparse).toEqual(Array.from({length:600},(_,i)=>i+11));
  expect(seconds.at(-1)).toBe(610);
},30000);

test('downsampled time buckets retain staggered sparse temperature and energy observations',async()=>{
  await owner`UPDATE drives SET end_date=start_date+interval '4 hours' WHERE id=1`;
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id)
    SELECT 1,'VehicleSpeed',${start}::timestamptz+n*interval '1 second',${start},20+n%100,false,'ok','speed'||n
    FROM generate_series(0,14400) n`;
  // Slow fields arrive on different rows from both the 1 Hz signal and each
  // other. Picking only the first row in a bucket loses their actual cadence.
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id)
    SELECT 1,field,${start}::timestamptz+n*interval '1 minute'+offset_seconds*interval '1 second',
      ${start},20+n%7,false,'ok',field||n
    FROM generate_series(0,239) n
      CROSS JOIN (VALUES ('ModuleTempMin',17.4),('InsideTemp',23.6),('EnergyRemaining',29.7)) AS metric(field,offset_seconds)`;
  const telemetry=(await get('/v1/drives/1')).telemetry;
  expect(telemetry.downsampled).toBe(true);expect(telemetry.truncated).toBe(false);
  expect(telemetry.samples.length).toBeLessThanOrEqual(2000);
  expect(telemetry.coverage.sourceSampleCount).toBe(15121);
  for(const [metric,offset] of [['batteryTempMinC',17.4],['insideTempC',23.6],['energyRemainingKwh',29.7]] as const){
    const points=telemetry.samples.filter((p:any)=>p[metric]!=null);
    expect(points.map((p:any)=>Date.parse(p.t))).toEqual(Array.from({length:240},(_,n)=>+at(n*60+offset)));
    expect(telemetry.coverage.metrics[metric]).toMatchObject({
      sourceSampleCount:240,returnedSampleCount:240,maxIntervalSeconds:60,returnedMaxIntervalSeconds:60,
      gapCount:0,downsampled:false,truncated:false,
    });
  }
},30000);

test('an invalid-break set larger than the response budget fails closed for that metric',async()=>{
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id)
    SELECT 1,'VehicleSpeed',${start}::timestamptz+n*interval '1 second',${start},
      CASE WHEN n%2=0 THEN 20 END,n%2=1,CASE WHEN n%2=1 THEN 'invalid' ELSE 'ok' END,'alternating'||n
    FROM generate_series(0,3000) n`;
  const telemetry=(await get('/v1/drives/1')).telemetry;
  expect(telemetry.samples.length).toBeLessThanOrEqual(2000);
  expect(telemetry.coverage.metrics.speedKph).toMatchObject({
    sourceSampleCount:1501,invalidGapCount:1500,gapCount:1500,downsampled:true,truncated:true,
  });
});

test('gap truncation is disclosed globally and for each intersected metric',async()=>{
  await owner`UPDATE drives SET end_date=start_date+interval '3 days' WHERE id=1`;
  await datum('VehicleSpeed',10,start,'first');await datum('VehicleSpeed',20,at(190000),'last');
  await owner`INSERT INTO volta_telemetry.gaps(vehicle_id,start_ts,end_ts,reason)
    SELECT 1,${start}::timestamptz+n*interval '92 seconds',
      ${start}::timestamptz+n*interval '92 seconds'+interval '90 seconds','disconnected'
    FROM generate_series(1,2001) n`;
  const telemetry=(await get('/v1/drives/1')).telemetry;
  expect(telemetry.gaps).toHaveLength(2000);expect(telemetry.truncated).toBe(true);
  expect(telemetry.coverage.metrics.speedKph).toMatchObject({gapCount:2001,truncated:true});
});

test('Fleet series query errors preserve detail and log only a fixed code',async()=>{
  const privateText='secret SQL and values';
  const broken=new Proxy(reader as any,{apply(target,thisArg,args:any[]){
    const query=Array.isArray(args[0]) ? args[0].join('') : '';
    if(query.includes('volta_telemetry.api_vehicle_bindings')) return Promise.reject(new Error(privateText));
    return Reflect.apply(target,thisArg,args);
  }}) as typeof reader;
  const logs:object[]=[];
  const telemetry=new Telemetry(broken,'USD',undefined,true,entry=>logs.push(entry));
  const drive=await telemetry.drive(1),charge=await telemetry.charge(1);
  expect(drive.path).toHaveLength(3);expect(drive.telemetry).toBeNull();
  expect(charge.samples).toHaveLength(2);expect(charge.telemetry).toBeNull();
  expect(logs).toEqual([
    {event:'fleet_series_failed',code:'telemetry_query_failed'},
    {event:'fleet_series_failed',code:'telemetry_query_failed'},
  ]);
  expect(JSON.stringify(logs)).not.toContain(privateText);
});

test('one-hour mixed-cadence drive is served before ANALYZE',async()=>{
  await owner`UPDATE drives SET end_date=start_date+interval '1 hour' WHERE id=1`;
  await owner`INSERT INTO volta_telemetry.power_calibration(vehicle_id,sign,source,evidence_note)
    VALUES(1,'discharge_positive','operator_live_gate','synthetic fixture')`;
  // 1 Hz speed, pack and GPS; three 10 s and four 60 s fields, each offset so
  // timestamps rarely coincide. Before ANALYZE the planner sees a tiny table.
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,latitude,longitude,invalid,quality,payload_id)
    SELECT 1,m.field,${start}::timestamptz+(n*m.every+m.offset_ms/1000.0)*interval '1 second',${start},
      CASE WHEN m.field='Location' THEN NULL WHEN m.field='PackVoltage' THEN 400 ELSE 20+n%50 END,
      CASE WHEN m.field='Location' THEN 37.4+n/1e5 END,CASE WHEN m.field='Location' THEN -122.1+n/1e5 END,
      false,'ok','mixed'||m.offset_ms||'-'||n
    FROM (VALUES ('VehicleSpeed',1,0),('PackVoltage',1,0),('PackCurrent',1,0),('Location',1,250),
      ('BatteryLevel',10,100),('EnergyRemaining',10,350),('RatedRange',10,700),
      ('InsideTemp',60,150),('OutsideTemp',60,450),('ModuleTempMin',60,650),('ModuleTempMax',60,850))
      AS m(field,every,offset_ms)
    CROSS JOIN LATERAL generate_series(0,3600/m.every-1) n`;
  const started=Date.now();
  const telemetry=(await get('/v1/drives/1')).telemetry;
  expect(Date.now()-started).toBeLessThan(5000);
  expect(telemetry).not.toBeNull();
  expect(telemetry.coverage.sourceSampleCount).toBeGreaterThan(7000);
  expect(telemetry.samples.map((p:any)=>p.powerKw)).toContain(8);
},30000);

test('eight-hour co-timed electrical history has identical selection and coverage before and after ANALYZE',async()=>{
  await owner`UPDATE drives SET end_date=start_date+interval '8 hours' WHERE id=1`;
  await owner`INSERT INTO volta_telemetry.power_calibration(vehicle_id,sign,source,evidence_note)
    VALUES(1,'discharge_positive','operator_live_gate','synthetic fixture')`;
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id)
    SELECT 1,field,${start}::timestamptz+n*interval '1 second',${start},
      CASE field WHEN 'VehicleSpeed' THEN 20+n%100 WHEN 'PackVoltage' THEN 400 ELSE 20+n%50 END,
      false,'ok','electrical'||n
    FROM generate_series(0,28800) n
      CROSS JOIN (VALUES ('VehicleSpeed'),('PackVoltage'),('PackCurrent')) AS metric(field)`;
  // Read the bulk insert before updating statistics: the query must not
  // depend on autovacuum having caught up, including its power-series view.
  const before=(await get('/v1/drives/1')).telemetry;
  expect(before.samples.length).toBeLessThanOrEqual(2000);
  expect(before.samples.length).toBeGreaterThan(1900);
  expect(before.coverage.sourceSampleCount).toBe(28801);
  expect(Date.parse(before.samples[0].t)).toBe(+start);
  expect(Date.parse(before.samples.at(-1).t)).toBe(+at(28800));
  expect(before.samples.map((p:any)=>p.powerKw)).toEqual(expect.arrayContaining([8,27.6]));
  expect(before.coverage.metrics.powerKw).toMatchObject({sourceSampleCount:28801,downsampled:true,truncated:false});
  await owner`ANALYZE volta_telemetry.samples`;
  expect((await get('/v1/drives/1')).telemetry).toEqual(before);
},30000);

test('live status uses exact binding, change-only security and tire units; mismatch falls back',async()=>{
  await owner`TRUNCATE volta_telemetry.latest_samples,volta_telemetry.connectivity,volta_telemetry.stream_health`;
  const t=new Date();
  await owner`INSERT INTO volta_telemetry.latest_samples(vehicle_id,field,source_ts,received_at,value_bool,invalid,quality,payload_id)
    VALUES(1,'Locked',${t},${t},true,false,'ok','live-fixture')`;
  await owner`INSERT INTO volta_telemetry.latest_samples(vehicle_id,field,source_ts,received_at,value_num,source_unit,invalid,quality,payload_id)
    VALUES(1,'TpmsPressureFl',${t},${t},2.9,'bar',false,'ok','live-fixture')`;
  let status=await get('/v1/vehicles/1/status');
  expect(status.locked).toBe(true);expect(status.tpms.fl.pressureBar).toBe(2.9);expect(status.telemetryFreshness.connected).toBe(false);
  await owner`UPDATE cars SET vin='5YJ3E1EA0XF000002' WHERE id=1`;
  status=await get('/v1/vehicles/1/status');expect(status.locked).toBeNull();expect(status.tpms).toBeUndefined();
  await owner`TRUNCATE volta_telemetry.latest_samples,volta_telemetry.connectivity,volta_telemetry.stream_health`;
});

test('telemetry-only battery supports vehicle selection and a backward-compatible status timestamp',async()=>{
  await owner`TRUNCATE volta_telemetry.latest_samples,volta_telemetry.connectivity,volta_telemetry.stream_health`;
  await owner`UPDATE positions SET battery_level=NULL WHERE car_id=1`;
  await owner`UPDATE charging_processes SET end_date=now() AT TIME ZONE 'UTC' WHERE car_id=1`;
  const t=new Date();
  await owner`INSERT INTO volta_telemetry.latest_samples(vehicle_id,field,source_ts,received_at,value_num,source_unit,invalid,quality,payload_id)
    VALUES(1,'BatteryLevel',${t},${t},72.4,'%',false,'ok','live-battery')`;
  const vehicles=await get('/v1/vehicles');
  expect(vehicles.find((v:any)=>v.id===1).hasData).toBe(true);
  const status=await get('/v1/vehicles/1/status');expect(status.batteryLevel).toBe(72);expect(status.updatedAt).toBeDefined();
  await owner`TRUNCATE volta_telemetry.latest_samples,volta_telemetry.connectivity,volta_telemetry.stream_health`;
});


test('live overlapping metrics prefer connected change-only data, otherwise compare per-field time',async()=>{
  const now=new Date(),old=new Date('2000-01-01T00:00:00Z');
  await owner`INSERT INTO volta_telemetry.latest_samples(vehicle_id,field,source_ts,received_at,value_num,source_unit,invalid,quality,payload_id)
    VALUES(1,'InsideTemp',${old},${old},38,'C',false,'ok','old-temp')`;
  const fallback=await new Telemetry(reader).status(1);
  expect((await get('/v1/vehicles/1/status')).insideTempC).toBe(fallback.insideTempC);
  await owner`INSERT INTO volta_telemetry.connectivity(vehicle_id,connection_id,status,source_ts,received_at)
    VALUES(1,'fixture','CONNECTED',${old},${old})`;
  await owner`INSERT INTO volta_telemetry.stream_health(id,receiver_generation,receiver_started_at,receiver_seen_at,consumer_started_at,caught_up_at,lag_records,updated_at)
    VALUES(1,'fixture',${old},${now},${old},${now},0,${now})`;
  expect((await get('/v1/vehicles/1/status')).insideTempC).toBe(38);
  await owner`UPDATE volta_telemetry.connectivity SET status='DISCONNECTED'`;
  expect((await get('/v1/vehicles/1/status')).insideTempC).toBe(fallback.insideTempC);
  await owner`UPDATE volta_telemetry.latest_samples SET source_ts=${now},received_at=${now}`;
  expect((await get('/v1/vehicles/1/status')).insideTempC).toBe(38);
  await owner`UPDATE volta_telemetry.latest_samples SET invalid=true,quality='invalid',value_num=NULL`;
  expect((await get('/v1/vehicles/1/status')).insideTempC).toBe(fallback.insideTempC);
});


test('overlapping reconnect keeps the active socket current; late old disconnect cannot mask it',async()=>{
  const now=new Date(),at=(seconds:number)=>new Date(+now-seconds*1000);
  await owner`INSERT INTO volta_telemetry.stream_health(id,receiver_generation,receiver_started_at,receiver_seen_at,consumer_started_at,caught_up_at,lag_records,updated_at)
    VALUES(1,'fixture',${at(10)},${now},${at(10)},${now},0,${now})`;
  await owner`INSERT INTO volta_telemetry.connectivity(vehicle_id,connection_id,status,source_ts,received_at) VALUES
    (1,'old-generation','CONNECTED',${at(20)},${at(20)}),
    (1,'wifi','CONNECTED',${at(6)},${at(6)}),
    (1,'cellular','CONNECTED',${at(4)},${at(4)}),
    (1,'wifi','DISCONNECTED',${at(2)},${at(2)})`;
  expect((await get('/v1/vehicles/1/status')).telemetryFreshness.connected).toBe(true);
  await owner`INSERT INTO volta_telemetry.connectivity(vehicle_id,connection_id,status,source_ts,received_at)
    VALUES(1,'cellular','DISCONNECTED',${at(1)},${at(1)})`;
  expect((await get('/v1/vehicles/1/status')).telemetryFreshness.connected).toBe(false);
});

test('service odometer prefers only newer, valid, ownership-bound telemetry', async()=>{
  const telemetry=new Telemetry(reader,'USD',undefined,true);
  const base=await telemetry.serviceOdometer(1); expect(base.source).toBe('teslamate');
  const t=new Date(Date.now()-1000);
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id)
    VALUES (1,'Odometer',${t},${t},7000,false,'ok','service-a')`;
  const live=await telemetry.serviceOdometer(1); expect(live.source).toBe('fleet_telemetry'); expect(live.odometerKm).toBeCloseTo(11265.408);
  await owner`INSERT INTO volta_telemetry.samples(vehicle_id,field,source_ts,received_at,value_num,invalid,quality,payload_id)
    VALUES (1,'Odometer',${t},${t},7001,false,'ok','service-b')`;
  expect((await telemetry.serviceOdometer(1)).source).toBe('teslamate');
  await owner`DELETE FROM volta_telemetry.samples WHERE payload_id='service-b'`;
  await owner`UPDATE volta_telemetry.vehicle_bindings SET vin_digest=repeat('0',64) WHERE vehicle_id=1`;
  expect((await telemetry.serviceOdometer(1)).source).toBe('teslamate');
});

test('drive energy falls back to exact-bound endpoints, with lifetime precedence and gap/reset fences',async()=>{
  await owner`UPDATE drives SET start_rated_range_km=NULL,end_rated_range_km=NULL WHERE id=1`;
  await owner`UPDATE positions SET rated_battery_range_km=NULL WHERE drive_id=1`;
  const finish=(await owner`SELECT end_date FROM drives WHERE id=1`)[0]!.end_date;
  await datum('EnergyRemaining',50,start,'first'); await datum('EnergyRemaining',45,finish,'last');
  let d=await get('/v1/drives/1'); expect(d.energyUsedKwh).toBe(5);expect(d.energySource).toBe('fleet_energy_remaining');
  const list=(await get('/v1/vehicles/1/drives')).items.find((r:any)=>r.id===1);expect(list.energyUsedKwh).toBe(5);
  await datum('LifetimeEnergyUsed',100,start,'first');await datum('LifetimeEnergyUsed',104,finish,'last');
  d=await get('/v1/drives/1');expect(d.energyUsedKwh).toBe(4);expect(d.energySource).toBe('fleet_lifetime_energy');
  await datum('LifetimeEnergyUsed',90,at(60),'reset');
  expect((await get('/v1/drives/1')).energySource).toBe('fleet_energy_remaining');
  await owner`INSERT INTO volta_telemetry.gaps(vehicle_id,start_ts,end_ts,reason) VALUES(1,${at(60)},${at(70)},'disconnected')`;
  expect((await get('/v1/drives/1')).energySource).toBe('fleet_energy_remaining');
  await owner`INSERT INTO volta_telemetry.gaps(vehicle_id,start_ts,end_ts,reason) VALUES(1,${at(70)},${at(160)},'disconnected')`;
  expect((await get('/v1/drives/1')).energyUsedKwh).toBeNull();
  await owner`DELETE FROM volta_telemetry.gaps`;
  await owner`UPDATE volta_telemetry.vehicle_bindings SET vin_digest=repeat('a',64)`;
  expect((await get('/v1/drives/1')).energyUsedKwh).toBeNull();
});


test('page energy batches disjoint and overlapping windows into three queries',async()=>{
  for (const id of [1,2,3]) {
    const [d]=await owner`SELECT start_date AS start,end_date AS finish FROM drives WHERE id=${id}`;
    await datum('LifetimeEnergyUsed',100,d!.start,`first-${id}`);
    await datum('LifetimeEnergyUsed',100+id,d!.finish,`last-${id}`);
    await datum('EnergyRemaining',50,d!.start,`first-${id}`);
    await datum('EnergyRemaining',45,d!.finish,`last-${id}`);
  }
  const [second]=await owner`SELECT start_date FROM drives WHERE id=2`;
  await datum('LifetimeEnergyUsed',90,new Date(+second!.start_date+60000),'reset');
  const [third]=await owner`SELECT start_date FROM drives WHERE id=3`;
  await owner`INSERT INTO volta_telemetry.gaps(vehicle_id,start_ts,end_ts,reason)
    VALUES(1,${third!.start_date},${third!.start_date},'disconnected'),
      (1,${third!.start_date},${new Date(+third!.start_date+90000)},'silence')`;
  let queries=0;
  const counted=new Proxy(reader,{apply(target,thisArg,args){queries++;return Reflect.apply(target,thisArg,args);}});
  const energy=await new FleetSeries(counted).driveEnergy([1,2,3,4]);
  expect(queries).toBe(3);
  expect(energy.get(1)).toEqual({energy:1,source:'fleet_lifetime_energy'});
  expect(energy.get(2)).toEqual({energy:5,source:'fleet_energy_remaining'});
  expect(energy.has(3)).toBe(false); expect(energy.has(4)).toBe(false);
});

test('batched energy retains validated car and windows during concurrent drive edits',async()=>{
  const [d]=await owner`SELECT start_date AS start,end_date AS finish FROM drives WHERE id=1`;
  await datum('EnergyRemaining',50,d!.start,'first');
  await datum('EnergyRemaining',45,d!.finish,'last');
  let queries=0;
  const concurrent=new Proxy(reader,{apply(target,thisArg,args){
    const query=Reflect.apply(target,thisArg,args);
    if (++queries!==1) return query;
    return (async()=>{
      const result=await query;
      await owner`UPDATE drives SET car_id=3,start_date=start_date+interval '1 day',end_date=end_date+interval '1 day' WHERE id=1`;
      return result;
    })();
  }});
  expect((await new FleetSeries(concurrent).driveEnergy([1])).get(1)).toEqual({energy:5,source:'fleet_energy_remaining'});
});

test('telemetry drive windows support safe negative IDs without int32 TeslaMate lookups',async()=>{
  await datum('VehicleSpeed',20,start,'first');await datum('VehicleSpeed',25,at(10),'last');
  const series=await new FleetSeries(reader).session('drive',-3700000000000001,{car_id:1,start,finish:at(10)});
  expect(series?.samples).toHaveLength(2);expect(series?.samples[0]?.speedKph).toBeCloseTo(32.18688);
  expect(series?.samples[0]?.elevationM).toBeNull();expect(series?.coverage.metrics.speedKph.sourceSampleCount).toBe(2);
});
