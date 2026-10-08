// Package consumer moves records from the durable queue into Postgres with
// at-least-once delivery and idempotent writes:
//
//	poll -> normalize -> one DB transaction -> commit Kafka offsets
//
// Offsets are committed only after the transaction commits. A crash at any
// point replays the uncommitted records, and the store's keys make the
// replay a no-op. A DB failure never commits offsets; the batch is retried.
package consumer

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/georgenijo/volta/ingestion/normalize"
	"github.com/georgenijo/volta/ingestion/store"
)

// Source is the queue side.
type Source interface {
	Poll(ctx context.Context) ([]normalize.Record, error)
	Commit(ctx context.Context, recs []normalize.Record) error
}

// Sink is the database side.
type Sink interface {
	Apply(ctx context.Context, items []store.Item) error
}

// Stats are aggregate counters. They never carry VINs or values.
type Stats struct {
	mu        sync.Mutex
	Accepted  int64
	Rejected  map[string]int64
	Batches   int64
	Retries   int64
	LastApply time.Time
	// Retrying is true while a polled batch is not yet stored.
	Retrying bool
}

// StatsSnapshot is a lock-free copy of Stats.
type StatsSnapshot struct {
	Accepted  int64
	Rejected  map[string]int64
	Batches   int64
	Retries   int64
	LastApply time.Time
	Retrying  bool
}

// Snapshot copies the counters.
func (s *Stats) Snapshot() StatsSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	cp := StatsSnapshot{Accepted: s.Accepted, Batches: s.Batches, Retries: s.Retries, LastApply: s.LastApply, Retrying: s.Retrying, Rejected: map[string]int64{}}
	for k, v := range s.Rejected {
		cp.Rejected[k] = v
	}
	return cp
}

// Consumer wires the pieces.
type Consumer struct {
	Source Source
	Sink   Sink
	Norm   *normalize.Normalizer
	Log    *slog.Logger
	Stats  *Stats
	// AfterWrite runs between the DB commit and the offset commit. Tests use
	// it to simulate a crash in that window. Nil in production.
	AfterWrite func()
	// Backoff bounds DB retry waits.
	MinBackoff, MaxBackoff time.Duration
}

// Build turns records into store items. Every item carries the record's
// billing receipt, computed from the raw record before (and independently
// of) normalization, so rejected records are billed too.
func (c *Consumer) Build(recs []normalize.Record) []store.Item {
	now := time.Now()
	items := make([]store.Item, 0, len(recs))
	for _, r := range recs {
		rc := c.Norm.Receipt(r, now)
		m, err := c.Norm.Normalize(r)
		if err != nil {
			reason, ok := normalize.IsRejection(err)
			if !ok {
				reason = normalize.ReasonDecode
			}
			items = append(items, store.Item{Topic: r.Topic, Partition: r.Partition, Offset: r.Offset, Reason: reason, Receipt: rc})
			continue
		}
		items = append(items, store.Item{Message: m, Receipt: rc})
	}
	return items
}

// Step processes one poll. It returns only when the batch is durably stored
// and committed, the context is cancelled, or polling/committing fails.
func (c *Consumer) Step(ctx context.Context) error {
	recs, err := c.Source.Poll(ctx)
	if err != nil {
		return err
	}
	if len(recs) == 0 {
		return nil
	}
	items := c.Build(recs)
	backoff := c.MinBackoff
	if backoff <= 0 {
		backoff = 500 * time.Millisecond
	}
	maxBackoff := c.MaxBackoff
	if maxBackoff <= 0 {
		maxBackoff = 30 * time.Second
	}
	for {
		err := c.Sink.Apply(ctx, items)
		if err == nil {
			break
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		c.bump(func(s *Stats) { s.Retries++; s.Retrying = true })
		// The error text comes from pgx and may name a constraint or table;
		// it never contains row values because all values are bind params.
		c.logger().Warn("telemetry batch not stored; retrying", "records", len(recs), "backoff", backoff.String(), "error_kind", errorKind(err))
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, maxBackoff)
	}
	// Apply may have quarantined items in place (store.ReasonStoreRejected);
	// the stats below count the stored outcome.
	if c.AfterWrite != nil {
		c.AfterWrite()
	}
	if err := c.Source.Commit(ctx, recs); err != nil {
		return err
	}
	c.bump(func(s *Stats) {
		s.Retrying = false
		s.Batches++
		s.LastApply = time.Now()
		if s.Rejected == nil {
			s.Rejected = map[string]int64{}
		}
		for _, it := range items {
			if it.Message != nil {
				s.Accepted++
			} else {
				s.Rejected[it.Reason]++
			}
		}
	})
	return nil
}

// Run loops until ctx is cancelled.
func (c *Consumer) Run(ctx context.Context) error {
	for {
		if err := c.Step(ctx); err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
	}
}

func (c *Consumer) bump(f func(*Stats)) {
	if c.Stats == nil {
		return
	}
	c.Stats.mu.Lock()
	f(c.Stats)
	c.Stats.mu.Unlock()
}

func (c *Consumer) logger() *slog.Logger {
	if c.Log != nil {
		return c.Log
	}
	return slog.Default()
}

func errorKind(err error) string {
	if err == nil {
		return ""
	}
	if err == context.DeadlineExceeded {
		return "timeout"
	}
	return "store_error"
}
