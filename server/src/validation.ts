import { invalid } from './errors';
export function integer(value: string | undefined, name: string, fallback?: number, max = 2147483647): number {
  if (value === undefined && fallback !== undefined) return fallback;
  if (!value || !/^[1-9]\d*$/.test(value)) throw invalid(`${name} must be a positive integer`);
  const n = Number(value);
  if (!Number.isSafeInteger(n) || n > max) throw invalid(`${name} is out of range`);
  return n;
}
export function choice<T extends string>(value: string | undefined, values: readonly T[], fallback: T): T {
  if (value === undefined) return fallback;
  if (!values.includes(value as T)) throw invalid(`Expected ${values.join(', ')}`);
  return value as T;
}
export function timeZone(value: string | undefined): string {
  if (value === undefined) return 'UTC';
  // Intl also accepts numeric offsets in some runtimes; the API accepts named zones only.
  if (!value || value.length > 100 || /^[+-]/.test(value)) throw invalid('tz must be an IANA time zone');
  try { return new Intl.DateTimeFormat('en', { timeZone: value }).resolvedOptions().timeZone; }
  catch { throw invalid('tz must be an IANA time zone'); }
}
export function timestamp(value: string | undefined): string | null {
  if (value === undefined) return null;
  if (!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z$/.test(value)) throw invalid('Dates must be ISO-8601 UTC timestamps');
  const date = new Date(value);
  if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 19) !== value.slice(0, 19)) throw invalid('Invalid date');
  const fraction = value.slice(19, -1).replace(/^\./, '').padEnd(6, '0');
  return `${value.slice(0, 19)}.${fraction}Z`;
}
export type ListInput = { from: string | null; to: string | null; limit: number; before: string | null; beforeId: number | null; minMinutes: number };
export function listInput(query: Record<string, string>, scope: string): ListInput {
  const from = timestamp(query.from), to = timestamp(query.to);
  if (from && to && from >= to) throw invalid('from must precede to');
  let before: string | null = null, beforeId: number | null = null;
  if (query.cursor !== undefined) {
    if (query.cursor.length > 1024 || !/^[A-Za-z0-9_-]+$/.test(query.cursor)) throw invalid('Invalid cursor');
    try {
      const decoded = JSON.parse(Buffer.from(query.cursor, 'base64url').toString());
      if (decoded.scope !== scope || decoded.from !== from || decoded.to !== to || decoded.minMinutes !== (query.minMinutes ?? '10')) throw invalid('Cursor belongs to another query');
      if (typeof decoded.start !== 'string' || typeof decoded.id !== 'number') throw invalid('Invalid cursor');
      before = timestamp(decoded.start);
      beforeId = integer(String(decoded.id), 'cursor id', undefined, scope.endsWith('/idles') ? 4294967295 : 2147483647);
      if (!before) throw invalid('Invalid cursor');
    } catch { throw invalid('Invalid cursor'); }
  }
  return { from, to, limit: integer(query.limit, 'limit', 50, 100), before, beforeId, minMinutes: integer(query.minMinutes, 'minMinutes', 10, 10080) };
}
export function page(rows: Record<string, any>[], input: ListInput, scope: string) {
  const selected = rows.slice(0, input.limit), last = selected.at(-1);
  const items = selected.map(({ _cursorStart, ...item }) => item);
  const nextCursor = rows.length > input.limit && last ? Buffer.from(JSON.stringify({ scope, from: input.from, to: input.to, minMinutes: String(input.minMinutes), start: last._cursorStart ?? new Date(last.start).toISOString(), id: last.id })).toString('base64url') : null;
  return { items, nextCursor };
}
