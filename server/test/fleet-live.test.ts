import { expect, test } from 'bun:test';
import { liveValues } from '../src/fleet-live';
const now = new Date('2026-01-02T12:00:00Z'), old = '2026-01-01T00:00:00Z';
const sample = (field:string, value:any, unit='', invalid=false) => ({field,source_ts:old,source_unit:unit,invalid,quality:invalid?'invalid':'ok',...value});
const health = {receiver_generation:'fixture',receiver_started_at:old,receiver_seen_at:now,updated_at:now,caught_up_at:now,lag_records:0};
const fixture = (samples:any[]=[]) => ({samples,connections:[{status:'CONNECTED',source_ts:old,received_at:old}],health:{...health},lastCharge:null as {start:Date,open:boolean,observed:boolean,dc:boolean}|null,powerSign:null as string|null});
test('change-only values stay current despite sample age',()=>{
 const r=liveValues(fixture([sample('Locked',{value_bool:true}),sample('SentryMode',{value_text:'SentryModeStateArmed'}),sample('ModuleTempMax',{value_num:38},'C')]),now)!;
 expect(r.freshness.connected).toBe(true);expect(r.values).toMatchObject({locked:true,sentryMode:true,packTempMaxC:38});
});
test('disconnect, stalled consumer and receiver restart retain values with disconnected freshness',()=>{
 const f=fixture([sample('Locked',{value_bool:false})]);f.connections=[{status:'DISCONNECTED',source_ts:old,received_at:old}];
 expect(liveValues(f,now)!.values.locked).toBe(false);expect(liveValues(f,now)!.freshness.connected).toBe(false);
 f.connections=[{status:'CONNECTED',source_ts:old,received_at:old}];f.health.receiver_seen_at=new Date(old);
 expect(liveValues(f,now)!.freshness.connected).toBe(false);
 f.health={...health,receiver_started_at:now.toISOString()};expect(liveValues(f,now)!.freshness.connected).toBe(false);
});
test('invalid, unknown units, unknown sentry and nonfinite measurements stay unknown',()=>{
 const r=liveValues(fixture([sample('Locked',{},'',true),sample('SentryMode',{value_text:'SentryModeStateUnknown'}),sample('ModuleTempMax',{value_num:100},'F'),sample('TpmsPressureFl',{value_num:Infinity},'bar')]),now)!;
 expect(r.values.locked).toBeNull();expect(r.values.sentryMode).toBeNull();expect(r.values.packTempMaxC).toBeNull();expect(r.tpms.fl.pressureBar).toBeNull();
});
test('HVAC power: user climate and precondition are on, overheat protection unknown; set point needs Celsius',()=>{
 const on=(state:string)=>liveValues(fixture([sample('HvacPower',{value_text:state})]),now)!.values.climateOn;
 expect(on('HvacPowerStateOff')).toBe(false);expect(on('HvacPowerStateOn')).toBe(true);expect(on('HvacPowerStatePrecondition')).toBe(true);
 expect(on('HvacPowerStateOverheatProtect')).toBeNull();expect(on('HvacPowerStateUnknown')).toBeNull();
 expect(liveValues(fixture([sample('HvacLeftTemperatureRequest',{value_num:21},'C')]),now)!.values.driverTempSettingC).toBe(21);
 expect(liveValues(fixture([sample('HvacLeftTemperatureRequest',{value_num:70},'F')]),now)!.values.driverTempSettingC).toBeNull();
 expect(liveValues(fixture([sample('HvacPower',{},'',true)]),now)!.values.climateOn).toBeNull();
});
test('TPMS honors units and per-tire timestamps; odometer converts miles',()=>{
 const r=liveValues(fixture([sample('TpmsPressureFl',{value_num:2.9},'bar'),sample('TpmsPressureFr',{value_num:42},'psi'),sample('TpmsPressureRl',{value_num:290},'kPa'),sample('Odometer',{value_num:100},'mi')]),now)!;
 expect(r.tpms.fl).toEqual({pressureBar:2.9,updatedAt:old});expect(r.tpms.fr.pressureBar).toBeCloseTo(2.8958,3);expect(r.tpms.rl.pressureBar).toBe(2.9);expect(r.tpms.rr.pressureBar).toBeNull();expect(r.values.odometerKm).toBeCloseTo(160.9344);
});

test('receiver generation fence uses precise receive time, not rounded source time',()=>{
 const f=fixture();f.health.receiver_started_at='2026-01-01T00:00:00.100Z';
 f.connections=[{status:'CONNECTED',source_ts:old,received_at:'2026-01-01T00:00:00.101Z'}];
 expect(liveValues(f,now)!.freshness.connected).toBe(true);
 f.connections[0]!.received_at=old;expect(liveValues(f,now)!.freshness.connected).toBe(false);
});

test('charging reports AC power, time to full and the open session counter',()=>{
 const start='2026-01-02T11:00:00Z',f=fixture([sample('DetailedChargeState',{value_text:'DetailedChargeStateCharging'}),sample('ACChargingPower',{value_num:7.7},'kW'),
  sample('DCChargingPower',{value_num:0},'kW'),sample('TimeToFullCharge',{value_num:3.2},'h'),sample('ChargeAmps',{value_num:32},'A'),sample('ChargerVoltage',{value_num:241},'V'),
  sample('ChargingCableType',{value_text:'CableTypeSAE'}),{...sample('ACChargingEnergyIn',{value_num:2.9},'kWh'),source_ts:'2026-01-02T11:40:00Z'},sample('DCChargingEnergyIn',{value_num:10.8},'kWh')]);
 f.lastCharge={start:new Date(start),open:true,observed:true,dc:false};
 const c=liveValues(f,now)!.charge;
 expect(c).toMatchObject({state:'charging',powerKw:7.7,fast:false,currentA:32,voltage:241,cableType:'CableTypeSAE',energyAddedKwh:2.9});
 expect(c.minutesToFull).toBeCloseTo(192);expect(c.readyAt).toEqual(new Date(+new Date(old)+192*60_000));expect(c.observedAt).toEqual(new Date('2026-01-02T11:40:00Z'));expect(c.startedAt).toEqual(new Date(start));expect(c.at).toEqual(new Date(old));
 expect(liveValues(f,now)!.values).not.toHaveProperty('chargingState');
});
test('a counter held from before the open session, or with no session, is not this session energy',()=>{
 const f=fixture([sample('DetailedChargeState',{value_text:'DetailedChargeStateCharging'}),{...sample('ACChargingEnergyIn',{value_num:20},'kWh'),source_ts:'2026-01-02T10:59:30Z'}]);
 expect(liveValues(f,now)!.charge.energyAddedKwh).toBeNull();
 // Restarted 30 s after the last session stopped: its final counter is not this session's.
 f.lastCharge={start:new Date('2026-01-02T11:00:00Z'),open:true,observed:true,dc:false};expect(liveValues(f,now)!.charge.energyAddedKwh).toBeNull();
 f.samples[1]!.source_ts='2026-01-02T11:00:00Z';expect(liveValues(f,now)!.charge.energyAddedKwh).toBe(20);
 // Charging belongs only to an open session.
 f.lastCharge.open=false;expect(liveValues(f,now)!.charge).toMatchObject({startedAt:null,energyAddedKwh:null});
});
test('a completed or stopped state keeps the newest session and its final counter',()=>{
 const f=fixture([sample('DetailedChargeState',{value_text:'DetailedChargeStateComplete'}),{...sample('ACChargingEnergyIn',{value_num:9.4},'kWh'),source_ts:'2026-01-02T11:30:00Z'}]);
 f.lastCharge={start:new Date('2026-01-02T11:00:00Z'),open:false,observed:true,dc:false};
 expect(liveValues(f,now)!.charge).toMatchObject({state:'complete',startedAt:new Date('2026-01-02T11:00:00Z'),energyAddedKwh:9.4});
 f.samples[0]!.value_text='DetailedChargeStateDisconnected';expect(liveValues(f,now)!.charge.startedAt).toBeNull();
});
test('a positive DC reading held from before the session cannot override fresh AC charging',()=>{
 const start='2026-01-02T11:00:00Z',f=fixture([sample('DetailedChargeState',{value_text:'DetailedChargeStateCharging'}),sample('DCChargingPower',{value_num:150},'kW'),
  {...sample('ACChargingPower',{value_num:7.7},'kW'),source_ts:'2026-01-02T11:01:00Z'},{...sample('ACChargingEnergyIn',{value_num:1.2},'kWh'),source_ts:'2026-01-02T11:10:00Z'},
  {...sample('DCChargingEnergyIn',{value_num:40},'kWh'),source_ts:'2026-01-02T11:10:00Z'}]);
 f.lastCharge={start:new Date(start),open:true,observed:true,dc:false};
 expect(liveValues(f,now)!.charge).toMatchObject({powerKw:7.7,fast:false,energyAddedKwh:1.2});
 // A fast-charger flag held from an earlier session does not make this one DC.
 f.samples.push(sample('FastChargerPresent',{value_bool:true}));expect(liveValues(f,now)!.charge.fast).toBe(false);
});
test('a held no-fast-charger flag cannot hide DC charging; a finished DC session keeps its DC total',()=>{
 const start='2026-01-02T11:00:00Z',f=fixture([sample('DetailedChargeState',{value_text:'DetailedChargeStateCharging'}),sample('FastChargerPresent',{value_bool:false}),
  {...sample('DCChargingPower',{value_num:150},'kW'),source_ts:'2026-01-02T11:20:00Z'},{...sample('DCChargingEnergyIn',{value_num:12},'kWh'),source_ts:'2026-01-02T11:20:00Z'},
  sample('ACChargingPower',{value_num:0},'kW'),sample('ACChargingEnergyIn',{value_num:3},'kWh')]);
 f.lastCharge={start:new Date(start),open:true,observed:true,dc:true};
 expect(liveValues(f,now)!.charge).toMatchObject({powerKw:150,fast:true,energyAddedKwh:12});
 f.samples[0]!.value_text='DetailedChargeStateComplete';f.samples[2]!.value_num=0;f.lastCharge.open=false;
 expect(liveValues(f,now)!.charge).toMatchObject({state:'complete',fast:true,energyAddedKwh:12});
});
test('DC fast charging uses DC power and its counter; unknown states stay unknown',()=>{
 const f=fixture([sample('DetailedChargeState',{value_text:'DetailedChargeStateStarting'}),sample('ACChargingPower',{value_num:0},'kW'),sample('DCChargingPower',{value_num:150},'kW'),
  {...sample('DCChargingEnergyIn',{value_num:12},'kWh'),source_ts:now.toISOString()},sample('ACChargingEnergyIn',{value_num:1},'kWh')]);
 f.samples[2]!.source_ts=now.toISOString();f.lastCharge={start:new Date('2026-01-02T11:50:00Z'),open:true,observed:true,dc:false};
 expect(liveValues(f,now)!.charge).toMatchObject({state:'charging',powerKw:150,fast:true,energyAddedKwh:12});
 f.samples[0].value_text='DetailedChargeStateMystery';expect(liveValues(f,now)!.charge.state).toBeNull();
});

// Live driving: a drive moment 2 s before `now` on a connected stream.
const moment = new Date(+now - 2000).toISOString();
const at = (row: any, t = moment, payload = 'p1') => ({...row, source_ts: t, payload_id: payload});
const driving = (extra: any[] = []) => {
  const f = fixture([at(sample('Gear',{value_text:'ShiftStateD'})), at(sample('VehicleSpeed',{value_num:40},'mph')),
    at(sample('Location',{latitude:37.44,longitude:-122.14})), at(sample('PackVoltage',{value_num:400},'V')),
    at(sample('PackCurrent',{value_num:105},'A')), ...extra]);
  f.powerSign = 'discharge_positive';
  return f;
};
test('a connected drive reports gear, speed in km/h and signed same-payload power as current',()=>{
  const d = liveValues(driving(), now)!.drive;
  expect(d.gear).toEqual({value:'D',observedAt:new Date(moment),current:true,source:'fleet_telemetry'});
  expect(d.speedKph!.value).toBeCloseTo(64.37,2); expect(d.speedKph!.current).toBe(true);
  expect(d.powerKw!.value).toBeCloseTo(42); expect(d.powerKw!.current).toBe(true); expect(d.stoppedSince).toBeNull();
});
test('regen is negative power; the sign follows the operator calibration and is unknown without it',()=>{
  const f = driving(); f.samples.find(s => s.field === 'PackCurrent')!.value_num = -45;
  expect(liveValues(f, now)!.drive.powerKw!.value).toBeCloseTo(-18);
  f.powerSign = 'discharge_negative'; expect(liveValues(f, now)!.drive.powerKw!.value).toBeCloseTo(18);
  f.powerSign = null; expect(liveValues(f, now)!.drive.powerKw).toBeNull();
});
test('power needs voltage and current from one payload; invalid or unknown units are unknown',()=>{
  const f = driving(); f.samples.find(s => s.field === 'PackCurrent')!.payload_id = 'p2';
  expect(liveValues(f, now)!.drive.powerKw).toBeNull();
  const g = driving(); g.samples.find(s => s.field === 'VehicleSpeed')!.source_unit = 'furlongs';
  expect(liveValues(g, now)!.drive.speedKph).toBeNull();
  const h = driving(); Object.assign(h.samples.find(s => s.field === 'Gear')!, {invalid:true,quality:'invalid',value_text:null});
  expect(liveValues(h, now)!.drive.gear).toBeNull();
  const i = driving(); i.samples.find(s => s.field === 'Gear')!.value_text = 'ShiftStateSNA';
  expect(liveValues(i, now)!.drive.gear).toBeNull();
});
test('gear maps P, R, N and D',()=>{
  for (const [raw, gear] of [['ShiftStateP','P'],['ShiftStateR','R'],['ShiftStateN','N'],['ShiftStateD','D']]) {
    const f = driving(); f.samples.find(s => s.field === 'Gear')!.value_text = raw;
    expect(liveValues(f, now)!.drive.gear!.value).toBe(gear as any);
  }
});
test('a car in gear that stops reporting position is stopped; the held speed is not current',()=>{
  const quiet = new Date(+now - 45_000).toISOString(), f = driving();
  for (const s of f.samples) s.source_ts = s.field === 'Gear' ? old : quiet;
  const d = liveValues(f, now)!.drive;
  expect(d.stoppedSince).toEqual(new Date(quiet)); expect(d.speedKph!.current).toBe(false); expect(d.powerKw!.current).toBe(false);
  expect(d.gear!.current).toBe(true);
  // Reported 9 s ago: still moving as far as anyone can tell.
  const recent = new Date(+now - 9000).toISOString(), g = driving();
  for (const s of g.samples) if (s.field !== 'Gear') s.source_ts = recent;
  expect(liveValues(g, now)!.drive.stoppedSince).toBeNull(); expect(liveValues(g, now)!.drive.speedKph!.current).toBe(true);
  // Shifted into Drive after the last report: stopped since the shift.
  const later = new Date(+now - 20_000).toISOString(); f.samples.find(s => s.field === 'Gear')!.source_ts = later;
  expect(liveValues(f, now)!.drive.stoppedSince).toEqual(new Date(later));
});
test('stillness needs a connected stream, a drive gear and a valid fix',()=>{
  const quiet = new Date(+now - 45_000).toISOString(), base = () => { const f = driving(); for (const s of f.samples) if (s.field !== 'Gear') s.source_ts = quiet; return f; };
  const parked = base(); parked.samples.find(s => s.field === 'Gear')!.value_text = 'ShiftStateP';
  expect(liveValues(parked, now)!.drive.stoppedSince).toBeNull();
  const tunnel = base(); Object.assign(tunnel.samples.find(s => s.field === 'Location')!, {invalid:true,quality:'invalid',latitude:null,longitude:null});
  expect(liveValues(tunnel, now)!.drive.stoppedSince).toBeNull();
  const away = base(); away.connections = [{status:'DISCONNECTED',source_ts:old,received_at:old}];
  const d = liveValues(away, now)!.drive;
  expect(d.stoppedSince).toBeNull(); expect(d.gear!.current).toBe(false); expect(d.speedKph!.current).toBe(false);
});
test('a disconnected stream keeps fresh-looking readings but never calls them current',()=>{
  const f = driving(); f.connections = [{status:'DISCONNECTED',source_ts:old,received_at:old}];
  const d = liveValues(f, now)!.drive;
  expect(d.gear!.current).toBe(false); expect(d.speedKph!.current).toBe(false); expect(d.powerKw!.current).toBe(false);
  expect(d.speedKph!.observedAt).toEqual(new Date(moment));
});
