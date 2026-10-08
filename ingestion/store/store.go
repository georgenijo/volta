// Package store writes normalized telemetry into the volta_telemetry schema.
//
// Apply runs one transaction per Kafka batch. Every insert is idempotent
// (keyed by Kafka position or by vehicle/field/source time), so the consumer
// can commit Kafka offsets only after this transaction commits and simply
// replay on any crash in between.
package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/georgenijo/volta/ingestion/normalize"
	"github.com/georgenijo/volta/ingestion/session"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Item is one Kafka record outcome: an accepted message or a rejection.
// Every item carries its billing receipt, written whether or not the record
// is accepted.
type Item struct {
	Message *normalize.Message
	// For rejections:
	Topic     string
	Partition int32
	Offset    int64
	Reason    string
	// Receipt is the record's billing view (see normalize.Receipt).
	Receipt normalize.Receipt
}

// ReasonStoreRejected marks a record the database refused permanently (a
// data or constraint error). It is quarantined so it cannot block the
// records behind it; its receipt is still billed.
const ReasonStoreRejected = "store_rejected"

// Store is the Postgres sink.
type Store struct {
	Pool *pgxpool.Pool
	// Lookback is how far before the earliest new sample sessions are
	// recomputed.
	Lookback time.Duration
	Options  session.Options
}

// New returns a store with production defaults.
func New(pool *pgxpool.Pool) *Store {
	return &Store{Pool: pool, Lookback: 24 * time.Hour, Options: session.DefaultOptions}
}

// Permanent reports whether a database error will recur for the same input
// (SQLSTATE class 22 data exception or 23 integrity violation). Anything
// else (connection loss, timeouts, serialization failures, a missing
// schema) is transient and retried without dropping data.
func Permanent(err error) bool {
	var pg *pgconn.PgError
	if !errors.As(err, &pg) || len(pg.Code) < 2 {
		return false
	}
	switch pg.Code[:2] {
	case "22", "23":
		return true
	}
	return false
}

// Apply persists a batch atomically. If the database refuses the batch with
// a permanent error, Apply isolates the offending records: each item is
// applied in its own transaction and any item that still fails permanently
// is stored as a rejection with ReasonStoreRejected (Apply rewrites that
// item in place). Transient errors are returned for the caller to retry.
func (s *Store) Apply(ctx context.Context, items []Item) error {
	if len(items) == 0 {
		return nil
	}
	err := s.applyTx(ctx, items)
	if err == nil || !Permanent(err) {
		return err
	}
	for i := range items {
		err := s.applyTx(ctx, items[i:i+1])
		if err == nil {
			continue
		}
		if !Permanent(err) {
			return err
		}
		it := &items[i]
		if it.Message != nil {
			it.Topic, it.Partition, it.Offset = it.Message.Topic, it.Message.Partition, it.Message.Offset
			it.Message = nil
		}
		it.Reason = ReasonStoreRejected
		if err := s.applyTx(ctx, items[i:i+1]); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) applyTx(ctx context.Context, items []Item) error {
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		affected := map[int]time.Time{}
		for _, it := range items {
			topic, part, off := it.Topic, it.Partition, it.Offset
			var vid *int
			if it.Message != nil {
				topic, part, off = it.Message.Topic, it.Message.Partition, it.Message.Offset
				vid = &it.Message.VehicleID
			}
			rc := it.Receipt
			if _, err := tx.Exec(ctx, `INSERT INTO volta_telemetry.receipts
				(topic, kafka_partition, kafka_offset, received_at, dated, billable, signal_count, accepted, vehicle_id)
				VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
				ON CONFLICT (topic, kafka_partition, kafka_offset) DO UPDATE SET accepted = EXCLUDED.accepted, vehicle_id = EXCLUDED.vehicle_id`,
				topic, part, off, rc.ReceivedAt, rc.Dated, rc.Billable, rc.Signals, it.Message != nil, vid); err != nil {
				return err
			}
			if it.Message == nil {
				if _, err := tx.Exec(ctx, `INSERT INTO volta_telemetry.rejected_records (topic, kafka_partition, kafka_offset, reason)
					VALUES ($1, $2, $3, $4) ON CONFLICT (topic, kafka_partition, kafka_offset) DO UPDATE SET reason = EXCLUDED.reason`,
					topic, part, off, it.Reason); err != nil {
					return err
				}
				continue
			}
			m := it.Message
			tag, err := tx.Exec(ctx, `INSERT INTO volta_telemetry.records
				(topic, kafka_partition, kafka_offset, vehicle_id, tx_type, txid, source_ts, received_at, is_resend, client_version, signal_count, payload_id, raw)
				VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) ON CONFLICT DO NOTHING`,
				m.Topic, m.Partition, m.Offset, m.VehicleID, m.TxType, m.TxID, m.SourceTS, m.ReceivedAt, m.IsResend, m.ClientVersion, m.SignalCount(), m.PayloadID, m.Raw)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				continue // replay of a record already stored
			}
			if m.Connectivity != nil {
				if _, err := tx.Exec(ctx, `INSERT INTO volta_telemetry.connectivity
					(vehicle_id, connection_id, status, source_ts, network_interface, received_at)
					VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT DO NOTHING`,
					m.VehicleID, m.Connectivity.ConnectionID, m.Connectivity.Status, m.SourceTS, m.Connectivity.NetworkInterface, m.ReceivedAt); err != nil {
					return err
				}
			}
			batch := &pgx.Batch{}
			for _, smp := range m.Samples {
				batch.Queue(`INSERT INTO volta_telemetry.samples
					(vehicle_id, field, source_ts, received_at, value_num, value_text, value_bool, latitude, longitude, invalid, quality, source_unit, is_resend, payload_id)
					VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14) ON CONFLICT DO NOTHING`,
					m.VehicleID, smp.Field, m.SourceTS, m.ReceivedAt, smp.Num, smp.Text, smp.Bool, smp.Lat, smp.Lon, smp.Invalid, smp.Quality, smp.SourceUnit, m.IsResend, m.PayloadID)
				batch.Queue(`INSERT INTO volta_telemetry.latest_samples AS l
					(vehicle_id, field, source_ts, received_at, value_num, value_text, value_bool, latitude, longitude, invalid, quality, source_unit, payload_id)
					VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
					ON CONFLICT (vehicle_id, field) DO UPDATE SET
					  source_ts = EXCLUDED.source_ts, received_at = EXCLUDED.received_at, value_num = EXCLUDED.value_num,
					  value_text = EXCLUDED.value_text, value_bool = EXCLUDED.value_bool, latitude = EXCLUDED.latitude,
					  longitude = EXCLUDED.longitude, invalid = EXCLUDED.invalid, quality = EXCLUDED.quality,
					  source_unit = EXCLUDED.source_unit, payload_id = EXCLUDED.payload_id
					WHERE EXCLUDED.source_ts > l.source_ts`,
					m.VehicleID, smp.Field, m.SourceTS, m.ReceivedAt, smp.Num, smp.Text, smp.Bool, smp.Lat, smp.Lon, smp.Invalid, smp.Quality, smp.SourceUnit, m.PayloadID)
				// A different payload with the same created_at and a different
				// value: neither is "the" value at that instant.
				batch.Queue(`UPDATE volta_telemetry.latest_samples SET
					  value_num = NULL, value_text = NULL, value_bool = NULL, latitude = NULL, longitude = NULL,
					  invalid = true, quality = 'conflict'
					WHERE vehicle_id = $1 AND field = $2 AND source_ts = $3 AND payload_id <> $4 AND quality <> 'conflict'
					  AND (value_num, value_text, value_bool, latitude, longitude, invalid)
					      IS DISTINCT FROM ($5::double precision, $6::text, $7::boolean, $8::double precision, $9::double precision, $10::boolean)`,
					m.VehicleID, smp.Field, m.SourceTS, m.PayloadID, smp.Num, smp.Text, smp.Bool, smp.Lat, smp.Lon, smp.Invalid)
			}
			if batch.Len() > 0 {
				if err := tx.SendBatch(ctx, batch).Close(); err != nil {
					return err
				}
			}
			if prev, ok := affected[m.VehicleID]; !ok || m.SourceTS.Before(prev) {
				affected[m.VehicleID] = m.SourceTS
			}
		}
		for vid, minTS := range affected {
			if err := s.recompute(ctx, tx, vid, minTS); err != nil {
				return err
			}
		}
		return nil
	})
}

func (s *Store) recompute(ctx context.Context, tx pgx.Tx, vehicleID int, minTS time.Time) error {
	windowStart := minTS.Add(-s.Lookback)
	// Never start inside a stored session: move back to its start.
	var overlap *time.Time
	if err := tx.QueryRow(ctx, `SELECT min(start_ts) FROM volta_telemetry.sessions
		WHERE vehicle_id = $1 AND start_ts < $2 AND end_ts >= $2`, vehicleID, windowStart).Scan(&overlap); err != nil {
		return err
	}
	if overlap != nil {
		windowStart = *overlap
	}

	// Seed: the latest Gear / DetailedChargeState before the window, invalid
	// samples included. An invalid latest value, or two payloads disagreeing
	// at that instant, seeds "unknown" (empty), never an older valid value.
	var seed session.Seed
	var lastGear, lastCharge *string
	var lastPayload *time.Time
	if err := tx.QueryRow(ctx, `SELECT
		(SELECT CASE WHEN bool_or(invalid) OR count(DISTINCT value_text) <> 1 THEN NULL ELSE min(value_text) END
		   FROM volta_telemetry.samples WHERE vehicle_id = $1 AND field = 'Gear' AND source_ts =
		   (SELECT max(source_ts) FROM volta_telemetry.samples WHERE vehicle_id = $1 AND field = 'Gear' AND source_ts < $2)),
		(SELECT CASE WHEN bool_or(invalid) OR count(DISTINCT value_text) <> 1 THEN NULL ELSE min(value_text) END
		   FROM volta_telemetry.samples WHERE vehicle_id = $1 AND field = 'DetailedChargeState' AND source_ts =
		   (SELECT max(source_ts) FROM volta_telemetry.samples WHERE vehicle_id = $1 AND field = 'DetailedChargeState' AND source_ts < $2)),
		(SELECT max(source_ts) FROM volta_telemetry.records WHERE vehicle_id = $1 AND tx_type = 'V' AND source_ts < $2)`,
		vehicleID, windowStart).Scan(&lastGear, &lastCharge, &lastPayload); err != nil {
		return err
	}
	if lastGear != nil {
		seed.LastGear = *lastGear
	}
	if lastCharge != nil {
		seed.LastChargeState = *lastCharge
	}
	if lastPayload != nil {
		seed.LastPayload = *lastPayload
	}

	// One point per payload instant, plus one per state sample. Invalid
	// samples are kept: they are uncertainty boundaries, not absent data.
	// session.Derive merges points at the same instant and treats
	// disagreement between payloads as invalid.
	var points []session.Point
	rows, err := tx.Query(ctx, `SELECT DISTINCT source_ts FROM volta_telemetry.records
		WHERE vehicle_id = $1 AND tx_type = 'V' AND source_ts >= $2`, vehicleID, windowStart)
	if err != nil {
		return err
	}
	for rows.Next() {
		var ts time.Time
		if err := rows.Scan(&ts); err != nil {
			rows.Close()
			return err
		}
		points = append(points, session.Point{TS: ts})
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	rows, err = tx.Query(ctx, `SELECT source_ts, field, value_text, value_num, invalid FROM volta_telemetry.samples
		WHERE vehicle_id = $1 AND source_ts >= $2
		  AND field IN ('Gear', 'VehicleSpeed', 'DetailedChargeState')`, vehicleID, windowStart)
	if err != nil {
		return err
	}
	for rows.Next() {
		var p session.Point
		var field string
		var text *string
		var num *float64
		var invalid bool
		if err := rows.Scan(&p.TS, &field, &text, &num, &invalid); err != nil {
			rows.Close()
			return err
		}
		switch field {
		case "Gear":
			if invalid || text == nil {
				p.GearInvalid = true
			} else {
				p.Gear = *text
			}
		case "DetailedChargeState":
			if invalid || text == nil {
				p.ChargeInvalid = true
			} else {
				p.ChargeState = *text
			}
		case "VehicleSpeed":
			if !invalid {
				p.SpeedMph = num
			}
		}
		points = append(points, p)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	var conns []session.ConnEvent
	rows, err = tx.Query(ctx, `(SELECT source_ts, connection_id, status FROM volta_telemetry.connectivity
		   WHERE vehicle_id = $1 AND source_ts < $2 ORDER BY source_ts DESC LIMIT 1)
		UNION ALL
		(SELECT source_ts, connection_id, status FROM volta_telemetry.connectivity
		   WHERE vehicle_id = $1 AND source_ts >= $2)`, vehicleID, windowStart)
	if err != nil {
		return err
	}
	for rows.Next() {
		var c session.ConnEvent
		if err := rows.Scan(&c.TS, &c.ConnectionID, &c.Status); err != nil {
			rows.Close()
			return err
		}
		conns = append(conns, c)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	res := session.Derive(points, conns, seed, s.Options)

	if _, err := tx.Exec(ctx, `DELETE FROM volta_telemetry.sessions WHERE vehicle_id = $1 AND start_ts >= $2`, vehicleID, windowStart); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM volta_telemetry.gaps WHERE vehicle_id = $1 AND end_ts >= $2`, vehicleID, windowStart); err != nil {
		return err
	}
	for _, se := range res.Sessions {
		gaps := se.Gaps
		if gaps == nil {
			gaps = []session.Gap{}
		}
		gj, err := json.Marshal(gaps)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO volta_telemetry.sessions
			(vehicle_id, kind, start_ts, end_ts, start_reason, end_reason, membership, gaps, payloads)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
			vehicleID, se.Kind, se.Start, se.End, se.StartReason, se.EndReason, se.Membership, gj, se.Payloads); err != nil {
			return err
		}
	}
	for _, g := range res.Gaps {
		if _, err := tx.Exec(ctx, `INSERT INTO volta_telemetry.gaps (vehicle_id, start_ts, end_ts, reason)
			VALUES ($1, $2, $3, $4) ON CONFLICT (vehicle_id, start_ts, reason) DO UPDATE SET end_ts = EXCLUDED.end_ts`,
			vehicleID, g.Start, g.End, g.Reason); err != nil {
			return err
		}
	}
	return nil
}

// Retention bounds raw and diagnostic data. Samples, sessions and recent
// receipts are the product and the billing ledger and are kept longer.
type Retention struct {
	Raw        time.Duration // records.raw payload bytes
	Rejections time.Duration
	// Receipts must cover more than the current and previous billing month.
	Receipts   time.Duration
	BatchLimit int
}

// DefaultRetention keeps raw payloads and rejections 30 days and receipts
// 400 days.
var DefaultRetention = Retention{Raw: 30 * 24 * time.Hour, Rejections: 30 * 24 * time.Hour, Receipts: 400 * 24 * time.Hour, BatchLimit: 5000}

// Prune applies retention in bounded batches. It returns rows touched.
func (s *Store) Prune(ctx context.Context, r Retention, now time.Time) (int64, error) {
	if r.BatchLimit <= 0 {
		return 0, errors.New("retention batch limit must be positive")
	}
	if r.Receipts < 62*24*time.Hour {
		return 0, errors.New("receipt retention must cover two billing months")
	}
	var total int64
	for _, q := range []struct {
		sql string
		age time.Duration
	}{
		{`UPDATE volta_telemetry.records SET raw = NULL
			WHERE ctid IN (SELECT ctid FROM volta_telemetry.records WHERE raw IS NOT NULL AND ingested_at < $1 LIMIT $2)`, r.Raw},
		{`DELETE FROM volta_telemetry.rejected_records
			WHERE ctid IN (SELECT ctid FROM volta_telemetry.rejected_records WHERE rejected_at < $1 LIMIT $2)`, r.Rejections},
		{`DELETE FROM volta_telemetry.receipts
			WHERE ctid IN (SELECT ctid FROM volta_telemetry.receipts WHERE received_at < $1 LIMIT $2)`, r.Receipts},
	} {
		tag, err := s.Pool.Exec(ctx, q.sql, now.Add(-q.age), r.BatchLimit)
		if err != nil {
			return total, err
		}
		total += tag.RowsAffected()
	}
	return total, nil
}

// Usage is the billable receipt total for one UTC month.
type Usage struct {
	// Signals counts every datum in every billable record handed off
	// durably, accepted or rejected, for any VIN.
	Signals int64
	// Uncountable records could not be decoded, so their signals are
	// unknown. Undated records had no receiver or broker time. Either one
	// makes the month total a lower bound only.
	Uncountable int64
	Undated     int64
}

// MonthUsage totals the receipts for the UTC month containing now.
func (s *Store) MonthUsage(ctx context.Context, now time.Time) (Usage, error) {
	var u Usage
	start := time.Date(now.UTC().Year(), now.UTC().Month(), 1, 0, 0, 0, 0, time.UTC)
	err := s.Pool.QueryRow(ctx, `SELECT COALESCE(sum(signal_count), 0)::bigint,
			count(*) FILTER (WHERE signal_count IS NULL)::bigint,
			count(*) FILTER (WHERE NOT dated)::bigint
		FROM volta_telemetry.receipts
		WHERE billable AND received_at >= $1 AND received_at < $2`, start, start.AddDate(0, 1, 0)).Scan(&u.Signals, &u.Uncountable, &u.Undated)
	return u, err
}

// Health is the stream liveness the consumer records for readers.
type Health struct {
	ReceiverGeneration string
	ReceiverStartedAt  time.Time // zero: unknown
	ReceiverSeenAt     time.Time // zero: never observed
	ConsumerStartedAt  time.Time
	CaughtUpAt         time.Time // zero: never caught up
	LagRecords         *int64
}

// UpdateHealth replaces the single stream_health row.
func (s *Store) UpdateHealth(ctx context.Context, h Health, now time.Time) error {
	_, err := s.Pool.Exec(ctx, `INSERT INTO volta_telemetry.stream_health
			(id, receiver_generation, receiver_started_at, receiver_seen_at, consumer_started_at, caught_up_at, lag_records, updated_at)
		VALUES (1, $1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (id) DO UPDATE SET receiver_generation = EXCLUDED.receiver_generation,
			receiver_started_at = EXCLUDED.receiver_started_at, receiver_seen_at = EXCLUDED.receiver_seen_at,
			consumer_started_at = EXCLUDED.consumer_started_at, caught_up_at = EXCLUDED.caught_up_at,
			lag_records = EXCLUDED.lag_records, updated_at = EXCLUDED.updated_at`,
		nullString(h.ReceiverGeneration), nullTime(h.ReceiverStartedAt), nullTime(h.ReceiverSeenAt),
		h.ConsumerStartedAt, nullTime(h.CaughtUpAt), h.LagRecords, now)
	return err
}

func nullTime(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}

func nullString(v string) *string {
	if v == "" {
		return nil
	}
	return &v
}
