import { randomUUID } from 'node:crypto';
import type { DB, Row } from './db';
import { timestamp } from './validation';
import { invalid, missing } from './errors';

export const serviceDefaults = [
  { name: 'Tire rotation', intervalKm: 6250 * 1.609344, intervalMonths: null },
  { name: 'Cabin air filter', intervalKm: null, intervalMonths: 24 },
  { name: 'Brake fluid check', intervalKm: null, intervalMonths: 48 },
  { name: 'Wiper blades', intervalKm: null, intervalMonths: 12 },
];
export function serviceInput(body: unknown) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw invalid('Expected a service item');
  const b = body as Record<string, unknown>;
  if (typeof b.name !== 'string' || !b.name.trim() || [...b.name.trim()].length > 100 || /[\p{Cc}\p{Cf}]/u.test(b.name)) throw invalid('Name must contain 1–100 characters');
  const intervalKm = b.intervalKm ?? null, intervalMonths = b.intervalMonths ?? null;
  if (intervalKm !== null && (typeof intervalKm !== 'number' || !Number.isFinite(intervalKm) || intervalKm <= 0 || intervalKm > 1000000)) throw invalid('Invalid distance interval');
  if (intervalMonths !== null && (typeof intervalMonths !== 'number' || !Number.isInteger(intervalMonths) || intervalMonths < 1 || intervalMonths > 1200)) throw invalid('Invalid month interval');
  if (intervalKm === null && intervalMonths === null) throw invalid('Set a distance or month interval');
  return { name: b.name.trim(), intervalKm, intervalMonths };
}
export function eventInput(body: unknown, now = new Date()) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw invalid('Expected completion date and odometer');
  const b = body as Record<string, unknown>;
  if (typeof b.completedAt !== 'string' || !/^\d{4}-\d{2}-\d{2}T.*Z$/.test(b.completedAt)) throw invalid('Use a UTC completion timestamp');
  const completedAt = new Date(timestamp(b.completedAt)!);
  if (!Number.isFinite(completedAt.getTime()) || completedAt.toISOString().slice(0,10) > now.toISOString().slice(0,10) || completedAt.getUTCFullYear() < 1970) throw invalid('Invalid completion date');
  const odometerKm = b.odometerKm ?? null;
  if (odometerKm !== null && (typeof odometerKm !== 'number' || !Number.isFinite(odometerKm) || odometerKm < 0 || odometerKm > 10000000)) throw invalid('Invalid odometer');
  return { completedAt, odometerKm };
}
// UTC calendar months, clamped to the last day (Jan 31 + 1 month = Feb 28).
export function addMonths(date: Date, months: number) {
  const out = new Date(date); const day = out.getUTCDate();
  out.setUTCDate(1); out.setUTCMonth(out.getUTCMonth() + months);
  const end = new Date(Date.UTC(out.getUTCFullYear(), out.getUTCMonth() + 1, 0)).getUTCDate();
  out.setUTCDate(Math.min(day, end)); return out;
}
export function due(item: Row, event: Row | undefined, odometer: number | null, now: Date) {
  const date = event?.completedAt ? new Date(event.completedAt) : null;
  const nextDate = date && item.intervalMonths ? addMonths(date, item.intervalMonths) : null;
  const nextKm = event?.odometerKm != null && item.intervalKm != null ? event.odometerKm + item.intervalKm : null;
  const remainingKm = nextKm != null && odometer != null && odometer >= event?.odometerKm ? nextKm - odometer : null;
  const remainingDays = nextDate ? Math.ceil((nextDate.getTime() - now.getTime()) / 86400000) : null;
  const fractions = [remainingKm != null ? 1 - remainingKm / item.intervalKm : null,
    nextDate && date ? (now.getTime() - date.getTime()) / (nextDate.getTime() - date.getTime()) : null].filter((x): x is number => x !== null);
  return { nextDate, nextOdometerKm: nextKm, remainingKm, remainingDays,
    progress: fractions.length ? Math.max(0, Math.min(1, Math.max(...fractions))) : null };
}
export class ServiceLog {
  constructor(private sql: DB) {}
  async list(vehicleID: number, odometer: { odometerKm: number | null; recordedAt: Date | null; source: string | null }, now = new Date()) {
    const items = await this.sql`SELECT id,name,interval_km AS "intervalKm",interval_months AS "intervalMonths" FROM volta.service_items WHERE vehicle_id=${vehicleID} ORDER BY name,id`;
    const events = await this.sql`SELECT e.id,e.item_id AS "itemId",e.completed_at AS "completedAt",e.odometer_km AS "odometerKm" FROM volta.service_events e JOIN volta.service_items i ON i.id=e.item_id WHERE i.vehicle_id=${vehicleID} ORDER BY e.completed_at DESC,e.recorded_at DESC,e.id DESC`;
    return { ...odometer, items: items.map(i => ({ ...i, ...due(i, events.find(e => e.itemId === i.id), odometer.odometerKm, now) })), events };
  }
  async add(vehicleID: number, body: unknown) {
    const i = serviceInput(body), id = randomUUID();
    await this.sql`INSERT INTO volta.service_items(id,vehicle_id,name,interval_km,interval_months) VALUES (${id},${vehicleID},${i.name},${i.intervalKm},${i.intervalMonths})`;
    return { id, ...i };
  }
  async complete(vehicleID: number, itemID: string, body: unknown) {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(itemID)) throw invalid('Invalid service item ID');
    const e = eventInput(body), id = randomUUID();
    const rows = await this.sql`INSERT INTO volta.service_events(id,item_id,completed_at,odometer_km)
      SELECT ${id},id,${e.completedAt},${e.odometerKm} FROM volta.service_items WHERE id=${itemID}::uuid AND vehicle_id=${vehicleID} RETURNING id`;
    if (!rows.length) throw missing();
    return { id, itemId: itemID, ...e };
  }
  private id(value: string) {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) throw invalid('Invalid service ID');
    return value;
  }
  async update(vehicleID: number, itemID: string, body: unknown) {
    const i = serviceInput(body);
    const rows = await this.sql`UPDATE volta.service_items SET name=${i.name},interval_km=${i.intervalKm},interval_months=${i.intervalMonths}
      WHERE vehicle_id=${vehicleID} AND id=${this.id(itemID)}::uuid RETURNING id`;
    if (!rows.length) throw missing();
    return {id:itemID,...i};
  }
  async remove(vehicleID: number, itemID: string) {
    const id = this.id(itemID);
    await this.sql.begin(async transaction => {
      const tx = transaction as unknown as DB;
      const rows = await tx`SELECT id FROM volta.service_items WHERE vehicle_id=${vehicleID} AND id=${id}::uuid FOR UPDATE`;
      if (!rows.length) throw missing();
      await tx`DELETE FROM volta.service_events WHERE item_id=${id}::uuid`;
      await tx`DELETE FROM volta.service_items WHERE id=${id}::uuid`;
    });
  }
  async updateEvent(vehicleID: number, eventID: string, body: unknown) {
    const e = eventInput(body);
    const rows = await this.sql`UPDATE volta.service_events e SET completed_at=${e.completedAt},odometer_km=${e.odometerKm},recorded_at=now()
      FROM volta.service_items i WHERE e.item_id=i.id AND i.vehicle_id=${vehicleID} AND e.id=${this.id(eventID)}::uuid RETURNING e.item_id`;
    if (!rows.length) throw missing();
    return {id:eventID,itemId:rows[0]!.item_id,...e};
  }
  async removeEvent(vehicleID: number, eventID: string) {
    const rows = await this.sql`DELETE FROM volta.service_events e USING volta.service_items i
      WHERE e.item_id=i.id AND i.vehicle_id=${vehicleID} AND e.id=${this.id(eventID)}::uuid RETURNING e.id`;
    if (!rows.length) throw missing();
  }

}
