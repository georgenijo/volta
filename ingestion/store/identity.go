package store

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// ErrVehicleBindingChanged is returned when an allowlist attempts to assign
// an existing vehicle id to another VIN digest, or an existing VIN digest to
// another vehicle id. The error deliberately carries neither digest nor VIN.
var ErrVehicleBindingChanged = errors.New("telemetry vehicle identity binding changed")

// EnsureVehicleBindings permanently records and verifies every configured
// vehicle identity before consumption starts. Missing allowlist entries are
// retained so historical identities cannot later be reassigned.
func (s *Store) EnsureVehicleBindings(ctx context.Context, bindings map[int]string) error {
	ids := make([]int, 0, len(bindings))
	for id := range bindings {
		ids = append(ids, id)
	}
	sort.Ints(ids)
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('volta_telemetry.vehicle_bindings'))`); err != nil {
			return err
		}
		for _, id := range ids {
			digest := bindings[id]
			if _, err := tx.Exec(ctx, `INSERT INTO volta_telemetry.vehicle_bindings (vehicle_id, vin_digest)
				VALUES ($1, $2) ON CONFLICT DO NOTHING`, id, digest); err != nil {
				return err
			}
			rows, err := tx.Query(ctx, `SELECT vehicle_id, vin_digest FROM volta_telemetry.vehicle_bindings
				WHERE vehicle_id = $1 OR vin_digest = $2`, id, digest)
			if err != nil {
				return err
			}
			matches := 0
			for rows.Next() {
				var gotID int
				var gotDigest string
				if err := rows.Scan(&gotID, &gotDigest); err != nil {
					rows.Close()
					return err
				}
				if gotID != id || gotDigest != digest {
					rows.Close()
					return ErrVehicleBindingChanged
				}
				matches++
			}
			if err := rows.Err(); err != nil {
				rows.Close()
				return err
			}
			rows.Close()
			if matches != 1 {
				return ErrVehicleBindingChanged
			}
		}
		return nil
	})
}

// QueueCheckpoint is durable proof for one exact topic incarnation and
// partition. NextOffset is the first offset not yet known durably receipted.
type QueueCheckpoint struct {
	TopicID    string
	NextOffset int64
}

// QueueCheckpoints are keyed by topic then partition.
type QueueCheckpoints map[string]map[int32]QueueCheckpoint

// LoadQueueCheckpoints returns every durable checkpoint for the named topics.
func (s *Store) LoadQueueCheckpoints(ctx context.Context, topics []string) (QueueCheckpoints, error) {
	rows, err := s.Pool.Query(ctx, `SELECT topic, kafka_partition, topic_id, next_offset
		FROM volta_telemetry.queue_checkpoints WHERE topic = ANY($1)`, topics)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := QueueCheckpoints{}
	for rows.Next() {
		var topic, topicID string
		var partition int32
		var next int64
		if err := rows.Scan(&topic, &partition, &topicID, &next); err != nil {
			return nil, err
		}
		if out[topic] == nil {
			out[topic] = map[int32]QueueCheckpoint{}
		}
		out[topic][partition] = QueueCheckpoint{TopicID: topicID, NextOffset: next}
	}
	return out, rows.Err()
}

// ReceiptsCover reports whether every offset in [from,to) has a durable
// billing receipt. It is used once when establishing a checkpoint over an
// already-consumed queue.
func (s *Store) ReceiptsCover(ctx context.Context, topic string, partition int32, from, to int64) (bool, error) {
	if from < 0 || to < from {
		return false, nil
	}
	if from == to {
		return true, nil
	}
	var count int64
	err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM volta_telemetry.receipts
		WHERE topic = $1 AND kafka_partition = $2 AND kafka_offset >= $3 AND kafka_offset < $4`,
		topic, partition, from, to).Scan(&count)
	return count == to-from, err
}

// SaveQueueCheckpoints advances checkpoints monotonically. A topic-id
// mismatch cannot update the row and is reported as a continuity failure.
func (s *Store) SaveQueueCheckpoints(ctx context.Context, checkpoints QueueCheckpoints, now time.Time) error {
	topics := make([]string, 0, len(checkpoints))
	for topic := range checkpoints {
		topics = append(topics, topic)
	}
	sort.Strings(topics)
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		for _, topic := range topics {
			partitions := make([]int, 0, len(checkpoints[topic]))
			for partition := range checkpoints[topic] {
				partitions = append(partitions, int(partition))
			}
			sort.Ints(partitions)
			for _, p := range partitions {
				cp := checkpoints[topic][int32(p)]
				tag, err := tx.Exec(ctx, `INSERT INTO volta_telemetry.queue_checkpoints AS q
					(topic, kafka_partition, topic_id, next_offset, updated_at)
					VALUES ($1, $2, $3, $4, $5)
					ON CONFLICT (topic, kafka_partition) DO UPDATE SET
					  next_offset = GREATEST(q.next_offset, EXCLUDED.next_offset), updated_at = EXCLUDED.updated_at
					WHERE q.topic_id = EXCLUDED.topic_id`, topic, int32(p), cp.TopicID, cp.NextOffset, now)
				if err != nil {
					return err
				}
				if tag.RowsAffected() != 1 {
					return errors.New("telemetry queue topic generation changed")
				}
			}
		}
		return nil
	})
}
