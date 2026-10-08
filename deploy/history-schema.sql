-- Tesla-billed charging sessions (GET /api/1/dx/charging/history), written only
-- by the operator CLI through commander. Applied by an administrator, never by
-- the API runtime; volta_auth gets DML through auth-grants.sql. The full VIN,
-- invoice identifiers and raw fee lines stay in this private schema: paired
-- devices receive only derived, VIN-free summaries.
CREATE TABLE IF NOT EXISTS volta.tesla_charging_sessions (
  -- Opaque per-sign-in namespace from commander; a relinked or replaced
  -- account gets a new key, so its reads never see an earlier link's rows.
  account_key text NOT NULL CHECK (account_key ~ '^[a-f0-9]{64}$'),
  session_id bigint NOT NULL CHECK (session_id > 0),
  -- Exact full VIN as Tesla billed it; NULL when absent or malformed. Matched
  -- to TeslaMate cars only by exact equality, never by a suffix.
  vin text CHECK (vin ~ '^[A-HJ-NPR-Z0-9]{17}$'),
  site_location_name text CHECK (length(site_location_name) BETWEEN 1 AND 200),
  country_code text CHECK (country_code ~ '^[A-Z]{2}$'),
  charge_start timestamptz,
  charge_stop timestamptz,
  unlatch_at timestamptz,
  billing_type text CHECK (length(billing_type) BETWEEN 1 AND 32),
  vehicle_make_type text CHECK (length(vehicle_make_type) BETWEEN 1 AND 32),
  -- Re-validated fee lines and invoice references (never fetched).
  fees jsonb NOT NULL CHECK (jsonb_typeof(fees) = 'array'),
  invoices jsonb NOT NULL CHECK (jsonb_typeof(invoices) = 'array'),
  -- Derived conservatively; NULL whenever Tesla's data is ambiguous.
  currency text CHECK (currency ~ '^[A-Z]{3}$'),
  total_due numeric,
  net_due numeric,
  billed_energy_kwh numeric CHECK (billed_energy_kwh >= 0),
  sort_at timestamptz NOT NULL,
  content_hash bytea NOT NULL CHECK (octet_length(content_hash) = 32),
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_key, session_id)
);
CREATE INDEX IF NOT EXISTS tesla_charging_sessions_vehicle
  ON volta.tesla_charging_sessions (account_key, vin, sort_at DESC, session_id DESC);
-- One row per applied operator run, for status, audit and resuming (counts and
-- session IDs only; no VINs, invoices or fees).
CREATE TABLE IF NOT EXISTS volta.tesla_history_syncs (
  id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_key text NOT NULL CHECK (account_key ~ '^[a-f0-9]{64}$'),
  window_start timestamptz NOT NULL,
  window_end timestamptz NOT NULL CHECK (window_end > window_start),
  first_page integer NOT NULL CHECK (first_page IN (0, 1)),
  page_size integer NOT NULL CHECK (page_size BETWEEN 1 AND 50),
  -- One row per run, stored before its first Tesla call and checkpointed with
  -- each kept page; outcome is 'in_progress' until the run records why it
  -- stopped, and finished_at is its latest checkpoint. Counts: this run only.
  pages integer NOT NULL CHECK (pages >= 0),
  received integer NOT NULL CHECK (received >= 0),
  rejected integer NOT NULL CHECK (rejected >= 0),
  inserted integer NOT NULL CHECK (inserted >= 0),
  updated integer NOT NULL CHECK (updated >= 0),
  unchanged integer NOT NULL CHECK (unchanged >= 0),
  -- The whole chain of runs for this window, from its first page: the
  -- pagination evidence a resumed run continues from.
  chain_pages integer NOT NULL CHECK (chain_pages BETWEEN 0 AND 201),
  chain_received integer NOT NULL CHECK (chain_received >= 0),
  chain_rejected integer NOT NULL CHECK (chain_rejected >= 0),
  total_results integer CHECK (total_results >= 0),
  seen_ids bigint[] NOT NULL CHECK (cardinality(seen_ids) = chain_received),
  -- True only when Tesla's total for this window was matched exactly with no
  -- rejected rows; it never asserts the account's whole history.
  window_complete boolean NOT NULL CHECK (NOT window_complete OR (chain_rejected = 0 AND total_results = chain_received)),
  outcome text NOT NULL CHECK (outcome ~ '^[a-z_]{1,40}$'),
  -- Where a resumed run continues; only the SHA-256 of its one-time token is kept.
  next_page integer CHECK (next_page BETWEEN 0 AND 200),
  resume_hash bytea UNIQUE CHECK (octet_length(resume_hash) = 32),
  resumed_from integer UNIQUE REFERENCES volta.tesla_history_syncs (id),
  -- The run holding the token: its lease time and a random owner generation,
  -- so a run whose lease lapsed cannot write over the run that took over.
  claimed_at timestamptz,
  claim_owner bytea CHECK (octet_length(claim_owner) = 32),
  resumed_at timestamptz,
  started_at timestamptz NOT NULL,
  finished_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((next_page IS NULL) = (resume_hash IS NULL)),
  CHECK (NOT window_complete OR next_page IS NULL),
  CHECK (NOT window_complete OR outcome = 'total_reached'),
  CHECK (claim_owner IS NULL OR claimed_at IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS tesla_history_syncs_account ON volta.tesla_history_syncs (account_key, finished_at DESC);
