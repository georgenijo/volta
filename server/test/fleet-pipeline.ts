// Called LAST by the disposable Docker acceptance harness. The receiver has
// already ingested real protobuf records over test mTLS into this database.
// All credentials below are generated fixture credentials, env only.
import { connect } from '../src/db';
import { Auth } from '../src/auth';
import { Telemetry } from '../src/telemetry';
import { createApp } from '../src/app';

const ownerURL=process.env.VT_API_TEST_DATABASE_URL,readerURL=process.env.VT_API_READER_DATABASE_URL;
const hostOf=(url:string)=>{try{return new URL(url).hostname;}catch{return '';}};
const pathOf=(url:string)=>{try{return new URL(url).pathname;}catch{return '';}};
if (process.env.VT_PIPELINE_DISPOSABLE !== 'volta-telemetry-test-postgres' || !ownerURL || !readerURL
  || !['127.0.0.1','localhost'].includes(hostOf(ownerURL))
  || pathOf(ownerURL) !== '/teslamate') {console.error('receiver-to-API acceptance failed: disposable preflight');process.exit(1);}
const owner=connect(ownerURL,false,120000),reader=connect(readerURL,true);
let http: ReturnType<typeof Bun.serve> | null=null;
let stage='schema';
try {
  // The ingestion suite first verifies the sentinel table was untouched.
  // Now install the full pinned TeslaMate fixture for the real API queries.
  await owner`DROP TABLE public.positions`;
  for (const path of ['teslamate-v4.3.0.sql','fixtures.sql']) {
    stage=path==='fixtures.sql'?'fixtures':'teslamate-schema';
    if (path==='fixtures.sql') await owner`SET search_path=public`;
    await owner.unsafe(await Bun.file(new URL(path,import.meta.url)).text()).simple();
  }
  stage='auth-schema';
  await owner.unsafe(await Bun.file(new URL('../../deploy/auth-schema.sql',import.meta.url)).text()).simple();
  stage='api-view';
  const migration=await Bun.file(new URL('../../deploy/telemetry/sql/002_api_series.sql',import.meta.url)).text();
  // postgres.js requires its transaction helper with a pooled connection.
  await owner.begin(async tx=>await tx.unsafe(migration.replace(/^BEGIN;$/m,'').replace(/^COMMIT;$/m,'')).simple());
  stage='api-grants';
  await owner`GRANT SELECT ON ALL TABLES IN SCHEMA public TO volta_readonly`;
  await owner`UPDATE public.cars SET vin='5YJ3E1EA0XF000002' WHERE id=2`;
  stage='window';
  let [window]=await owner`SELECT min(source_ts) AS start,max(source_ts) AS finish FROM volta_telemetry.samples WHERE vehicle_id=2`;
  if (process.env.VT_API_WINDOW_START && process.env.VT_API_WINDOW_END) window={start:new Date(process.env.VT_API_WINDOW_START),finish:new Date(process.env.VT_API_WINDOW_END)};
  if (!window?.start || !window.finish) throw new Error('Streamed observations required');
  stage='drive-fixture';
  await owner`UPDATE public.drives SET car_id=2,start_date=${window.start},end_date=${window.finish},distance=1,duration_min=10 WHERE id=1`;
  const auth=new Auth(owner);
  stage='http';
  const app=createApp(auth,new Telemetry(reader,'USD',undefined,true),()=>{});
  http=Bun.serve({hostname:'127.0.0.1',port:0,fetch:app.fetch});
  const base=`http://127.0.0.1:${http.port}`;
  const pair=await fetch(base+'/v1/auth/pair',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({code:await auth.createPairingCode(),deviceName:'Synthetic pipeline'})});
  if (pair.status!==200) throw new Error('Pairing failed');
  const {token}=await pair.json() as {token:string};
  const response=await fetch(base+'/v1/drives/1',{headers:{Authorization:`Bearer ${token}`}});
  const result=await response.json() as any;
  const samples=result.telemetry?.samples ?? [];
  stage='dense-shape';
  const gps=samples.filter((p:any)=>p.latitude!==null);
  if (response.status!==200 || gps.length<40 || !samples.some((p:any)=>p.speedKph>0)) throw new Error('Dense API series missing');
  if (gps.some((p:any,i:number)=>i>0 && +new Date(p.t)-+new Date(gps[i-1].t)>2000)) throw new Error('Dense cadence missing');
  if (result.telemetry.source!=='fleet_telemetry' || result.telemetry.truncated) throw new Error('Invalid provenance');
  stage='charge-shape';
  const [chargeWindow]=await owner`SELECT min(source_ts) AS start,max(source_ts) AS finish FROM volta_telemetry.samples
    WHERE vehicle_id=2 AND field='ACChargingPower' AND NOT invalid`;
  if (!chargeWindow?.start || !chargeWindow.finish) throw new Error('Streamed charge observations required');
  await owner`UPDATE public.charging_processes SET car_id=2,start_date=${chargeWindow.start},end_date=${chargeWindow.finish} WHERE id=1`;
  const chargeResponse=await fetch(base+'/v1/charges/1',{headers:{Authorization:`Bearer ${token}`}});
  const charge=await chargeResponse.json() as any;
  if (chargeResponse.status!==200 || !charge.telemetry?.samples.some((p:any)=>p.powerKw>0)) throw new Error('Charge series missing');
  console.log(JSON.stringify({receiverToAPI:'PASS',samples:samples.length,chargeSamples:charge.telemetry.samples.length,maxGPSIntervalSeconds:2}));
} catch (error) {
  // Raw Postgres errors can contain fixture locations and credentials too.
  console.error('receiver-to-API acceptance failed: '+stage);
  if (typeof error==='object' && error && 'code' in error && typeof error.code==='string' && /^[0-9A-Z]{5}$/.test(error.code)) console.error('SQLSTATE '+error.code);
  process.exitCode=1;
} finally {
  http?.stop(true);
  await Promise.all([owner.end(),reader.end()]);
}
