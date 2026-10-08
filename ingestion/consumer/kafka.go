package consumer

import (
	"context"
	"errors"

	"github.com/georgenijo/volta/ingestion/normalize"
	"github.com/twmb/franz-go/pkg/kgo"
)

// KafkaSource reads the receiver topics with manual offset commits.
type KafkaSource struct {
	Client     *kgo.Client
	MaxRecords int
	pending    []*kgo.Record
}

// KafkaConfig is the consumer-side Kafka configuration.
type KafkaConfig struct {
	Brokers    []string
	Group      string
	Topics     []string
	MaxRecords int
}

// NewKafkaSource builds a franz-go client. Auto-commit is disabled and
// rebalances are blocked while a polled batch is in flight, so a batch is
// either fully stored and committed or replayed.
func NewKafkaSource(cfg KafkaConfig) (*KafkaSource, error) {
	if len(cfg.Brokers) == 0 || cfg.Group == "" || len(cfg.Topics) == 0 {
		return nil, errors.New("kafka brokers, group and topics are required")
	}
	if cfg.MaxRecords <= 0 {
		cfg.MaxRecords = 500
	}
	cl, err := kgo.NewClient(
		kgo.SeedBrokers(cfg.Brokers...),
		kgo.ConsumerGroup(cfg.Group),
		kgo.ConsumeTopics(cfg.Topics...),
		kgo.DisableAutoCommit(),
		kgo.BlockRebalanceOnPoll(),
		kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()),
		kgo.FetchMaxBytes(8<<20),
		kgo.FetchIsolationLevel(kgo.ReadCommitted()),
	)
	if err != nil {
		return nil, err
	}
	return &KafkaSource{Client: cl, MaxRecords: cfg.MaxRecords}, nil
}

// Poll returns the next batch.
func (k *KafkaSource) Poll(ctx context.Context) ([]normalize.Record, error) {
	fetches := k.Client.PollRecords(ctx, k.MaxRecords)
	if fetches.IsClientClosed() {
		return nil, errors.New("kafka client closed")
	}
	if err := ctx.Err(); err != nil {
		k.Client.AllowRebalance()
		return nil, err
	}
	var ferr error
	fetches.EachError(func(_ string, _ int32, err error) {
		if ferr == nil {
			ferr = err
		}
	})
	if ferr != nil {
		k.Client.AllowRebalance()
		return nil, ferr
	}
	k.pending = k.pending[:0]
	var out []normalize.Record
	fetches.EachRecord(func(r *kgo.Record) {
		h := make(map[string]string, len(r.Headers))
		for _, kv := range r.Headers {
			h[kv.Key] = string(kv.Value)
		}
		out = append(out, normalize.Record{
			Topic: r.Topic, Partition: r.Partition, Offset: r.Offset,
			Key: r.Key, Value: r.Value, Headers: h, Timestamp: r.Timestamp,
		})
		k.pending = append(k.pending, r)
	})
	if len(out) == 0 {
		k.Client.AllowRebalance()
	}
	return out, nil
}

// Commit commits the offsets of the last polled batch and then permits
// rebalancing again.
func (k *KafkaSource) Commit(ctx context.Context, _ []normalize.Record) error {
	defer k.Client.AllowRebalance()
	if len(k.pending) == 0 {
		return nil
	}
	return k.Client.CommitRecords(ctx, k.pending...)
}

// Close leaves the group cleanly.
func (k *KafkaSource) Close() { k.Client.Close() }
