package consumer

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/georgenijo/volta/ingestion/internal/testvin"
	"github.com/georgenijo/volta/ingestion/normalize"
	"github.com/georgenijo/volta/ingestion/store"
	"github.com/georgenijo/volta/ingestion/vehicles"
	"github.com/teslamotors/fleet-telemetry/protos"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// fakeSource is an in-memory partition with a committed offset.
type fakeSource struct {
	mu        sync.Mutex
	recs      []normalize.Record
	committed int // next offset to deliver
	inflight  int
}

func (f *fakeSource) Poll(ctx context.Context) ([]normalize.Record, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.committed >= len(f.recs) {
		return nil, ctx.Err()
	}
	end := min(f.committed+3, len(f.recs))
	f.inflight = end
	return append([]normalize.Record(nil), f.recs[f.committed:end]...), nil
}

func (f *fakeSource) Commit(context.Context, []normalize.Record) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.committed = f.inflight
	return nil
}

// fakeSink is an idempotent store keyed like volta_telemetry.records.
type fakeSink struct {
	mu       sync.Mutex
	fail     int
	rows     map[int64]bool
	rejected map[int64]string
	applies  int
}

func (s *fakeSink) Apply(_ context.Context, items []store.Item) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.applies++
	if s.fail > 0 {
		s.fail--
		return errors.New("connection refused")
	}
	for _, it := range items {
		if it.Message != nil {
			s.rows[it.Message.Offset] = true
		} else {
			s.rejected[it.Offset] = it.Reason
		}
	}
	return nil
}

var t0 = time.Date(2026, 10, 8, 17, 0, 0, 0, time.UTC)

func record(i int, vin string) normalize.Record {
	b, _ := proto.Marshal(&protos.Payload{Vin: vin, CreatedAt: timestamppb.New(t0.Add(time.Duration(i) * 10 * time.Second)),
		Data: []*protos.Datum{{Key: protos.Field_VehicleSpeed, Value: &protos.Value{Value: &protos.Value_DoubleValue{DoubleValue: 31}}}}})
	return normalize.Record{Topic: "tesla_telemetry_V", Offset: int64(i), Key: []byte(vin), Value: b, Headers: map[string]string{
		"vin": vin, "txtype": "V", "receivedat": strconv.FormatInt(t0.Add(time.Hour).UnixMilli(), 10),
	}}
}

func setup(t *testing.T, n int) (*Consumer, *fakeSource, *fakeSink, *bytes.Buffer) {
	t.Helper()
	a, err := vehicles.Parse(testvin.Mapping)
	if err != nil {
		t.Fatal(err)
	}
	src := &fakeSource{}
	for i := 0; i < n; i++ {
		vin := testvin.A
		if i%4 == 3 {
			vin = testvin.Rogue
		}
		src.recs = append(src.recs, record(i, vin))
	}
	sink := &fakeSink{rows: map[int64]bool{}, rejected: map[int64]string{}}
	var logs bytes.Buffer
	c := &Consumer{Source: src, Sink: sink, Norm: normalize.New("tesla_telemetry", a),
		Log: slog.New(slog.NewJSONHandler(&logs, nil)), Stats: &Stats{}, MinBackoff: time.Millisecond, MaxBackoff: 2 * time.Millisecond}
	return c, src, sink, &logs
}

func TestNoCommitUntilStored(t *testing.T) {
	c, src, sink, logs := setup(t, 3)
	sink.fail = 2
	if err := c.Step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if sink.applies != 3 || src.committed != 3 || c.Stats.Snapshot().Retries != 2 {
		t.Fatalf("applies %d committed %d", sink.applies, src.committed)
	}
	// Retry logs carry counts and kinds only.
	if l := logs.String(); strings.Contains(l, "5YJ3E1EA0XF") || strings.Contains(l, "connection refused") {
		t.Fatalf("log leaks: %s", l)
	}
}

func TestCancelledWhileFailingDoesNotCommit(t *testing.T) {
	c, src, sink, _ := setup(t, 3)
	sink.fail = 1 << 30
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if err := c.Step(ctx); err == nil {
		t.Fatal("expected cancellation")
	}
	if src.committed != 0 {
		t.Fatal("offsets committed although nothing was stored")
	}
}

func TestCrashBetweenWriteAndCommitReplaysIdempotently(t *testing.T) {
	c, src, sink, _ := setup(t, 6)
	crashed := false
	c.AfterWrite = func() {
		if !crashed {
			crashed = true
			panic("simulated crash")
		}
	}
	func() {
		defer func() { _ = recover() }()
		_ = c.Step(context.Background())
	}()
	if src.committed != 0 || len(sink.rows)+len(sink.rejected) != 3 {
		t.Fatalf("after crash committed %d stored %d", src.committed, len(sink.rows)+len(sink.rejected))
	}
	// "Restart": a new consumer on the same source replays the batch.
	c.AfterWrite = nil
	for src.committed < len(src.recs) {
		if err := c.Step(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if len(sink.rows) != 5 || len(sink.rejected) != 1 || sink.rejected[3] != normalize.ReasonUnregistered {
		t.Fatalf("rows %d rejected %v", len(sink.rows), sink.rejected)
	}
}

func TestEveryItemCarriesReceipt(t *testing.T) {
	c, src, _, _ := setup(t, 4)
	items := c.Build(src.recs)
	for i, it := range items {
		if !it.Receipt.Billable || it.Receipt.Signals == nil || *it.Receipt.Signals != 1 || !it.Receipt.Dated {
			t.Fatalf("item %d receipt %+v", i, it.Receipt)
		}
	}
	if items[3].Message != nil || items[3].Reason != normalize.ReasonUnregistered {
		t.Fatalf("rogue VIN not rejected: %+v", items[3])
	}
}

// quarantineSink rejects one item in place, like store.Apply does for a
// permanent database error.
type quarantineSink struct{ fakeSink }

func (s *quarantineSink) Apply(ctx context.Context, items []store.Item) error {
	items[0].Message = nil
	items[0].Reason = store.ReasonStoreRejected
	return s.fakeSink.Apply(ctx, items)
}

func TestStatsCountStoredOutcome(t *testing.T) {
	c, src, _, _ := setup(t, 3)
	q := &quarantineSink{fakeSink{rows: map[int64]bool{}, rejected: map[int64]string{}}}
	c.Sink = q
	sink := &q.fakeSink
	if err := c.Step(context.Background()); err != nil {
		t.Fatal(err)
	}
	s := c.Stats.Snapshot()
	if src.committed != 3 || s.Accepted != 2 || s.Rejected[store.ReasonStoreRejected] != 1 || s.Retrying || len(sink.rows) != 2 {
		t.Fatalf("stats %+v", s)
	}
}
