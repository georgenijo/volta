-- Applied by an administrator, never by the API runtime. No TeslaMate DDL.
CREATE SCHEMA IF NOT EXISTS volta;
CREATE TABLE IF NOT EXISTS volta.devices (
  id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  token_hash bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz,
  revoked_at timestamptz
);
CREATE TABLE IF NOT EXISTS volta.pairing_codes (
  code_hash bytea PRIMARY KEY CHECK (octet_length(code_hash) = 32),
  expires_at timestamptz NOT NULL
);
CREATE TABLE IF NOT EXISTS volta.rate_limits (
  key text PRIMARY KEY,
  window_start timestamptz NOT NULL,
  attempts integer NOT NULL
);
-- Sign in with Apple. Apple's identifier for a person is stored only as a hash.
CREATE TABLE IF NOT EXISTS volta.apple_owners (
  subject_hash bytea PRIMARY KEY CHECK (octet_length(subject_hash) = 32),
  created_at timestamptz NOT NULL DEFAULT now()
);
-- At most one open window in which the next Apple ID to sign in enrolls itself.
CREATE TABLE IF NOT EXISTS volta.apple_enrollment (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  expires_at timestamptz NOT NULL
);
-- Identity tokens already accepted, kept until they could no longer verify.
CREATE TABLE IF NOT EXISTS volta.apple_tokens (
  token_hash bytea PRIMARY KEY CHECK (octet_length(token_hash) = 32),
  expires_at timestamptz NOT NULL
);
