-- Optional recorded odometer surface. Resolve invalid/conflicting observations
-- at each timestamp before converting Tesla's documented miles to metric.
BEGIN;
CREATE OR REPLACE VIEW volta_telemetry.service_odometer AS
SELECT vehicle_id, source_ts,
  CASE WHEN bool_and(NOT invalid) AND count(DISTINCT value_num)=1
    THEN max(value_num)*1.609344 END AS odometer_km
FROM volta_telemetry.samples WHERE field='Odometer'
GROUP BY vehicle_id, source_ts;
REVOKE ALL ON volta_telemetry.service_odometer FROM PUBLIC;
GRANT SELECT ON volta_telemetry.service_odometer TO volta_readonly;
COMMIT;
