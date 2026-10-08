import { createHash } from 'node:crypto';
import type { DB } from './db';

const sampleLimit = 2000, gapLimit = 2000;

/** Reads only private recorded history. No Tesla request, geocoder or elevation API. */
export class FleetSeries {
  constructor(private sql: DB) {}

  async session(kind: 'drive' | 'charge', id: number) {
    const s = this.sql;
    const [session] = kind === 'drive'
      ? await s`SELECT car_id, start_date AS start, COALESCE(end_date, now() AT TIME ZONE 'UTC') AS finish FROM public.drives WHERE id=${id}`
      : await s`SELECT car_id, start_date AS start, COALESCE(end_date, now() AT TIME ZONE 'UTC') AS finish FROM public.charging_processes WHERE id=${id}`;
    if (!session) return null;
    const [binding] = await s`SELECT b.vin_digest,c.vin FROM volta_telemetry.api_vehicle_bindings b
      JOIN public.cars c ON c.id=b.vehicle_id WHERE b.vehicle_id=${session.car_id}`;
    // A bad operator mapping must never attach another car's history.
    if (!binding?.vin || !/^[A-HJ-NPR-Z0-9]{17}$/.test(binding.vin)) return null;
    const digest = createHash('sha256').update('volta-telemetry-vin-binding-v1\0').update(binding.vin,'utf8').digest('hex');
    if (binding.vin_digest !== digest) return null;

    const power = kind === 'drive' ? s`CASE
      WHEN 'PackCurrent'=ANY(COALESCE(p.invalid_fields,ARRAY[]::text[]))
        OR 'PackVoltage'=ANY(COALESCE(p.invalid_fields,ARRAY[]::text[])) THEN NULL
      ELSE p.power_kw END` : s`CASE
      WHEN p.dc_power_kw>0 AND NOT ('DCChargingPower'=ANY(COALESCE(p.invalid_fields,ARRAY[]::text[]))) THEN p.dc_power_kw
      WHEN p.ac_power_kw>0 AND NOT ('ACChargingPower'=ANY(COALESCE(p.invalid_fields,ARRAY[]::text[]))) THEN p.ac_power_kw
      WHEN p.dc_power_kw=0 AND p.ac_power_kw=0
        AND NOT ('DCChargingPower'=ANY(COALESCE(p.invalid_fields,ARRAY[]::text[])))
        AND NOT ('ACChargingPower'=ANY(COALESCE(p.invalid_fields,ARRAY[]::text[]))) THEN 0
      ELSE NULL END`;
    const base = s`SELECT p.source_ts AS t,p.latitude,p.longitude,p.speed_kph AS "speedKph",
      ${power} AS "powerKw",e.elevation AS "elevationM",p.battery_level AS "batteryLevel",
      p.energy_remaining_kwh AS "energyRemainingKwh",p.battery_temp_min_c AS "batteryTempMinC",
      p.battery_temp_max_c AS "batteryTempMaxC",p.inside_temp_c AS "insideTempC",p.outside_temp_c AS "outsideTempC",
      p.voltage,p.current_a AS "currentA",p.rated_range_km AS "ratedRangeKm",
      p.longitudinal_acceleration_mps2 AS "longitudinalAccelerationMps2",p.lateral_acceleration_mps2 AS "lateralAccelerationMps2",
      false AS "routeBreakBefore",COALESCE(p.invalid_fields,ARRAY[]::text[]) AS "invalidFields"
      FROM volta_telemetry.session_samples p
      LEFT JOIN LATERAL (
        -- Reuse TeslaMate's SRTM elevation only at a nearby recorded location
        -- within 60 seconds. No interpolation across a sparse route.
        SELECT elevation FROM public.positions tm WHERE ${kind === 'drive'} AND tm.drive_id=${id}
          AND tm.elevation IS NOT NULL AND p.latitude IS NOT NULL AND p.longitude IS NOT NULL
          AND tm.date BETWEEN (p.source_ts AT TIME ZONE 'UTC')-interval '60 seconds' AND (p.source_ts AT TIME ZONE 'UTC')+interval '60 seconds'
          AND 6371000*2*asin(least(1.0,sqrt(power(sin(radians((tm.latitude-p.latitude)/2)),2)
            +cos(radians(p.latitude))*cos(radians(tm.latitude))*power(sin(radians((tm.longitude-p.longitude)/2)),2))))<=50
        ORDER BY abs(extract(epoch FROM tm.date-(p.source_ts AT TIME ZONE 'UTC'))),tm.id LIMIT 1
      ) e ON true
      WHERE p.vehicle_id=${session.car_id} AND p.source_ts>=${session.start}::timestamp AT TIME ZONE 'UTC'
        AND p.source_ts<=${session.finish}::timestamp AT TIME ZONE 'UTC'`;

    // Preserve every metric's temporal boundaries and extrema, then spend the
    // remaining row budget over time buckets with a representative for every
    // metric present in each bucket, then fill unused slots evenly. Coverage is
    // calculated before selection, so downsampling never masquerades as a
    // short or sparse source series.
    const rows = await s`WITH base AS MATERIALIZED (${base}),
      numbered AS MATERIALIZED (
        SELECT b.*,row_number() OVER(ORDER BY t) AS rn,count(*) OVER() AS total FROM base b
      ), metric_values AS MATERIALIZED (
        SELECT n.rn,n.t,m.key,(m.value#>>'{}')::double precision AS value
        FROM numbered n CROSS JOIN LATERAL jsonb_each(to_jsonb(n)-'rn'-'total'-'t'-'invalidFields'-'routeBreakBefore') m
        WHERE jsonb_typeof(m.value)='number'
      ), invalid_metric_rows AS MATERIALIZED (
        SELECT DISTINCT n.rn,n.t,m.key
        FROM numbered n CROSS JOIN LATERAL unnest(n."invalidFields") f(field)
        CROSS JOIN LATERAL (SELECT CASE
          WHEN f.field='VehicleSpeed' THEN 'speedKph'
          WHEN f.field='BatteryLevel' THEN 'batteryLevel'
          WHEN f.field='EnergyRemaining' THEN 'energyRemainingKwh'
          WHEN f.field='ModuleTempMin' THEN 'batteryTempMinC'
          WHEN f.field='ModuleTempMax' THEN 'batteryTempMaxC'
          WHEN f.field='InsideTemp' THEN 'insideTempC'
          WHEN f.field='OutsideTemp' THEN 'outsideTempC'
          WHEN f.field='ChargerVoltage' THEN 'voltage'
          WHEN f.field='ChargeAmps' THEN 'currentA'
          WHEN f.field='RatedRange' THEN 'ratedRangeKm'
          WHEN f.field='LongitudinalAcceleration' THEN 'longitudinalAccelerationMps2'
          WHEN f.field='LateralAcceleration' THEN 'lateralAccelerationMps2'
          WHEN ${kind==='drive'} AND f.field IN ('PackCurrent','PackVoltage') THEN 'powerKw'
          WHEN ${kind==='charge'} AND n."powerKw" IS NULL
            AND f.field IN ('ACChargingPower','DCChargingPower') THEN 'powerKw'
        END AS key) m
        WHERE m.key IS NOT NULL
      ), metric_events AS MATERIALIZED (
        SELECT rn,t,key,false AS invalid FROM metric_values
        UNION ALL SELECT rn,t,key,true FROM invalid_metric_rows
      ), metric_event_neighbors AS (
        SELECT me.*,lag(rn) OVER(PARTITION BY key ORDER BY t,rn) AS prior_rn,
          lead(rn) OVER(PARTITION BY key ORDER BY t,rn) AS next_rn,
          lag(invalid,1,false) OVER(PARTITION BY key ORDER BY t,rn) AS prior_invalid
        FROM metric_events me
      ), invalid_boundary_rows AS MATERIALIZED (
        SELECT key,rn FROM metric_event_neighbors WHERE invalid
        UNION SELECT key,prior_rn FROM metric_event_neighbors WHERE invalid AND prior_rn IS NOT NULL
        UNION SELECT key,next_rn FROM metric_event_neighbors WHERE invalid AND next_rn IS NOT NULL
      ), invalid_run_stats AS MATERIALIZED (
        SELECT key,count(*) FILTER(WHERE invalid AND NOT prior_invalid)::integer AS count
        FROM metric_event_neighbors GROUP BY key
      ), metric_ranked AS (
        SELECT mv.*,
          row_number() OVER(PARTITION BY key ORDER BY t,rn) AS first_rank,
          row_number() OVER(PARTITION BY key ORDER BY t DESC,rn DESC) AS last_rank,
          row_number() OVER(PARTITION BY key ORDER BY value,t,rn) AS min_rank,
          row_number() OVER(PARTITION BY key ORDER BY value DESC,t,rn) AS max_rank
        FROM metric_values mv
      ), essential AS MATERIALIZED (
        SELECT DISTINCT rn FROM metric_ranked
        WHERE first_rank=1 OR last_rank=1 OR min_rank=1 OR max_rank=1
        UNION SELECT min(rn) FROM numbered
        UNION SELECT max(rn) FROM numbered
      ), invalid_ids AS MATERIALIZED (
        SELECT DISTINCT rn FROM invalid_boundary_rows
      ), invalid_numbered AS (
        SELECT i.rn,row_number() OVER(ORDER BY i.rn) AS seq,count(*) OVER() AS total,
          greatest(0,${sampleLimit}-(SELECT count(*) FROM essential WHERE rn IS NOT NULL))::integer AS capacity
        FROM invalid_ids i WHERE i.rn NOT IN (SELECT rn FROM essential WHERE rn IS NOT NULL)
      ), invalid_bucketed AS (
        SELECT i.*,floor((seq-1)*least(total,capacity)/greatest(total,1))::integer AS bucket
        FROM invalid_numbered i WHERE capacity>0
      ), selected_invalid AS (
        SELECT rn FROM (SELECT ib.*,row_number() OVER(PARTITION BY bucket ORDER BY rn) AS bucket_rank FROM invalid_bucketed ib) ranked
        WHERE bucket_rank=1
      ), mandatory AS MATERIALIZED (
        SELECT rn FROM essential WHERE rn IS NOT NULL
        UNION ALL SELECT rn FROM selected_invalid
      ), capacity AS (
        SELECT greatest(0,${sampleLimit}-count(*))::integer AS n FROM mandatory WHERE rn IS NOT NULL
      ), source_bounds AS MATERIALIZED (
        SELECT min(t) AS start,max(t) AS finish FROM numbered
      ), representative_capacity AS (
        -- A generic row plus at most one row per metric in each bucket cannot
        -- exceed the remaining budget, even when fields arrive separately.
        SELECT c.n/(1+(SELECT count(DISTINCT key) FROM metric_values))::integer AS n
        FROM capacity c
      ), remaining AS MATERIALIZED (
        SELECT n.rn,CASE WHEN b.finish>b.start THEN least(c.n-1,
            greatest(0,width_bucket(extract(epoch FROM n.t)::double precision,
              extract(epoch FROM b.start)::double precision,extract(epoch FROM b.finish)::double precision,c.n)-1))
            ELSE 0 END AS bucket
        FROM numbered n CROSS JOIN representative_capacity c CROSS JOIN source_bounds b
        WHERE n.rn NOT IN (SELECT rn FROM mandatory WHERE rn IS NOT NULL) AND c.n>0
      ), bucket_representatives AS MATERIALIZED (
        SELECT DISTINCT ON(bucket) rn FROM remaining ORDER BY bucket,rn
      ), metric_representatives AS MATERIALIZED (
        -- Bucket metric observations directly. Joining two materialized
        -- full-history CTEs can become quadratic before autovacuum ANALYZE.
        SELECT DISTINCT ON(bucket,mv.key) mv.rn
        FROM metric_values mv CROSS JOIN representative_capacity c CROSS JOIN source_bounds b
        CROSS JOIN LATERAL (SELECT CASE WHEN b.finish>b.start THEN least(c.n-1,
          greatest(0,width_bucket(extract(epoch FROM mv.t)::double precision,
            extract(epoch FROM b.start)::double precision,extract(epoch FROM b.finish)::double precision,c.n)-1))
          ELSE 0 END AS bucket) grid
        WHERE mv.rn NOT IN (SELECT rn FROM mandatory WHERE rn IS NOT NULL) AND c.n>0
        ORDER BY bucket,mv.key,mv.rn
      ), representatives AS MATERIALIZED (
        SELECT rn FROM bucket_representatives UNION SELECT rn FROM metric_representatives
      ), fill_capacity AS (
        -- Do not turn buckets without extra observations into more buckets
        -- for a dense burst: the two temporal grids share the original budget.
        SELECT least(c.n-(SELECT count(*) FROM representatives)::integer,c.n-r.n) AS n
        FROM capacity c CROSS JOIN representative_capacity r
      ), fill_remaining AS (
        SELECT n.rn,CASE WHEN b.finish>b.start THEN least(c.n-1,
            greatest(0,width_bucket(extract(epoch FROM n.t)::double precision,
              extract(epoch FROM b.start)::double precision,extract(epoch FROM b.finish)::double precision,c.n)-1))
            ELSE 0 END AS bucket
        FROM numbered n CROSS JOIN fill_capacity c CROSS JOIN source_bounds b
        WHERE n.rn NOT IN (SELECT rn FROM mandatory WHERE rn IS NOT NULL)
          AND n.rn NOT IN (SELECT rn FROM representatives WHERE rn IS NOT NULL) AND c.n>0
      ), even_rows AS (
        SELECT DISTINCT ON(bucket) rn FROM fill_remaining ORDER BY bucket,rn
      ), selected_ids AS MATERIALIZED (
        SELECT rn FROM mandatory WHERE rn IS NOT NULL
        UNION ALL SELECT rn FROM representatives
        UNION ALL SELECT rn FROM even_rows
      ), selected_points AS MATERIALIZED (
        SELECT n.*,row_number() OVER(ORDER BY n.t,n.rn) AS "selectedOrder"
        FROM numbered n
        -- Keep membership as a hashed subplan even with stale row estimates.
        WHERE (n.rn IN (SELECT rn FROM selected_ids)) IS TRUE
      ), returned_metric_values AS MATERIALIZED (
        SELECT p.rn,p.t,m.key
        FROM selected_points p CROSS JOIN LATERAL jsonb_each(to_jsonb(p)-'rn'-'total'-'selectedOrder'-'t'-'invalidFields'-'routeBreakBefore') m
        WHERE jsonb_typeof(m.value)='number'
      ), returned_metric_ordered AS (
        SELECT rv.*,lag(t) OVER(PARTITION BY key ORDER BY t,rn) AS prior FROM returned_metric_values rv
      ), returned_metric_stats AS (
        SELECT key,count(*)::integer AS count,max(extract(epoch FROM(t-prior))) AS max_interval_seconds
        FROM returned_metric_ordered GROUP BY key
      ), ordered_metrics AS (
        SELECT mv.*,lag(t) OVER(PARTITION BY key ORDER BY t,rn) AS prior FROM metric_values mv
      ), session_gaps AS MATERIALIZED (
        SELECT greatest(start_ts,${session.start}::timestamp AT TIME ZONE 'UTC') AS start,
          least(end_ts,${session.finish}::timestamp AT TIME ZONE 'UTC') AS "end",reason
        FROM volta_telemetry.gaps WHERE vehicle_id=${session.car_id}
          AND start_ts<=${session.finish}::timestamp AT TIME ZONE 'UTC'
          AND end_ts>=${session.start}::timestamp AT TIME ZONE 'UTC'
        ORDER BY start_ts,end_ts,reason
      ), returned_gaps AS MATERIALIZED (
        SELECT * FROM session_gaps ORDER BY start,"end",reason LIMIT ${gapLimit}
      ), metric_stats AS (
        SELECT key,min(t) AS start,max(t) AS "end",count(*)::integer AS source_count,
          max(extract(epoch FROM(t-prior))) AS max_interval_seconds,
          (SELECT count(*)::integer FROM session_gaps g WHERE g.start<=max(om.t) AND g."end">=min(om.t)) AS receiver_gap_count,
          (SELECT count(*)::integer FROM returned_gaps g WHERE g.start<=max(om.t) AND g."end">=min(om.t)) AS returned_receiver_gap_count,
          coalesce((SELECT count FROM invalid_run_stats i WHERE i.key=om.key),0) AS invalid_gap_count,
          (SELECT count(DISTINCT rn)::integer FROM invalid_boundary_rows i WHERE i.key=om.key) AS invalid_boundary_count,
          (SELECT count(DISTINCT i.rn)::integer FROM invalid_boundary_rows i WHERE i.key=om.key AND (i.rn IN (SELECT rn FROM selected_ids)) IS TRUE) AS returned_invalid_boundary_count
        FROM ordered_metrics om GROUP BY key
      ), metric_coverage AS (
        SELECT coalesce(jsonb_object_agg(ms.key,jsonb_build_object(
          'start',ms.start,'end',ms."end",'sourceSampleCount',ms.source_count,
          'returnedSampleCount',coalesce(rc.count,0),
          'densityPerMinute',CASE WHEN extract(epoch FROM(${session.finish}::timestamptz-${session.start}::timestamptz))>0
            THEN ms.source_count*60/extract(epoch FROM(${session.finish}::timestamptz-${session.start}::timestamptz)) END,
          'maxIntervalSeconds',ms.max_interval_seconds,'returnedMaxIntervalSeconds',rc.max_interval_seconds,
          'gapCount',ms.receiver_gap_count+ms.invalid_gap_count,
          'receiverGapCount',ms.receiver_gap_count,'invalidGapCount',ms.invalid_gap_count,
          'downsampled',coalesce(rc.count,0)<ms.source_count,
          'truncated',ms.returned_receiver_gap_count<ms.receiver_gap_count
            OR ms.returned_invalid_boundary_count<ms.invalid_boundary_count
        )), '{}'::jsonb) AS value
        FROM metric_stats ms LEFT JOIN returned_metric_stats rc USING(key)
      ), response_meta AS (
        SELECT jsonb_build_object(
          'coverage',jsonb_build_object(
            'sessionStart',${session.start}::timestamptz,'sessionEnd',${session.finish}::timestamptz,
            'sampleStart',(SELECT min(t) FROM base),'sampleEnd',(SELECT max(t) FROM base),
            'sourceSampleCount',(SELECT count(*) FROM base),
            'returnedSampleCount',(SELECT count(*) FROM selected_points),
            'metrics',(SELECT value FROM metric_coverage)
          ),
          'gaps',coalesce((SELECT jsonb_agg(to_jsonb(g) ORDER BY start,"end",reason) FROM returned_gaps g),'[]'::jsonb),
          'downsampled',(SELECT count(*) FROM selected_points)<(SELECT count(*) FROM base),
          'truncated',(SELECT count(*) FROM returned_gaps)<(SELECT count(*) FROM session_gaps)
        ) AS value
      )
      SELECT p.*,CASE WHEN p."selectedOrder"=1 THEN (SELECT value FROM response_meta) END AS "responseMeta"
      FROM selected_points p ORDER BY p.t,p.rn`;
    if (!rows.length) return null;

    const responseMeta = rows[0]!.responseMeta as any;
    const gaps = (responseMeta.gaps as any[]).map(g => ({...g,start:new Date(g.start),end:new Date(g.end)}));
    const samples = rows.map(row => {
      const {rn: _rn,total: _total,selectedOrder: _selectedOrder,responseMeta: _responseMeta,...point} = row;
      // Defensive nonfinite handling: JSON numbers are measurements or null.
      for (const [key,value] of Object.entries(point)) if (typeof value === 'number' && !Number.isFinite(value)) point[key]=null;
      if (kind==='drive' && point.invalidFields.some((f:string)=>['PackCurrent','PackVoltage'].includes(f))) {
        point.powerKw=null;
        if (!point.invalidFields.includes('Power')) point.invalidFields.push('Power');
      }
      if (kind==='charge' && point.powerKw===null
        && point.invalidFields.some((f:string)=>['ACChargingPower','DCChargingPower'].includes(f))) {
        if (!point.invalidFields.includes('Power')) point.invalidFields.push('Power');
      }
      return point;
    });
    let previousGPS: Date | null = null;
    for (const point of samples) {
      if (point.latitude != null && point.longitude != null) {
        const at = new Date(point.t);
        point.routeBreakBefore = previousGPS !== null && gaps.some(g => +g.start <= +at && +g.end >= +previousGPS!);
        previousGPS = at;
      }
    }
    return { source:'fleet_telemetry' as const,samples,gaps,coverage:responseMeta.coverage,
      downsampled:responseMeta.downsampled as boolean,truncated:responseMeta.truncated as boolean };
  }
}
