package consumer

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/georgenijo/volta/ingestion/store"
	"github.com/twmb/franz-go/pkg/kadm"
	"github.com/twmb/franz-go/pkg/kgo"
)

// Offsets are per-topic, per-partition Kafka offsets.
type Offsets map[string]map[int32]int64

// OffsetReader reads the broker's view of the queue.
type OffsetReader interface {
	// StartOffsets returns the oldest retained offset in every partition.
	StartOffsets(ctx context.Context, topics []string) (Offsets, error)
	// EndOffsets returns the next offset to be written in every partition
	// of the topics. A topic that is missing or has no partitions is an
	// error.
	EndOffsets(ctx context.Context, topics []string) (Offsets, error)
	// Committed returns the group's committed offsets (the next offset to
	// consume). Partitions without a commit are absent.
	Committed(ctx context.Context) (Offsets, error)
	// TopicIDs returns the broker-assigned identity for each exact topic
	// incarnation. An empty or missing id is an error.
	TopicIDs(ctx context.Context, topics []string) (map[string]string, error)
}

// CheckpointStore makes queue-history continuity survive process restarts.
// A retained suffix is accepted only when an earlier checkpoint or the
// receipt ledger proves every preceding offset was accounted for.
type CheckpointStore interface {
	LoadQueueCheckpoints(ctx context.Context, topics []string) (store.QueueCheckpoints, error)
	ReceiptsCover(ctx context.Context, topic string, partition int32, from, to int64) (bool, error)
	SaveQueueCheckpoints(ctx context.Context, checkpoints store.QueueCheckpoints, now time.Time) error
}

// Progress proves how far the durable handoff has got. Each Tick reads the
// committed offsets, then the end offsets at time at. Every record the
// broker held at that time has a smaller offset than the end offset, and
// the consumer commits only after the record's receipt is stored, so once
// the committed offsets reach a snapshot's end offsets, every record the
// broker held at the snapshot time is accounted for. That time is
// AccountedThrough. It only moves forward when that is proven: a stalled
// consumer or a backlog leaves it at the last proven snapshot. A missing
// topic or partition, unreadable broker, topic replacement, or unproven
// retention resets it immediately so the meter fails closed.
type Progress struct {
	Reader      OffsetReader
	Checkpoints CheckpointStore
	Topics      []string

	mu      sync.Mutex
	pending *offsetSnapshot
	through time.Time
	lag     *int64
	err     error
}

type offsetSnapshot struct {
	at  time.Time
	end Offsets
}

// Tick takes one measurement. at must be read before Tick is called.
func (p *Progress) Tick(ctx context.Context, at time.Time) error {
	err := p.tick(ctx, at)
	p.mu.Lock()
	p.err = err
	if err != nil {
		p.lag = nil
		// Queue continuity failures are a billing safety boundary. Do not
		// retain a recently healthy timestamp during the meter grace window.
		p.through = time.Time{}
	}
	p.mu.Unlock()
	return err
}

func (p *Progress) tick(ctx context.Context, at time.Time) error {
	if p.Reader == nil || p.Checkpoints == nil || len(p.Topics) == 0 {
		return errors.New("queue progress is not configured")
	}
	committed, err := p.Reader.Committed(ctx)
	if err != nil {
		return err
	}
	start, err := p.Reader.StartOffsets(ctx, p.Topics)
	if err != nil {
		return err
	}
	end, err := p.Reader.EndOffsets(ctx, p.Topics)
	if err != nil {
		return err
	}
	ids, err := p.Reader.TopicIDs(ctx, p.Topics)
	if err != nil {
		return err
	}
	saved, err := p.Checkpoints.LoadQueueCheckpoints(ctx, p.Topics)
	if err != nil {
		return err
	}
	next := store.QueueCheckpoints{}
	var lag int64
	for _, t := range p.Topics {
		if ids[t] == "" || len(end[t]) == 0 || len(start[t]) != len(end[t]) {
			return errors.New("queue topic identity or partition missing")
		}
		for part := range saved[t] {
			if _, ok := end[t][part]; !ok {
				return errors.New("queue partition disappeared")
			}
		}
		next[t] = map[int32]store.QueueCheckpoint{}
		for part, e := range end[t] {
			st, ok := start[t][part]
			if !ok || st < 0 || e < st {
				return errors.New("queue offsets are invalid")
			}
			c := committed[t][part]
			if c < 0 || c > e {
				return errors.New("queue committed offset is invalid")
			}
			cp, exists := saved[t][part]
			if exists {
				if cp.TopicID != ids[t] || cp.NextOffset < 0 || e < cp.NextOffset {
					return errors.New("queue history continuity lost")
				}
				if st > cp.NextOffset {
					covered, err := p.Checkpoints.ReceiptsCover(ctx, t, part, cp.NextOffset, st)
					if err != nil {
						return err
					}
					if !covered {
						return errors.New("queue retention passed the durable checkpoint")
					}
					cp.NextOffset = st
				}
			} else {
				// First run or a newly added partition. Prove any already
				// committed prefix from receipts; the broker retaining only a
				// suffix can never establish history by itself.
				proveThrough := max(c, st)
				covered, err := p.Checkpoints.ReceiptsCover(ctx, t, part, 0, proveThrough)
				if err != nil {
					return err
				}
				if !covered {
					return errors.New("queue history before retained start is unproven")
				}
				cp.NextOffset = proveThrough
			}
			n := c
			if cp.NextOffset > n {
				n = cp.NextOffset
			}
			next[t][part] = store.QueueCheckpoint{TopicID: ids[t], NextOffset: n}
			if d := e - c; d > 0 {
				lag += d
			}
		}
	}
	if err := p.Checkpoints.SaveQueueCheckpoints(ctx, next, at); err != nil {
		return err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.lag = &lag
	if p.pending != nil && covers(committed, p.pending.end) && p.pending.at.After(p.through) {
		p.through = p.pending.at
	}
	// Committed was read before end: if it already covers end, every record
	// the broker held at time at is accounted for now.
	if covers(committed, end) && at.After(p.through) {
		p.through = at
	}
	p.pending = &offsetSnapshot{at: at, end: end}
	return nil
}

// covers reports whether committed has reached end in every partition. A
// partition with no commit counts as offset 0.
func covers(committed, end Offsets) bool {
	for t, ps := range end {
		for part, e := range ps {
			if committed[t][part] < e {
				return false
			}
		}
	}
	return true
}

// ProgressState is a copy of the latest measurement.
type ProgressState struct {
	// AccountedThrough is zero until the handoff has been proven once.
	AccountedThrough time.Time
	// LagRecords is nil when the last measurement failed.
	LagRecords *int64
	Err        error
}

// State returns the latest measurement.
func (p *Progress) State() ProgressState {
	p.mu.Lock()
	defer p.mu.Unlock()
	return ProgressState{AccountedThrough: p.through, LagRecords: p.lag, Err: p.err}
}

// KafkaOffsets reads offsets with the Kafka admin API.
type KafkaOffsets struct {
	Admin *kadm.Client
	Group string
}

// NewKafkaOffsets shares the consumer's client.
func NewKafkaOffsets(cl *kgo.Client, group string) *KafkaOffsets {
	return &KafkaOffsets{Admin: kadm.NewClient(cl), Group: group}
}

// StartOffsets implements OffsetReader.
func (k *KafkaOffsets) StartOffsets(ctx context.Context, topics []string) (Offsets, error) {
	l, err := k.Admin.ListStartOffsets(ctx, topics...)
	if err != nil {
		return nil, err
	}
	if err := l.Error(); err != nil {
		return nil, err
	}
	out := Offsets{}
	l.Each(func(o kadm.ListedOffset) {
		if out[o.Topic] == nil {
			out[o.Topic] = map[int32]int64{}
		}
		out[o.Topic][o.Partition] = o.Offset
	})
	return out, nil
}

// EndOffsets implements OffsetReader.
func (k *KafkaOffsets) EndOffsets(ctx context.Context, topics []string) (Offsets, error) {
	l, err := k.Admin.ListEndOffsets(ctx, topics...)
	if err != nil {
		return nil, err
	}
	if err := l.Error(); err != nil {
		return nil, err
	}
	out := Offsets{}
	l.Each(func(o kadm.ListedOffset) {
		if out[o.Topic] == nil {
			out[o.Topic] = map[int32]int64{}
		}
		out[o.Topic][o.Partition] = o.Offset
	})
	return out, nil
}

// Committed implements OffsetReader.
func (k *KafkaOffsets) Committed(ctx context.Context) (Offsets, error) {
	r, err := k.Admin.FetchOffsets(ctx, k.Group)
	if err != nil {
		return nil, err
	}
	if err := r.Error(); err != nil {
		return nil, err
	}
	out := Offsets{}
	r.Each(func(o kadm.OffsetResponse) {
		if o.At < 0 {
			return
		}
		if out[o.Topic] == nil {
			out[o.Topic] = map[int32]int64{}
		}
		out[o.Topic][o.Partition] = o.At
	})
	return out, nil
}

// TopicIDs implements OffsetReader.
func (k *KafkaOffsets) TopicIDs(ctx context.Context, topics []string) (map[string]string, error) {
	m, err := k.Admin.Metadata(ctx, topics...)
	if err != nil {
		return nil, err
	}
	out := make(map[string]string, len(topics))
	var zero kadm.TopicID
	for _, topic := range topics {
		d, ok := m.Topics[topic]
		if !ok || d.Err != nil || d.ID == zero || len(d.Partitions) == 0 {
			return nil, errors.New("queue topic identity unavailable")
		}
		out[topic] = d.ID.String()
	}
	return out, nil
}
