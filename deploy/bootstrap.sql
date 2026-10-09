\set ON_ERROR_STOP on
-- Run as TeslaMate's database administrator with psql. Passwords are prompted
-- locally with hidden input, never embedded here or in argv.
BEGIN;
-- Dedicated group has only SELECT on explicit public telemetry tables.
SELECT 'CREATE ROLE volta_readonly NOLOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'volta_readonly') \gexec
SELECT 'CREATE ROLE volta_reader LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'volta_reader') \gexec
SELECT 'CREATE ROLE volta_auth LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'volta_auth') \gexec
\password volta_reader
\password volta_auth
ALTER ROLE volta_reader SET default_transaction_read_only = on;
ALTER ROLE volta_reader SET search_path = public;
-- Match teslamate-host's telemetry hardening when bootstrap is re-applied.
ALTER ROLE volta_reader CONNECTION LIMIT 10;
ALTER ROLE volta_reader SET statement_timeout = '30s';
ALTER ROLE volta_reader SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE volta_reader SET lock_timeout = '5s';
ALTER ROLE volta_auth SET search_path = volta;
GRANT volta_readonly TO volta_reader;
SELECT format('GRANT CONNECT ON DATABASE %I TO volta_reader, volta_auth', current_database()) \gexec
GRANT USAGE ON SCHEMA public TO volta_readonly;
GRANT SELECT ON public.cars, public.positions, public.drives, public.charging_processes,
  public.charges, public.states, public.updates, public.geofences, public.addresses, public.car_settings TO volta_readonly;
-- No grants on private.tokens, unrelated tables, or future tables.
\ir auth-schema.sql
\ir history-schema.sql
\ir service-schema.sql
\ir auth-grants.sql
\ir privilege-checks.sql
COMMIT;
