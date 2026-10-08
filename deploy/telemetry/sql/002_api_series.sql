-- Additive, read-only API surface. Requires 001_volta_telemetry.sql.
BEGIN;

CREATE OR REPLACE VIEW volta_telemetry.api_vehicle_bindings AS
SELECT vehicle_id, vin_digest FROM volta_telemetry.vehicle_bindings;

-- Resolve per-field conflicts before pivoting. A reported invalid value at
-- the same instant also makes that field unknown. Never carry values forward.
CREATE OR REPLACE VIEW volta_telemetry.session_samples AS
WITH resolved AS (
  SELECT vehicle_id, source_ts, field,
    CASE WHEN bool_and(NOT invalid) AND count(DISTINCT value_num) = 1
         THEN max(value_num) END AS n,
    CASE WHEN bool_and(NOT invalid) AND count(DISTINCT (latitude, longitude)) = 1
         THEN max(latitude) END AS lat,
    CASE WHEN bool_and(NOT invalid) AND count(DISTINCT (latitude, longitude)) = 1
         THEN max(longitude) END AS lon
  FROM volta_telemetry.samples GROUP BY vehicle_id, source_ts, field
), packs AS (
  -- Electrical power requires voltage and current from the SAME payload.
  SELECT vehicle_id, source_ts, payload_id,
    max(value_num) FILTER (WHERE field='PackVoltage' AND NOT invalid) AS v,
    max(value_num) FILTER (WHERE field='PackCurrent' AND NOT invalid) AS a
  FROM volta_telemetry.samples WHERE field IN ('PackVoltage','PackCurrent')
  GROUP BY vehicle_id, source_ts, payload_id
), powers AS (
  SELECT p.vehicle_id, p.source_ts,
    CASE WHEN count(DISTINCT p.v*p.a) FILTER (WHERE p.v>0) = 1
         THEN max(p.v*p.a) FILTER (WHERE p.v>0)/1000 *
           CASE c.sign WHEN 'discharge_positive' THEN 1 WHEN 'discharge_negative' THEN -1 END
    END AS power_kw
  FROM packs p LEFT JOIN volta_telemetry.power_calibration c USING (vehicle_id)
  GROUP BY p.vehicle_id,p.source_ts,c.sign
), merged AS (
  -- powers has one row per (vehicle_id, source_ts), so appending it to the
  -- per-field rows and grouping once equals a join without depending on
  -- planner estimates: before ANALYZE a join here was planned as a quadratic
  -- nested loop.
  SELECT vehicle_id,source_ts,field,n,lat,lon,NULL::double precision AS power_kw FROM resolved
  UNION ALL
  SELECT vehicle_id,source_ts,NULL,NULL,NULL,NULL,power_kw FROM powers
)
SELECT r.vehicle_id,r.source_ts,
  max(r.lat) FILTER (WHERE field='Location') AS latitude,
  max(r.lon) FILTER (WHERE field='Location') AS longitude,
  max(n) FILTER (WHERE field='VehicleSpeed')*1.609344 AS speed_kph,
  max(n) FILTER (WHERE field='BatteryLevel') AS battery_level,
  max(n) FILTER (WHERE field='EnergyRemaining') AS energy_remaining_kwh,
  max(n) FILTER (WHERE field='ModuleTempMin') AS battery_temp_min_c,
  max(n) FILTER (WHERE field='ModuleTempMax') AS battery_temp_max_c,
  max(n) FILTER (WHERE field='InsideTemp') AS inside_temp_c,
  max(n) FILTER (WHERE field='OutsideTemp') AS outside_temp_c,
  max(n) FILTER (WHERE field='ChargerVoltage') AS voltage,
  max(n) FILTER (WHERE field='ChargeAmps') AS current_a,
  max(n) FILTER (WHERE field='RatedRange')*1.609344 AS rated_range_km,
  -- AC/DC charging input power and calibrated pack power have different
  -- meanings. Expose both internally; API selects according to session kind.
  max(n) FILTER (WHERE field='ACChargingPower') AS ac_power_kw,
  max(n) FILTER (WHERE field='DCChargingPower') AS dc_power_kw,
  max(r.power_kw) AS power_kw,
  -- Absence and an explicit invalid/conflicting observation are distinct.
  -- Clients can keep a slow signal's cadence without bridging invalid data.
  array_agg(r.field) FILTER (WHERE r.n IS NULL AND r.field IN
    ('VehicleSpeed','BatteryLevel','EnergyRemaining','ModuleTempMin','ModuleTempMax',
     'InsideTemp','OutsideTemp','ChargerVoltage','ChargeAmps','RatedRange',
     'ACChargingPower','DCChargingPower','PackCurrent','PackVoltage',
     'LongitudinalAcceleration','LateralAcceleration')) AS invalid_fields,
  max(n) FILTER (WHERE field='LongitudinalAcceleration') AS longitudinal_acceleration_mps2,
  max(n) FILTER (WHERE field='LateralAcceleration') AS lateral_acceleration_mps2
FROM merged r
GROUP BY r.vehicle_id,r.source_ts;

REVOKE ALL ON volta_telemetry.api_vehicle_bindings,volta_telemetry.session_samples FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname='volta_readonly') THEN
    GRANT SELECT ON volta_telemetry.api_vehicle_bindings,volta_telemetry.session_samples TO volta_readonly;
  END IF;
END $$;
COMMIT;
