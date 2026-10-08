-- Volta Fleet Telemetry capture schema.
--
-- Owns schema volta_telemetry only. Never writes TeslaMate's public tables
-- and never changes existing roles beyond granting read access to the new
-- views. Idempotent: safe to re-run. Plain SQL (DO blocks, no psql
-- meta-commands) so the acceptance harness applies the exact same file.
--
-- Apply (operator, on the TeslaMate database, as its owner):
--   docker exec -i teslamate-database-1 psql -v ON_ERROR_STOP=1 -U teslamate teslamate \
--     < deploy/telemetry/sql/001_volta_telemetry.sql
-- then set the ingest password out of band:
--   \password volta_telemetry_ingest

BEGIN;

CREATE SCHEMA IF NOT EXISTS volta_telemetry;

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'volta_telemetry_ingest') THEN
    -- No password here: the role cannot authenticate until the operator
    -- sets one.
    CREATE ROLE volta_telemetry_ingest LOGIN CONNECTION LIMIT 4;
  END IF;
END
$$;

ALTER ROLE volta_telemetry_ingest SET search_path = volta_telemetry;
ALTER ROLE volta_telemetry_ingest SET statement_timeout = '30s';
ALTER ROLE volta_telemetry_ingest SET idle_in_transaction_session_timeout = '60s';
-- Keep values out of the database server log: an error on the ingest
-- role's statements logs only the primary message (no DETAIL "Failing row
-- contains (...)" / "Key (...)=(...)"), no statement text and no bind
-- parameters. These are superuser settings; the schema is applied as the
-- database owner (superuser in TeslaMate's stock Postgres).
ALTER ROLE volta_telemetry_ingest SET log_error_verbosity = 'terse';
ALTER ROLE volta_telemetry_ingest SET log_min_error_statement = 'panic';
ALTER ROLE volta_telemetry_ingest SET log_parameter_max_length_on_error = 0;

-- Billing ledger: one row per Kafka record on a vehicle-data topic, written
-- before validation, so accepted and rejected records (unregistered or
-- foreign VINs, malformed payloads) all burn the budget. Keyed by Kafka
-- position: a replay after a crash is a no-op, and every receipt (resends
-- included, as Tesla bills them) counts once. signal_count NULL means the
-- payload could not be decoded: the meter reports unknown for that month
-- instead of guessing. No VIN and no payload: vehicle_id is set only for
-- registered vehicles.
CREATE TABLE IF NOT EXISTS volta_telemetry.receipts (
  topic           text        NOT NULL,
  kafka_partition integer     NOT NULL,
  kafka_offset    bigint      NOT NULL,
  received_at     timestamptz NOT NULL,
  dated           boolean     NOT NULL, -- false: no receiver or broker time, dated at ingest
  billable        boolean     NOT NULL,
  signal_count    integer     CHECK (signal_count >= 0),
  accepted        boolean     NOT NULL,
  vehicle_id      integer     CHECK (vehicle_id > 0),
  ingested_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (topic, kafka_partition, kafka_offset)
);
CREATE INDEX IF NOT EXISTS receipts_received ON volta_telemetry.receipts (received_at);

-- Durable proof that the consumer has seen each exact queue incarnation
-- continuously from offset zero (or from an earlier stored checkpoint).
-- Topic ids fence deletion/recreation: matching offsets in a replacement
-- topic never count as continuation of the old billing history.
CREATE TABLE IF NOT EXISTS volta_telemetry.queue_checkpoints (
  topic           text        NOT NULL,
  kafka_partition integer     NOT NULL,
  topic_id        text        NOT NULL CHECK (length(topic_id) > 0),
  next_offset     bigint      NOT NULL CHECK (next_offset >= 0),
  updated_at      timestamptz NOT NULL,
  PRIMARY KEY (topic, kafka_partition)
);

-- Permanent privacy-preserving identity fence. Only a domain-separated
-- SHA-256 digest is stored; a vehicle id or digest can never be reassigned.
CREATE TABLE IF NOT EXISTS volta_telemetry.vehicle_bindings (
  vehicle_id integer     PRIMARY KEY CHECK (vehicle_id > 0),
  vin_digest text        NOT NULL UNIQUE CHECK (vin_digest ~ '^[0-9a-f]{64}$'),
  bound_at   timestamptz NOT NULL DEFAULT now()
);

-- One row per accepted Kafka record. The primary key is the Kafka position,
-- so replaying a record after a crash is a no-op. payload_id is a hash of the
-- payload content (is_resend cleared): an exact retransmit has the same id,
-- two different payloads with the same created_at never do.
CREATE TABLE IF NOT EXISTS volta_telemetry.records (
  topic           text        NOT NULL,
  kafka_partition integer     NOT NULL,
  kafka_offset    bigint      NOT NULL,
  vehicle_id      integer     NOT NULL CHECK (vehicle_id > 0),
  tx_type         text        NOT NULL CHECK (tx_type IN ('V', 'connectivity')),
  txid            text        NOT NULL DEFAULT '',
  source_ts       timestamptz NOT NULL,
  received_at     timestamptz NOT NULL,
  is_resend       boolean     NOT NULL DEFAULT false,
  client_version  text        NOT NULL DEFAULT '',
  signal_count    integer     NOT NULL CHECK (signal_count >= 0),
  payload_id      text        NOT NULL,
  raw             bytea,      -- original protobuf; nulled after raw retention
  ingested_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (topic, kafka_partition, kafka_offset)
);
CREATE INDEX IF NOT EXISTS records_vehicle_source ON volta_telemetry.records (vehicle_id, source_ts);
CREATE INDEX IF NOT EXISTS records_raw_retention ON volta_telemetry.records (ingested_at) WHERE raw IS NOT NULL;

-- One row per field per payload. source_ts is the payload's created_at:
-- Fleet Telemetry has no per-datum timestamp. Absence of a row means the
-- field was not sent at that instant (unknown), never "same as before".
-- invalid = no usable value; quality says why: 'invalid' (the car reported
-- it unavailable) or 'malformed' (the datum did not have the field's
-- registered type). Keyed by payload_id so two payloads with the same
-- created_at stay separate and are never combined.
CREATE TABLE IF NOT EXISTS volta_telemetry.samples (
  vehicle_id  integer          NOT NULL CHECK (vehicle_id > 0),
  field       text             NOT NULL,
  source_ts   timestamptz      NOT NULL,
  received_at timestamptz      NOT NULL,
  value_num   double precision,
  value_text  text,
  value_bool  boolean,
  latitude    double precision,
  longitude   double precision,
  invalid     boolean          NOT NULL,
  quality     text             NOT NULL CHECK (quality IN ('ok', 'invalid', 'malformed')),
  source_unit text             NOT NULL DEFAULT '',
  is_resend   boolean          NOT NULL DEFAULT false,
  payload_id  text             NOT NULL,
  PRIMARY KEY (vehicle_id, field, source_ts, payload_id),
  CHECK (invalid = (num_nonnulls(value_num, value_text, value_bool, latitude) = 0)),
  CHECK (invalid = (quality <> 'ok')),
  CHECK ((latitude IS NULL) = (longitude IS NULL))
);
CREATE INDEX IF NOT EXISTS samples_vehicle_source ON volta_telemetry.samples (vehicle_id, source_ts);

-- Newest sample per field, maintained out-of-order safely (a late, older
-- sample never replaces a newer one). Each value keeps its own source_ts so
-- the app shows how old it is instead of presenting it as fresh. When two
-- different payloads report different values at the same created_at, the
-- value becomes invalid with quality 'conflict' instead of either one.
CREATE TABLE IF NOT EXISTS volta_telemetry.latest_samples (
  vehicle_id  integer          NOT NULL,
  field       text             NOT NULL,
  source_ts   timestamptz      NOT NULL,
  received_at timestamptz      NOT NULL,
  value_num   double precision,
  value_text  text,
  value_bool  boolean,
  latitude    double precision,
  longitude   double precision,
  invalid     boolean          NOT NULL,
  quality     text             NOT NULL CHECK (quality IN ('ok', 'invalid', 'malformed', 'conflict')),
  source_unit text             NOT NULL DEFAULT '',
  payload_id  text             NOT NULL,
  PRIMARY KEY (vehicle_id, field),
  CHECK (invalid = (num_nonnulls(value_num, value_text, value_bool, latitude) = 0)),
  CHECK (invalid = (quality <> 'ok'))
);

-- Receiver connect/disconnect events (receiver clock).
CREATE TABLE IF NOT EXISTS volta_telemetry.connectivity (
  vehicle_id        integer     NOT NULL,
  connection_id     text        NOT NULL,
  status            text        NOT NULL CHECK (status IN ('CONNECTED', 'DISCONNECTED', 'UNKNOWN')),
  source_ts         timestamptz NOT NULL,
  network_interface text        NOT NULL DEFAULT '',
  received_at       timestamptz NOT NULL,
  PRIMARY KEY (vehicle_id, connection_id, status, source_ts)
);
CREATE INDEX IF NOT EXISTS connectivity_vehicle_source ON volta_telemetry.connectivity (vehicle_id, source_ts);

-- Records refused by the consumer (unregistered VIN, VIN mismatch, bad
-- timestamp, a record the database refused, ...). Reason only: no VIN, no
-- payload, no values. Billing does not depend on this table (see receipts);
-- it is pruned after the rejection retention.
CREATE TABLE IF NOT EXISTS volta_telemetry.rejected_records (
  topic           text        NOT NULL,
  kafka_partition integer     NOT NULL,
  kafka_offset    bigint      NOT NULL,
  reason          text        NOT NULL,
  rejected_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (topic, kafka_partition, kafka_offset)
);

-- Derived sessions. Recomputed deterministically from samples; membership
-- is 'partial' whenever the start was not observed or an unknown span lies
-- inside (listed in gaps).
CREATE TABLE IF NOT EXISTS volta_telemetry.sessions (
  vehicle_id   integer     NOT NULL,
  kind         text        NOT NULL CHECK (kind IN ('drive', 'charge')),
  start_ts     timestamptz NOT NULL,
  end_ts       timestamptz NOT NULL,
  start_reason text        NOT NULL,
  end_reason   text        NOT NULL,
  membership   text        NOT NULL CHECK (membership IN ('complete', 'partial')),
  gaps         jsonb       NOT NULL DEFAULT '[]',
  payloads     integer     NOT NULL,
  derived_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (vehicle_id, kind, start_ts),
  CHECK (end_ts >= start_ts)
);

-- Unknown spans: a known disconnect (any length), silence without
-- connectivity evidence, or a vehicle-reported invalid Gear /
-- DetailedChargeState until the next valid value.
CREATE TABLE IF NOT EXISTS volta_telemetry.gaps (
  vehicle_id integer     NOT NULL,
  start_ts   timestamptz NOT NULL,
  end_ts     timestamptz NOT NULL,
  reason     text        NOT NULL CHECK (reason IN ('disconnected', 'silence', 'gear_invalid', 'charge_invalid')),
  PRIMARY KEY (vehicle_id, start_ts, reason)
);
CREATE INDEX IF NOT EXISTS gaps_vehicle_end ON volta_telemetry.gaps (vehicle_id, end_ts);

-- PackCurrent sign. Written only by the operator after the live sign gate
-- (a verified physical net-charging observation); never inferred from
-- charger power, and the ingest role cannot write it. No row = unverified,
-- so power stays NULL.
CREATE TABLE IF NOT EXISTS volta_telemetry.power_calibration (
  vehicle_id    integer     PRIMARY KEY CHECK (vehicle_id > 0),
  sign          text        NOT NULL CHECK (sign IN ('discharge_positive', 'discharge_negative')),
  source        text        NOT NULL CHECK (source = 'operator_live_gate'),
  evidence_note text        NOT NULL CHECK (length(evidence_note) > 0),
  recorded_at   timestamptz NOT NULL DEFAULT now()
);

-- Receiver and consumer liveness, written by the consumer from the receiver
-- guard's liveness endpoint and its own queue progress. A stream is current
-- only while this is fresh (see store.Link).
CREATE TABLE IF NOT EXISTS volta_telemetry.stream_health (
  id                  smallint    PRIMARY KEY CHECK (id = 1),
  receiver_generation text,
  receiver_started_at timestamptz,
  receiver_seen_at    timestamptz,
  consumer_started_at timestamptz NOT NULL,
  caught_up_at        timestamptz,
  lag_records         bigint,
  updated_at          timestamptz NOT NULL
);

-- Same-payload values only: every column comes from one payload (grouped
-- by payload identity, not by timestamp). No forward fill.
CREATE OR REPLACE VIEW volta_telemetry.payload_points AS
SELECT s.vehicle_id,
       s.source_ts,
       max(s.latitude)  FILTER (WHERE s.field = 'Location' AND NOT s.invalid)          AS latitude,
       max(s.longitude) FILTER (WHERE s.field = 'Location' AND NOT s.invalid)          AS longitude,
       max(s.value_num) FILTER (WHERE s.field = 'VehicleSpeed' AND NOT s.invalid) * 1.609344 AS speed_kph,
       max(s.value_num) FILTER (WHERE s.field = 'GpsHeading' AND NOT s.invalid)        AS heading_deg,
       max(s.value_num) FILTER (WHERE s.field = 'PackVoltage' AND NOT s.invalid)       AS pack_voltage_v,
       max(s.value_num) FILTER (WHERE s.field = 'PackCurrent' AND NOT s.invalid)       AS pack_current_a,
       max(s.value_num) FILTER (WHERE s.field = 'BatteryLevel' AND NOT s.invalid)      AS battery_level_pct,
       max(s.value_num) FILTER (WHERE s.field = 'Soc' AND NOT s.invalid)               AS soc_pct,
       max(s.value_num) FILTER (WHERE s.field = 'Odometer' AND NOT s.invalid) * 1.609344 AS odometer_km,
       max(s.value_text) FILTER (WHERE s.field = 'Gear' AND NOT s.invalid)             AS gear,
       bool_or(s.is_resend)                                                            AS is_resend
FROM volta_telemetry.samples s
GROUP BY s.vehicle_id, s.source_ts, s.payload_id;

-- Route/chart points. power_kw is NULL until the operator records the
-- PackCurrent sign, and when voltage/current were not in the same payload.
-- route_break_before is true when an unknown span lies between this point
-- and the previous route point: clients must not draw a line across it.
CREATE OR REPLACE VIEW volta_telemetry.drive_points AS
SELECT p.vehicle_id,
       p.source_ts,
       p.latitude,
       p.longitude,
       p.speed_kph,
       p.heading_deg,
       CASE
         WHEN p.pack_voltage_v IS NULL OR p.pack_voltage_v <= 0 THEN NULL
         WHEN c.sign = 'discharge_positive' THEN p.pack_voltage_v * p.pack_current_a / 1000
         WHEN c.sign = 'discharge_negative' THEN -p.pack_voltage_v * p.pack_current_a / 1000
       END                                    AS power_kw,
       COALESCE(c.sign, 'unverified')         AS power_sign,
       p.pack_voltage_v,
       p.pack_current_a,
       p.battery_level_pct,
       p.soc_pct,
       p.odometer_km,
       p.gear,
       d.start_ts                             AS drive_start_ts,
       CASE
         WHEN d.start_ts IS NULL THEN 'unknown'
         WHEN d.membership = 'complete' THEN 'member'
         ELSE 'partial'
       END                                    AS trip_membership,
       -- A stream gap (any known disconnect or unexplained silence) lies
       -- between the previous valid position and this one: do not draw a
       -- line across it.
       EXISTS (
         SELECT 1 FROM volta_telemetry.gaps g
         WHERE g.vehicle_id = p.vehicle_id AND g.reason IN ('disconnected', 'silence')
           AND g.start_ts < p.source_ts
           AND g.end_ts > COALESCE((
             SELECT max(l.source_ts) FROM volta_telemetry.samples l
             WHERE l.vehicle_id = p.vehicle_id AND l.field = 'Location' AND NOT l.invalid
               AND l.source_ts < p.source_ts), '-infinity'::timestamptz)
       )                                      AS route_break_before
FROM volta_telemetry.payload_points p
LEFT JOIN volta_telemetry.power_calibration c ON c.vehicle_id = p.vehicle_id
LEFT JOIN volta_telemetry.sessions d
  ON d.vehicle_id = p.vehicle_id AND d.kind = 'drive'
 AND p.source_ts BETWEEN d.start_ts AND d.end_ts
WHERE p.latitude IS NOT NULL;

-- Metered streaming signals per UTC month from the billing ledger: every
-- received vehicle-data record, accepted or rejected, resends included.
-- vehicle_id is NULL for records that do not belong to a registered
-- vehicle. uncountable_records > 0 means the month's total is a lower
-- bound. Tesla's billing month boundary may differ; see the docs.
CREATE OR REPLACE VIEW volta_telemetry.signal_usage_monthly AS
SELECT to_char(date_trunc('month', r.received_at AT TIME ZONE 'UTC'), 'YYYY-MM') AS month,
       r.vehicle_id,
       COALESCE(sum(r.signal_count), 0)::bigint                     AS signals,
       (COALESCE(sum(r.signal_count) FILTER (WHERE NOT r.accepted), 0))::bigint AS rejected_signals,
       count(*) FILTER (WHERE r.signal_count IS NULL)::bigint         AS uncountable_records,
       round(COALESCE(sum(r.signal_count), 0) / 150000.0, 4)          AS usd
FROM volta_telemetry.receipts r
WHERE r.billable
GROUP BY 1, 2;

CREATE OR REPLACE VIEW volta_telemetry.rejection_counts AS
SELECT (rejected_at AT TIME ZONE 'UTC')::date AS day, reason, count(*)::bigint AS records
FROM volta_telemetry.rejected_records
GROUP BY 1, 2;

-- Privileges. The ingest role owns nothing and can only touch this schema.
REVOKE ALL ON SCHEMA volta_telemetry FROM PUBLIC;
GRANT USAGE ON SCHEMA volta_telemetry TO volta_telemetry_ingest;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA volta_telemetry TO volta_telemetry_ingest;
-- The sign calibration is operator-only.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON volta_telemetry.power_calibration FROM volta_telemetry_ingest;

-- The API's read-only group sees derived views and sessions, not raw
-- payloads (records.raw) or rejection details.
DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'volta_readonly') THEN
    GRANT USAGE ON SCHEMA volta_telemetry TO volta_readonly;
    GRANT SELECT ON volta_telemetry.drive_points, volta_telemetry.payload_points,
                    volta_telemetry.latest_samples, volta_telemetry.sessions,
                    volta_telemetry.gaps, volta_telemetry.connectivity,
                    volta_telemetry.power_calibration, volta_telemetry.stream_health,
                    volta_telemetry.signal_usage_monthly, volta_telemetry.rejection_counts
      TO volta_readonly;
  END IF;
END
$$;

COMMIT;
