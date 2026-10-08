\set ON_ERROR_STOP on
-- Same-cluster recovery: existing roles/passwords/settings are retained.
-- Restore the TeslaMate database first; run as its administrator.
BEGIN;
\ir auth-schema.sql
\ir history-schema.sql
\ir auth-grants.sql
\ir privilege-checks.sql
COMMIT;
