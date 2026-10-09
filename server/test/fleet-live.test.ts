import { expect, test } from 'bun:test';
import { liveValues } from '../src/fleet-live';
const now = new Date('2026-01-02T12:00:00Z'), old = '2026-01-01T00:00:00Z';
const sample = (field:string, value:any, unit='', invalid=false) => ({field,source_ts:old,source_unit:unit,invalid,quality:invalid?'invalid':'ok',...value});
const health = {receiver_generation:'fixture',receiver_started_at:old,receiver_seen_at:now,updated_at:now,caught_up_at:now,lag_records:0};
const fixture = (samples:any[]=[]) => ({samples,connections:[{status:'CONNECTED',source_ts:old,received_at:old}],health:{...health}});
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
