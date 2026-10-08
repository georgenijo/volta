package store

import (
	"context"
	"errors"
	"time"

	"github.com/georgenijo/volta/ingestion/contract"
	"github.com/jackc/pgx/v5"
)

// DrivePoints returns same-payload trip points in [from, to] ordered by
// source time. This is the reference query the Volta API should run against
// volta_telemetry.drive_points (as volta_readonly).
func (s *Store) DrivePoints(ctx context.Context, vehicleID int, from, to time.Time) ([]contract.DrivePoint, error) {
	rows, err := s.Pool.Query(ctx, `SELECT source_ts, latitude, longitude, speed_kph, heading_deg, power_kw, power_sign,
			pack_voltage_v, pack_current_a, battery_level_pct, trip_membership, route_break_before
		FROM volta_telemetry.drive_points
		WHERE vehicle_id = $1 AND source_ts BETWEEN $2 AND $3
		ORDER BY source_ts`, vehicleID, from, to)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []contract.DrivePoint{}
	for rows.Next() {
		var r contract.DrivePointRow
		if err := rows.Scan(&r.SourceTS, &r.Latitude, &r.Longitude, &r.SpeedKph, &r.HeadingDeg, &r.PowerKw, &r.PowerSign,
			&r.PackVoltageV, &r.PackCurrentA, &r.BatteryLevelPct, &r.TripMembership, &r.RouteBreak); err != nil {
			return nil, err
		}
		out = append(out, contract.FromRow(r))
	}
	return out, rows.Err()
}

// DefaultLivenessMaxAge bounds how old the receiver and consumer liveness
// observations in stream_health may be for a link to count as connected.
const DefaultLivenessMaxAge = 90 * time.Second

// Link derives the stream state for freshness. It is connected only when
// all of these hold at now:
//
//   - the receiver was observed alive within maxAge (stream_health);
//   - the consumer caught up with the queue within maxAge, so no newer
//     DISCONNECTED event can be waiting unprocessed;
//   - the vehicle's newest connectivity event is CONNECTED and is no older
//     than the running receiver generation (a CONNECTED event from before
//     a receiver restart or SIGKILL describes a socket that is gone).
//
// Since is the later of that event and the newest stored gap end.
func (s *Store) Link(ctx context.Context, vehicleID int, now time.Time, maxAge time.Duration) (contract.Link, error) {
	if maxAge <= 0 {
		maxAge = DefaultLivenessMaxAge
	}
	var generation *string
	var started, seen, caughtUp *time.Time
	err := s.Pool.QueryRow(ctx, `SELECT receiver_generation, receiver_started_at, receiver_seen_at, caught_up_at
		FROM volta_telemetry.stream_health WHERE id = 1`).Scan(&generation, &started, &seen, &caughtUp)
	if errors.Is(err, pgx.ErrNoRows) {
		return contract.Link{}, nil
	}
	if err != nil {
		return contract.Link{}, err
	}
	fresh := func(t *time.Time) bool { return t != nil && !t.After(now) && now.Sub(*t) <= maxAge }
	if generation == nil || *generation == "" || started == nil || !fresh(seen) || !fresh(caughtUp) {
		return contract.Link{}, nil
	}
	var status *string
	var ts, received *time.Time
	err = s.Pool.QueryRow(ctx, `SELECT status, source_ts, received_at FROM volta_telemetry.connectivity
		WHERE vehicle_id = $1 ORDER BY source_ts DESC, received_at DESC, status DESC LIMIT 1`, vehicleID).Scan(&status, &ts, &received)
	if errors.Is(err, pgx.ErrNoRows) {
		return contract.Link{}, nil
	}
	if err != nil {
		return contract.Link{}, err
	}
	// received_at is the receiver's millisecond handoff time. Comparing it
	// to the guard's exact start instant fences the active generation without
	// rounding: an old CONNECTED created in the same wall-clock second as a
	// replacement receiver can never revive that replacement's stream.
	if status == nil || *status != "CONNECTED" || ts == nil || received == nil || received.Before(*started) {
		return contract.Link{}, nil
	}
	since := *ts
	if started.After(since) {
		since = *started
	}
	l := contract.Link{Connected: true, Since: since}
	var gapEnd *time.Time
	if err := s.Pool.QueryRow(ctx, `SELECT max(end_ts) FROM volta_telemetry.gaps
		WHERE vehicle_id = $1 AND reason IN ('disconnected', 'silence')`, vehicleID).Scan(&gapEnd); err != nil {
		return contract.Link{}, err
	}
	if gapEnd != nil && gapEnd.After(l.Since) {
		l.Since = *gapEnd
	}
	return l, nil
}

// Snapshot returns the latest value of every field with its own source time.
func (s *Store) Snapshot(ctx context.Context, vehicleID int, now time.Time) (contract.Snapshot, error) {
	link, err := s.Link(ctx, vehicleID, now, DefaultLivenessMaxAge)
	if err != nil {
		return contract.Snapshot{}, err
	}
	rows, err := s.Pool.Query(ctx, `SELECT field, source_ts, value_num, value_text, value_bool, latitude, longitude, invalid, quality
		FROM volta_telemetry.latest_samples WHERE vehicle_id = $1 ORDER BY field`, vehicleID)
	if err != nil {
		return contract.Snapshot{}, err
	}
	defer rows.Close()
	var lr []contract.LatestRow
	for rows.Next() {
		var r contract.LatestRow
		if err := rows.Scan(&r.Field, &r.SourceTS, &r.Num, &r.Text, &r.Bool, &r.Latitude, &r.Longitude, &r.Invalid, &r.Quality); err != nil {
			return contract.Snapshot{}, err
		}
		lr = append(lr, r)
	}
	if err := rows.Err(); err != nil {
		return contract.Snapshot{}, err
	}
	return contract.SnapshotFrom(vehicleID, lr, link, now), nil
}
