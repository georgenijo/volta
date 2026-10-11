import { expect, test } from 'bun:test';
import { boundSeries, driveCharts, seedValues, stepSeries } from '../src/drive-charts';

const at=(s:number)=>new Date(Date.UTC(2026,0,2)+s*1000);
const start=at(0),end=at(600);

test('step series forward-fills: change-only points and a final point at the end',()=>{
  const obs=[{t:at(10),v:5},{t:at(20),v:5},{t:at(30),v:6},{t:at(40),v:6}];
  expect(stepSeries(obs,start,end)).toEqual([{t:at(10),v:5},{t:at(30),v:6},{t:end,v:6}]);
  // An observation exactly at the end is the final point.
  expect(stepSeries([{t:at(10),v:1},{t:end,v:2}],start,end)).toEqual([{t:at(10),v:1},{t:end,v:2}]);
  expect(stepSeries([],start,end)).toEqual([]);
});

test('seed: the last value before the start opens the series unless an observation is at the start',()=>{
  expect(stepSeries([{t:at(60),v:20}],start,end,18)).toEqual([{t:start,v:18},{t:at(60),v:20},{t:end,v:20}]);
  expect(stepSeries([{t:start,v:21}],start,end,18)).toEqual([{t:start,v:21},{t:end,v:21}]);
  // A seed alone is a flat line across the whole drive.
  expect(stepSeries([],start,end,18)).toEqual([{t:start,v:18},{t:end,v:18}]);
  const rows=[{key:'outsideTempC',source_ts:at(-3600),v:12.04},{key:'insideTempC',source_ts:at(-12*3600-1),v:20},
    {key:'batteryLevel',source_ts:at(-60),v:null},{key:'ratedRangeKm',source_ts:at(-100),v:300}];
  expect(seedValues(rows,start,[])).toEqual({outsideTempC:12,ratedRangeKm:300});
  // Never across real data loss: the car resends every field when the stream resumes.
  expect(seedValues(rows,start,[{start:at(-3000),end:at(-2000),reason:'disconnected'}])).toEqual({ratedRangeKm:300});
  expect(seedValues(rows,start,[{start:at(-3000),end:at(-2000),reason:'charge_invalid'}])).toEqual({outsideTempC:12,ratedRangeKm:300});
});

test('no gap rule: data loss and long silences never break or end a series; invalid readings hold the step',()=>{
  const samples=[{source_ts:at(0),inside_temp_c:20},{source_ts:at(30),inside_temp_c:null,invalid_fields:['InsideTemp']},
    {source_ts:at(500),inside_temp_c:22}];
  const charts=driveCharts(start,end,samples,{});
  expect(charts.series.insideTempC).toEqual([{t:at(0),v:20},{t:at(500),v:22},{t:end,v:22}]);
  expect(charts.start).toEqual(start);expect(charts.end).toEqual(end);
  // Power is unknown while pack voltage/current is invalid, even if a value is present.
  const power=driveCharts(start,end,[{source_ts:at(0),power_kw:10},{source_ts:at(10),power_kw:99,invalid_fields:['PackCurrent']},{source_ts:at(20),power_kw:-5}],{});
  expect(power.series.powerKw).toEqual([{t:at(0),v:10},{t:at(20),v:-5},{t:end,v:-5}]);
});

test('empty metrics are omitted entirely and values are rounded before change detection',()=>{
  const charts=driveCharts(start,end,[{source_ts:at(0),speed_kph:48.28032,battery_level:null},{source_ts:at(10),speed_kph:48.31}],{});
  expect(Object.keys(charts.series)).toEqual(['speedKph']);
  expect(charts.series.speedKph).toEqual([{t:at(0),v:48.3},{t:end,v:48.3}]);
  expect(driveCharts(start,end,[],{}).series).toEqual({});
});

test('dense speed and power are bounded to 600 points keeping extremes, endpoints and order',()=>{
  const points=Array.from({length:5000},(_,i)=>({t:at(i*.1),v:Math.sin(i/7)*50+(i===2345 ? 400 : 0)+(i===3456 ? -300 : 0)}));
  const out=boundSeries([...points,{t:end,v:points.at(-1)!.v}]);
  expect(out.length).toBeLessThanOrEqual(600);expect(out[0]).toEqual(points[0]!);expect(out.at(-1)!.t).toEqual(end);
  expect(Math.max(...out.map(p=>p.v))).toBeCloseTo(Math.max(...points.map(p=>p.v)));
  expect(Math.min(...out.map(p=>p.v))).toBeCloseTo(Math.min(...points.map(p=>p.v)));
  expect(out.every((p,i)=>!i || +p.t>=+out[i-1]!.t)).toBe(true);
  const dense=Array.from({length:3000},(_,i)=>({source_ts:at(i*.2),speed_kph:i%2 ? 10 : 20,power_kw:i}));
  const charts=driveCharts(start,end,dense,{});
  expect(charts.series.speedKph!.length).toBeLessThanOrEqual(600);expect(charts.series.powerKw!.length).toBeLessThanOrEqual(600);
  expect(charts.series.powerKw!.at(-1)).toEqual({t:end,v:2999});
});
