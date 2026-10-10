import type { Row } from './db';

export type Span = { start: Date; end: Date; reason: string };
/** Ingestion writes one disconnected/silence row per inter-payload span, so a
 * row's length IS the sample silence. A connected stream still emits 0.5-30s
 * cadence rows whenever connectivity last read DISCONNECTED; parked heartbeats
 * reach 30s. Only silence of a minute or more is lost data. Never coalesce
 * before thresholding: contiguous cadence rows would become one false outage. */
export const lossMs = 60000;
export const lossGap = (g: { reason: string }) => g.reason === 'disconnected' || g.reason === 'silence';
/** Coverage and Park-stop joins also distrust unknown gear; charge state is irrelevant. */
export const coverageGap = (g: { reason: string }) => g.reason !== 'charge_invalid';
/** Idempotent: real loss rows coalesced across <=1s seams, invalid spans kept.
 * SQL prefilters repeat the row rule inline so callers never transfer the flood:
 * (reason NOT IN ('disconnected','silence') OR end_ts-start_ts>=interval '60 seconds'). */
export function realGaps(rows: Row[]): Span[] {
  const spans: Span[] = rows.map(g => ({start:new Date(g.start),end:new Date(g.end),reason:String(g.reason)}));
  const out: Span[] = [];
  for (const g of spans.filter(g => lossGap(g) && +g.end-+g.start>=lossMs).sort((a,b) => +a.start-+b.start)) {
    const last = out.at(-1);
    if (last && +g.start-+last.end<=1000) { if (+g.end>+last.end) last.end=g.end; } else out.push({...g});
  }
  return [...out,...spans.filter(g => !lossGap(g))].sort((a,b) => +a.start-+b.start || a.reason.localeCompare(b.reason));
}
/** Real data loss strictly between two instants. */
export const lostBetween = (gaps: Span[], a: Date, b: Date) => gaps.some(g => lossGap(g) && +g.start<+b && +g.end>+a);
