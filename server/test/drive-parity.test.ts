import { expect, test } from 'bun:test';
import { applyDriveEnergy, efficiencyScore, endpointEnergy, driveScore, driveStyleScore, scoreFromStats, aggregateDriveScore } from '../src/drive-parity';

test('rated energy wins; unknown and negative energy never become costable zero', () => {
  expect(applyDriveEnergy({energyUsedKwh:5,distanceKm:20},{energy:4,source:'fleet_lifetime_energy'})).toMatchObject({energyUsedKwh:5,efficiencyWhPerKm:250,energySource:'teslamate_rated_range'});
  expect(applyDriveEnergy({energyUsedKwh:null,distanceKm:20},{energy:4,source:'fleet_lifetime_energy'})).toMatchObject({energyUsedKwh:4,efficiencyWhPerKm:200,energySource:'fleet_lifetime_energy'});
  expect(applyDriveEnergy({energyUsedKwh:-1,distanceKm:20}).energyUsedKwh).toBeNull();
  expect(applyDriveEnergy({energyUsedKwh:0,distanceKm:0}).efficiencyWhPerKm).toBeNull();
  expect(applyDriveEnergy({energyUsedKwh:0,distanceKm:20}).energyUsedKwh).toBeNull();
  expect(applyDriveEnergy({energyUsedKwh:0,distanceKm:20},{energy:4,source:'fleet_lifetime_energy'}).energyUsedKwh).toBe(4);
});
test('efficiency score requires real finite positive inputs', () => {
  expect(efficiencyScore(200,160)).toBe(73);
  expect(efficiencyScore(100,160)).toBe(100);
  for (const n of [null,0,-1,NaN,Infinity]) expect(efficiencyScore(n,160)).toBeNull();
});
test('energy endpoints require distinct readings close to both session boundaries', () => {
  const start=new Date(0),end=new Date(3600000);
  expect(endpointEnergy({t:start,value:50},{t:end,value:45},start,end)).toBe(5);
  expect(endpointEnergy({t:new Date(180000),value:50},{t:end,value:45},start,end)).toBeNull();
  expect(endpointEnergy({t:start,value:50},{t:new Date(3400000),value:45},start,end)).toBeNull();
  expect(endpointEnergy({t:start,value:40},{t:end,value:45},start,end)).toBeNull();
  expect(endpointEnergy({t:start,value:50},{t:start,value:50},start,end)).toBeNull();
  expect(endpointEnergy({t:start,value:50},{t:end,value:50},start,end)).toBeNull();
});

test('composite differentiates consumption, harsh acceleration and sustained overspeed', () => {
  expect(efficiencyScore(170,200)).toBe(100);
  expect(efficiencyScore(400,200)).toBe(40);
  const points=(speed:number,accel:number)=>[0,10,20,30].map(t=>({t:new Date(t*1000),speedKph:speed,longitudinalAccelerationMps2:accel}));
  const normal=driveScore(200,200,points(90,.2))!;
  expect(normal).toBeGreaterThan(85); expect(normal).toBeLessThan(100);
  expect(driveScore(300,200,points(90,.2))).toBeLessThan(normal);
  expect(driveScore(200,200,points(90,4))).toBeLessThan(normal);
  expect(driveScore(200,200,points(160,.2))).toBeLessThan(normal);
  expect(driveScore(null,null,[])).toBeNull();
  expect(driveScore(null,null,[{t:new Date(0),speedKph:0}])).toBeNull();
  expect(driveScore(200,200,[])).toBe(efficiencyScore(200,200));
  expect(driveScore(200,200,points(90,.2))).toBe(normal);
});

test('four style components have independent thresholds and weights renormalize',()=>{
  const points=(acc:number|null,lat:number|null=null,speed:number|null=90)=>[0,5,10,15].map(t=>({t:new Date(t*1000),speedKph:speed,longitudinalAccelerationMps2:acc,lateralAccelerationMps2:lat}));
  expect(driveStyleScore(200,200,points(.2)).scoreBreakdown).toEqual({efficiency:89,acceleration:100,smoothness:100,speed:100});
  expect(driveStyleScore(null,null,points(3)).scoreBreakdown.acceleration).toBe(2);
  expect(driveStyleScore(null,null,points(-3.5)).scoreBreakdown.acceleration).toBe(2);
  expect(driveStyleScore(null,null,points(null,3.5,null)).scoreBreakdown).toEqual({efficiency:null,acceleration:2,smoothness:null,speed:null});
  expect(driveStyleScore(null,null,points(.2,null,160)).scoreBreakdown.speed).toBe(22);
  const rough=points(0);rough[1]!.longitudinalAccelerationMps2=20;rough[2]!.longitudinalAccelerationMps2=-20;rough[3]!.longitudinalAccelerationMps2=20;
  expect(driveStyleScore(null,null,rough).scoreBreakdown.smoothness).toBe(0);
  const efficiencyOnly=scoreFromStats(200,200,null,null,null);expect(efficiencyOnly.driveScore).toBe(89);
  const speedOnly=scoreFromStats(null,null,null,30,null);expect(speedOnly.driveScore).toBe(22);
  expect(scoreFromStats(null,null,null,null,null).driveScore).toBeNull();
  expect(scoreFromStats(200,200,null,0,null).driveScore).toBe(Math.round((89*.4+100*.15)/.55));
  expect(aggregateDriveScore([{distanceKm:10,driveScore:100},{distanceKm:30,driveScore:60},{distanceKm:100,driveScore:null}])).toBe(70);
  expect(aggregateDriveScore([{distanceKm:0,driveScore:100}])).toBeNull();
});

test('smoothness is stable across quantized speed cadences and never mixes IMU and speed derivatives',()=>{
  const trip=(step:number)=>Array.from({length:Math.floor(60/step)+1},(_,i)=>({t:new Date(i*step*1000),speedKph:Math.round(30+i*step*1.2)}));
  const scores=[.5,1,2,5].map(step=>driveStyleScore(200,200,trip(step)));
  for (const score of scores) expect(score.scoreBreakdown.smoothness).toBe(100);
  expect(new Set(scores.map(s=>s.driveScore)).size).toBe(1);
  const mixed=trip(1).map((p,i)=>({...p,longitudinalAccelerationMps2:i%2?0:null}));
  expect(driveStyleScore(null,null,mixed).scoreBreakdown.smoothness).toBe(100);
});
