import { expect, test } from 'bun:test';
import { coveredCharge, deriveCharge, telemetryChargeId, telemetryChargeVehicle } from '../src/fleet-charges';

const at=(s:number)=>new Date(Date.UTC(2026,0,3)+s*1000);
// Change-only DC session: power/SoC/energy reported only when they change.
const rows=()=>[
  {t:at(-240),battery_level:23.5,energy_remaining_kwh:20,outside_temp_c:10,dc_power_kw:0,ac_power_kw:0,latitude:37.7,longitude:-122.4},
  {t:at(0),outside_temp_c:12},
  {t:at(2),dc_power_kw:1},
  {t:at(60),dc_power_kw:150},
  {t:at(120),dc_power_kw:196},
  {t:at(600),battery_level:60,outside_temp_c:14},
  {t:at(1500),dc_power_kw:50},
  {t:at(1680),dc_power_kw:0},
  {t:at(1690),battery_level:80.4,energy_remaining_kwh:63.26},
  {t:at(1810),battery_level:79,dc_power_kw:0,speed_kph:30},
];
test('telemetry charge trims to measured power, takes SoC and kWh at the edges, and never reaches the next drive',()=>{
  const c=deriveCharge({start:at(0),end:at(1700),nextDrive:at(1800)},rows())!;
  expect(c.start).toEqual(at(2));expect(c.end).toEqual(at(1680));expect(c.durationMin).toBeCloseTo(1678/60);
  expect(c.startBatteryLevel).toBe(24);expect(c.endBatteryLevel).toBe(80);
  expect(c.energyAddedKwh).toBeCloseTo(43.26);expect(c.maxPowerKw).toBe(196);expect(c.fastCharger).toBe(true);
  const held=[[1,58],[150,60],[196,1380],[50,180]];
  expect(c.avgPowerKw).toBeCloseTo(held.reduce((s,[p,dt])=>s+p!*p!*dt!,0)/held.reduce((s,[p,dt])=>s+p!*dt!,0));
  expect(c.outsideTempAvgC).toBeCloseTo((12*598+14*1080)/1678);expect(c.latitude).toBe(37.7);expect(c.longitude).toBe(-122.4);
  // Next drive before power reports zero: clamp, exclude post-drive SoC, integrate held power.
  const early=deriveCharge({start:at(0),end:at(1700),nextDrive:at(1650)},rows())!;
  expect(early.end).toEqual(at(1650));expect(early.endBatteryLevel).toBe(60);
  expect(early.energyAddedKwh).toBeCloseTo((58+150*60+196*1380+50*150)/3600);
  // Real data loss inside: no guessed energy. Cadence jitter does not count.
  expect(deriveCharge({start:at(0),end:at(1700),nextDrive:at(1650)},rows(),[{start:at(700),end:at(800),reason:'disconnected'}])!.energyAddedKwh).toBeNull();
  expect(deriveCharge({start:at(0),end:at(1700),nextDrive:at(1650)},rows(),[{start:at(700),end:at(701),reason:'disconnected'}])!.energyAddedKwh).not.toBeNull();
});
test('no reported power means no charge; AC sessions are slow; invalid DC is unknown, not zero',()=>{
  expect(deriveCharge({start:at(0),end:at(600)},[{t:at(-100),dc_power_kw:50},{t:at(10),battery_level:50}])).toBeNull();
  expect(deriveCharge({start:at(0),end:at(600)},[{t:at(10),dc_power_kw:0,ac_power_kw:0}])).toBeNull();
  const ac=deriveCharge({start:at(0),end:at(3600)},[
    {t:at(0),ac_power_kw:0,invalid_fields:['DCChargingPower'],battery_level:40,energy_remaining_kwh:30},
    {t:at(5),ac_power_kw:11},{t:at(3605),battery_level:55,energy_remaining_kwh:41}])!;
  expect(ac.start).toEqual(at(5));expect(ac.end).toEqual(at(3600));expect(ac.fastCharger).toBe(false);expect(ac.maxPowerKw).toBe(11);
  expect(ac.energyAddedKwh).toBeCloseTo(11);expect(ac.avgPowerKw).toBeCloseTo(11);expect(ac.startBatteryLevel).toBe(40);expect(ac.endBatteryLevel).toBe(55);
  // A negative energy delta (pack recalibration) falls back to held power.
  const recal=deriveCharge({start:at(0),end:at(3600)},[{t:at(0),ac_power_kw:11,energy_remaining_kwh:30},{t:at(3600),ac_power_kw:0,energy_remaining_kwh:29}])!;
  expect(recal.energyAddedKwh).toBeCloseTo(11);
  // Unknown power is not a stop: no invented endpoint, no energy, flagged uncertain.
  const invalid=deriveCharge({start:at(0),end:at(600)},[{t:at(0),dc_power_kw:100},{t:at(300),invalid_fields:['DCChargingPower']}])!;
  expect(invalid.end).toEqual(at(600));expect(invalid.energyAddedKwh).toBeNull();expect(invalid._uncertain).toBe(true);
});
test('invalid power between the last positive and an explicit zero keeps the session open and uncertain',()=>{
  const c=deriveCharge({start:at(0),end:at(1800)},[{t:at(0),dc_power_kw:100,ac_power_kw:0},{t:at(300),invalid_fields:['DCChargingPower']},{t:at(900),dc_power_kw:0}])!;
  expect(c.end).toEqual(at(900));expect(c.energyAddedKwh).toBeNull();expect(c._uncertain).toBe(true);
  // AC still reading 0 does not stand in for unknown DC power.
  expect(c.durationMin).toBe(15);
  const clean=deriveCharge({start:at(0),end:at(1800)},[{t:at(0),dc_power_kw:100,ac_power_kw:0},{t:at(900),dc_power_kw:0}])!;
  expect(clean.end).toEqual(at(900));expect(clean.energyAddedKwh).toBeCloseTo(25);expect(clean._uncertain).toBe(false);
});
test('edge SoC and EnergyRemaining never hold across an invalid observation or real loss',()=>{
  const session=[{t:at(0),dc_power_kw:100},{t:at(600),dc_power_kw:0},{t:at(610),battery_level:50,energy_remaining_kwh:30}];
  const held=deriveCharge({start:at(0),end:at(900)},[{t:at(-60),battery_level:40,energy_remaining_kwh:20},...session])!;
  expect(held.startBatteryLevel).toBe(40);expect(held.energyAddedKwh).toBeCloseTo(10);
  const invalid=deriveCharge({start:at(0),end:at(900)},[{t:at(-60),battery_level:40,energy_remaining_kwh:20},
    {t:at(-30),invalid_fields:['BatteryLevel','EnergyRemaining']},...session])!;
  expect(invalid.startBatteryLevel).toBeNull();expect(invalid.energyAddedKwh).toBeCloseTo(100*600/3600);
  const lost=deriveCharge({start:at(0),end:at(900)},[{t:at(-250),battery_level:40,energy_remaining_kwh:20},...session],[{start:at(-200),end:at(-50),reason:'disconnected'}])!;
  expect(lost.startBatteryLevel).toBeNull();expect(lost.energyAddedKwh).toBeCloseTo(100*600/3600);
  // Held within the session: an invalid end reading is not carried to the end.
  const end=deriveCharge({start:at(0),end:at(900)},[{t:at(-60),battery_level:40,energy_remaining_kwh:20},{t:at(0),dc_power_kw:100},{t:at(300),battery_level:45,energy_remaining_kwh:25},
    {t:at(500),invalid_fields:['BatteryLevel','EnergyRemaining']},{t:at(600),dc_power_kw:0}])!;
  expect(end.endBatteryLevel).toBeNull();expect(end.energyAddedKwh).toBeCloseTo(100*600/3600);
});
test('charge identity is stable and a covered TeslaMate process is replaced only without lost data',()=>{
  const id=telemetryChargeId(2,at(0));expect(id).toBeLessThan(0);expect(telemetryChargeVehicle(id)).toBe(2);
  const catalog={windows:[],gaps:[{start:at(500),end:at(700),reason:'silence'}],start:at(0),end:at(5000)};
  expect(coveredCharge({start:at(100),end:at(400)},catalog)).toBe(true);
  expect(coveredCharge({start:at(400),end:at(800)},catalog)).toBe(false);
  expect(coveredCharge({start:at(-100),end:at(400)},catalog)).toBe(false);
  expect(coveredCharge({start:at(4900),end:null},catalog)).toBe(false);
  expect(coveredCharge({start:at(1000),end:at(1100)},{...catalog,gaps:[{start:at(900),end:at(1200),reason:'charge_invalid'}]})).toBe(false);
  expect(coveredCharge({start:at(1000),end:at(1100)},{...catalog,gaps:[{start:at(900),end:at(1200),reason:'gear_invalid'}]})).toBe(true);
});
