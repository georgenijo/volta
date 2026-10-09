-- Operator-applied on the TeslaMate database after telemetry migrations 001/002.
-- No password in source. Set it out of band with \password volta_commander_reader.
BEGIN;
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='volta_commander_reader') THEN
    CREATE ROLE volta_commander_reader LOGIN CONNECTION LIMIT 2;
  END IF;
END $$;
ALTER ROLE volta_commander_reader SET default_transaction_read_only = on;
ALTER ROLE volta_commander_reader SET statement_timeout = '1s';
ALTER ROLE volta_commander_reader SET log_error_verbosity = 'terse';
ALTER ROLE volta_commander_reader SET log_min_error_statement = 'panic';
ALTER ROLE volta_commander_reader SET log_parameter_max_length_on_error = 0;
GRANT USAGE ON SCHEMA public,volta_telemetry TO volta_commander_reader;
GRANT SELECT (id,vin) ON public.cars TO volta_commander_reader;
GRANT SELECT ON volta_telemetry.vehicle_bindings,volta_telemetry.api_vehicle_bindings,
 volta_telemetry.latest_samples,volta_telemetry.connectivity,volta_telemetry.stream_health,
 volta_telemetry.gaps,volta_telemetry.sessions,volta_telemetry.power_calibration TO volta_commander_reader;
COMMIT;
