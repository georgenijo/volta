-- Removes everything 001_volta_telemetry.sql created and nothing else:
-- the volta_telemetry schema (tables, views, data) and the ingest role.
-- TeslaMate's tables and the volta_readonly role are untouched.
--
--   docker exec -i teslamate-database-1 psql -v ON_ERROR_STOP=1 -U teslamate teslamate \
--     < deploy/telemetry/sql/rollback.sql
BEGIN;
DROP SCHEMA IF EXISTS volta_telemetry CASCADE;
DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'volta_telemetry_ingest') THEN
    -- Privileges on objects outside the dropped schema (database CONNECT).
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM volta_telemetry_ingest', current_database());
    DROP ROLE volta_telemetry_ingest;
  END IF;
END
$$;
COMMIT;
