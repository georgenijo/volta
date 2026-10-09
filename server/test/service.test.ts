import { expect, test } from 'bun:test';
import { addMonths, due, eventInput, serviceInput } from '../src/service';
test('service validation rejects unknown or non-finite intervals', () => {
  expect(serviceInput({name:' Rotation ',intervalKm:10058.4})).toEqual({name:'Rotation',intervalKm:10058.4,intervalMonths:null});
  for (const b of [{name:'Filter'}, {name:'',intervalMonths:24}, {name:'Filter',intervalMonths:1.5}, {name:'Filter',intervalKm:Infinity}, {name:'Filter',intervalKm:-1}]) expect(()=>serviceInput(b)).toThrow();
});
test('completion validates dates and preserves unknown odometer', () => {
  const now=new Date('2026-02-01');
  expect(eventInput({completedAt:'2026-01-01T00:00:00Z'},now).odometerKm).toBeNull();
  for (const b of [{completedAt:'garbage'},{completedAt:'2027-01-01T00:00:00Z'},{completedAt:'2026-01-01T00:00:00Z',odometerKm:-1}]) expect(()=>eventInput(b,now)).toThrow();
});
test('calendar intervals clamp month ends and leap years', () => {
  expect(addMonths(new Date('2024-02-29T00:00:00Z'),24).toISOString()).toBe('2026-02-28T00:00:00.000Z');
  expect(addMonths(new Date('2026-01-31T00:00:00Z'),1).toISOString()).toBe('2026-02-28T00:00:00.000Z');
});
test('unknown baselines stay unknown; earliest interval drives progress', () => {
  const item={intervalKm:1000,intervalMonths:12},now=new Date('2026-07-01');
  expect(due(item,undefined,10000,now)).toMatchObject({remainingKm:null,remainingDays:null,progress:null});
  expect(due(item,{completedAt:'2026-01-01',odometerKm:9000},10100,now)).toMatchObject({remainingKm:-100,progress:1});
});
