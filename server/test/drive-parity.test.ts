import { expect, test } from 'bun:test';
import { applyDriveEnergy, efficiencyScore, endpointEnergy } from '../src/drive-parity';

test('rated energy wins; unknown and negative energy never become costable zero', () => {
  expect(applyDriveEnergy({energyUsedKwh:5,distanceKm:20},{energy:4,source:'fleet_lifetime_energy'})).toMatchObject({energyUsedKwh:5,efficiencyWhPerKm:250,energySource:'teslamate_rated_range'});
  expect(applyDriveEnergy({energyUsedKwh:null,distanceKm:20},{energy:4,source:'fleet_lifetime_energy'})).toMatchObject({energyUsedKwh:4,efficiencyWhPerKm:200,energySource:'fleet_lifetime_energy'});
  expect(applyDriveEnergy({energyUsedKwh:-1,distanceKm:20}).energyUsedKwh).toBeNull();
  expect(applyDriveEnergy({energyUsedKwh:0,distanceKm:0}).efficiencyWhPerKm).toBeNull();
  expect(applyDriveEnergy({energyUsedKwh:0,distanceKm:20}).energyUsedKwh).toBeNull();
  expect(applyDriveEnergy({energyUsedKwh:0,distanceKm:20},{energy:4,source:'fleet_lifetime_energy'}).energyUsedKwh).toBe(4);
});
test('efficiency score requires real finite positive inputs', () => {
  expect(efficiencyScore(200,160)).toBe(80);
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
