import type { DB, Row } from './db';
import { invalid } from './errors';
import { timestamp, timeZone } from './validation';

/** Tyre pressure history from TeslaMate `positions.tpms_pressure_*` (bar, one
 * decimal). Read-only: one SELECT, no writes, no Tesla calls. Each wheel is
 * thinned to one point per local calendar day (or ISO week for long spans)
 * holding that bucket's lowest, mean and highest reading, plus a comparison
 * with the other wheels read at the same moment. A bucket without a
 * reading is absent, never zero and never interpolated, so a gap in the record
 * stays a gap and a wheel whose sensor never reported has no points. */
export const wheels = ['fl', 'fr', 'rl', 'rr'] as const;
export type Wheel = typeof wheels[number];
export type TireBucket = 'day' | 'week';

/** Spans longer than this are drawn in weeks (about 60 points a year). */
export const maxDailySpanDays = 400;
/** TeslaMate stores bar. Zero, negative or impossible values mean the sensor
 * had no reading, so they are dropped rather than plotted as pressure. */
export const plausibleBar = { above: 0, atMost: 10 } as const;

export type TireInput = { from: string | null; to: string | null; timeZone: string };
/** `peer*` compare each reading with the other wheels read in the same
 * positions row (see `read`): `peerReadings` rows had at least two other
 * plausible wheels, `peerDeltaBar` is this wheel minus their mean, averaged
 * over those rows, and `peerBar` is that mean of the others. Both are null when
 * `peerReadings` is 0. `peerWheels` is how many other wheels read in every one
 * of those rows (2 or 3), null when it varied between rows or there were none,
 * so a client never names more tyres than took part. */
export type TirePoint = { start: Date; minBar: number; avgBar: number; maxBar: number; readings: number; firstAt: Date; lastAt: Date;
  peerReadings: number; peerDeltaBar: number | null; peerBar: number | null; peerWheels: number | null };

export function tireInput(query: Record<string, string | undefined>): TireInput {
  const from = timestamp(query.from), to = timestamp(query.to);
  if (from && to && from >= to) throw invalid('from must precede to');
  return { from, to, timeZone: timeZone(query.tz) };
}

/** Days for a known span, weeks beyond `maxDailySpanDays`. */
export function bucketFor(start: Date | null, end: Date): TireBucket {
  if (!start) return 'day';
  return +end - +start > maxDailySpanDays * 86_400_000 ? 'week' : 'day';
}

export class TireHistory {
  constructor(private sql: DB, private clock: () => Date = () => new Date()) {}

  async read(id: number, input: TireInput) {
    const s = this.sql, now = this.clock(), end = input.to ?? now.toISOString();
    // `to` defaults to now, so a `from` after now is as wrong as one after `to`.
    // An explicit `to` was already compared at full precision by tireInput.
    if (input.from && !input.to && +new Date(input.from) >= +now) throw invalid('from must precede to');
    // positions.date is UTC without a zone. Buckets start at local midnight
    // (or local Monday) in the caller's zone, returned as UTC instants.
    // One positions row is one moment: all four sensors read together. A wheel
    // value's peer is the mean of the other plausible values in that same row,
    // used only when at least two others are present, so the comparison is
    // always contemporaneous. Rows stream straight into one summary per local
    // day holding every wheel's sums and counts; no row-level or per-wheel
    // expansion is materialised. Only those day summaries (`days`) are
    // referenced twice, then unpivoted to wheels. Weeks are built from day sums
    // and counts, never from day means. Plausibility is tested on the stored
    // numeric; arithmetic is float8. Each `OFFSET 0` keeps PostgreSQL from
    // flattening a level and copying its CASE expressions into every aggregate
    // (measured 4x slower over a full history); the levels still stream.
    const rows = await s`WITH days AS (
        SELECT day, min(at) FILTER (WHERE present > 0) AS first_at,
          min(fl) AS fl_min, max(fl) AS fl_max, sum(fl) AS fl_sum, count(fl) AS fl_n,
          min(at) FILTER (WHERE fl IS NOT NULL) AS fl_first, max(at) FILTER (WHERE fl IS NOT NULL) AS fl_last,
          count(fl_peer) AS fl_peer_n, sum(fl - fl_peer) AS fl_delta, sum(fl_peer) AS fl_peer_sum,
          min(present) FILTER (WHERE fl_peer IS NOT NULL) AS fl_peer_pmin, max(present) FILTER (WHERE fl_peer IS NOT NULL) AS fl_peer_pmax,
          min(fr) AS fr_min, max(fr) AS fr_max, sum(fr) AS fr_sum, count(fr) AS fr_n,
          min(at) FILTER (WHERE fr IS NOT NULL) AS fr_first, max(at) FILTER (WHERE fr IS NOT NULL) AS fr_last,
          count(fr_peer) AS fr_peer_n, sum(fr - fr_peer) AS fr_delta, sum(fr_peer) AS fr_peer_sum,
          min(present) FILTER (WHERE fr_peer IS NOT NULL) AS fr_peer_pmin, max(present) FILTER (WHERE fr_peer IS NOT NULL) AS fr_peer_pmax,
          min(rl) AS rl_min, max(rl) AS rl_max, sum(rl) AS rl_sum, count(rl) AS rl_n,
          min(at) FILTER (WHERE rl IS NOT NULL) AS rl_first, max(at) FILTER (WHERE rl IS NOT NULL) AS rl_last,
          count(rl_peer) AS rl_peer_n, sum(rl - rl_peer) AS rl_delta, sum(rl_peer) AS rl_peer_sum,
          min(present) FILTER (WHERE rl_peer IS NOT NULL) AS rl_peer_pmin, max(present) FILTER (WHERE rl_peer IS NOT NULL) AS rl_peer_pmax,
          min(rr) AS rr_min, max(rr) AS rr_max, sum(rr) AS rr_sum, count(rr) AS rr_n,
          min(at) FILTER (WHERE rr IS NOT NULL) AS rr_first, max(at) FILTER (WHERE rr IS NOT NULL) AS rr_last,
          count(rr_peer) AS rr_peer_n, sum(rr - rr_peer) AS rr_delta, sum(rr_peer) AS rr_peer_sum,
          min(present) FILTER (WHERE rr_peer IS NOT NULL) AS rr_peer_pmin, max(present) FILTER (WHERE rr_peer IS NOT NULL) AS rr_peer_pmax
        FROM (
          SELECT at, day, present, fl, fr, rl, rr,
            CASE WHEN present >= 3 THEN (total - fl) / (present - 1)::float8 END AS fl_peer,
            CASE WHEN present >= 3 THEN (total - fr) / (present - 1)::float8 END AS fr_peer,
            CASE WHEN present >= 3 THEN (total - rl) / (present - 1)::float8 END AS rl_peer,
            CASE WHEN present >= 3 THEN (total - rr) / (present - 1)::float8 END AS rr_peer
          FROM (
            SELECT at, date_trunc('day', at AT TIME ZONE ${input.timeZone}) AS day, fl, fr, rl, rr, num_nonnulls(fl, fr, rl, rr) AS present,
              COALESCE(fl, 0) + COALESCE(fr, 0) + COALESCE(rl, 0) + COALESCE(rr, 0) AS total
            FROM (
              SELECT p.date AT TIME ZONE 'UTC' AS at,
                CASE WHEN p.tpms_pressure_fl > ${plausibleBar.above}::numeric AND p.tpms_pressure_fl <= ${plausibleBar.atMost}::numeric THEN p.tpms_pressure_fl::float8 END AS fl,
                CASE WHEN p.tpms_pressure_fr > ${plausibleBar.above}::numeric AND p.tpms_pressure_fr <= ${plausibleBar.atMost}::numeric THEN p.tpms_pressure_fr::float8 END AS fr,
                CASE WHEN p.tpms_pressure_rl > ${plausibleBar.above}::numeric AND p.tpms_pressure_rl <= ${plausibleBar.atMost}::numeric THEN p.tpms_pressure_rl::float8 END AS rl,
                CASE WHEN p.tpms_pressure_rr > ${plausibleBar.above}::numeric AND p.tpms_pressure_rr <= ${plausibleBar.atMost}::numeric THEN p.tpms_pressure_rr::float8 END AS rr
              FROM public.positions p
              WHERE p.car_id = ${id}
                AND (${input.from}::timestamptz IS NULL OR p.date >= ${input.from}::timestamptz AT TIME ZONE 'UTC')
                AND p.date < ${end}::timestamptz AT TIME ZONE 'UTC'
              OFFSET 0
            ) plausible
            OFFSET 0
          ) counted
          OFFSET 0
        ) r
        GROUP BY day
      ), span AS (
        SELECT CASE WHEN ${end}::timestamptz - COALESCE(${input.from}::timestamptz, min(first_at)) > make_interval(days => ${maxDailySpanDays}::integer)
                    THEN 'week' ELSE 'day' END AS bucket FROM days
      )
      SELECT w.wheel, span.bucket, date_trunc(span.bucket, d.day) AT TIME ZONE ${input.timeZone} AS start,
        min(w.min_bar) AS "minBar", sum(w.bar_sum) / sum(w.n)::float8 AS "avgBar", max(w.max_bar) AS "maxBar",
        sum(w.n)::integer AS readings, min(w.first_at) AS "firstAt", max(w.last_at) AS "lastAt",
        sum(w.peer_n)::integer AS "peerReadings", sum(w.delta_sum) / NULLIF(sum(w.peer_n), 0)::float8 AS "peerDeltaBar",
        sum(w.peer_sum) / NULLIF(sum(w.peer_n), 0)::float8 AS "peerBar",
        (CASE WHEN min(w.peer_pmin) = max(w.peer_pmax) THEN min(w.peer_pmin) - 1 END)::integer AS "peerWheels"
      FROM days d
      CROSS JOIN LATERAL (VALUES ('fl', fl_min, fl_max, fl_sum, fl_n, fl_first, fl_last, fl_peer_n, fl_delta, fl_peer_sum, fl_peer_pmin, fl_peer_pmax),
                                 ('fr', fr_min, fr_max, fr_sum, fr_n, fr_first, fr_last, fr_peer_n, fr_delta, fr_peer_sum, fr_peer_pmin, fr_peer_pmax),
                                 ('rl', rl_min, rl_max, rl_sum, rl_n, rl_first, rl_last, rl_peer_n, rl_delta, rl_peer_sum, rl_peer_pmin, rl_peer_pmax),
                                 ('rr', rr_min, rr_max, rr_sum, rr_n, rr_first, rr_last, rr_peer_n, rr_delta, rr_peer_sum, rr_peer_pmin, rr_peer_pmax))
        AS w(wheel, min_bar, max_bar, bar_sum, n, first_at, last_at, peer_n, delta_sum, peer_sum, peer_pmin, peer_pmax)
      CROSS JOIN span
      WHERE w.n > 0
      GROUP BY w.wheel, span.bucket, 3 ORDER BY w.wheel, 3`;
    const series = Object.fromEntries(wheels.map(w => [w, [] as TirePoint[]])) as Record<Wheel, TirePoint[]>;
    for (const row of rows as Row[]) {
      series[row.wheel as Wheel].push({ start: new Date(row.start), minBar: row.minBar, avgBar: row.avgBar, maxBar: row.maxBar,
        readings: row.readings, firstAt: new Date(row.firstAt), lastAt: new Date(row.lastAt),
        peerReadings: row.peerReadings, peerDeltaBar: row.peerDeltaBar, peerBar: row.peerBar, peerWheels: row.peerWheels });
    }
    const all = wheels.flatMap(w => series[w]);
    const first = all.length ? new Date(Math.min(...all.map(p => +p.firstAt))) : null;
    const last = all.length ? new Date(Math.max(...all.map(p => +p.lastAt))) : null;
    return {
      vehicleId: id, source: 'teslamate', unit: 'bar',
      bucket: (rows[0]?.bucket as TireBucket | undefined) ?? bucketFor(input.from ? new Date(input.from) : null, new Date(end)),
      timeZone: input.timeZone, from: input.from ? new Date(input.from) : null, to: new Date(end),
      firstReadingAt: first, lastReadingAt: last, wheels: series,
    };
  }
}
