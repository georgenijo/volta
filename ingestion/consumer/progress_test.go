package consumer

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/georgenijo/volta/ingestion/store"
)

type fakeOffsets struct {
	start, end, committed Offsets
	ids                   map[string]string
	endErr                error
}

func (f *fakeOffsets) StartOffsets(context.Context, []string) (Offsets, error) { return f.start, nil }

func (f *fakeOffsets) EndOffsets(context.Context, []string) (Offsets, error) {
	if f.endErr != nil {
		return nil, f.endErr
	}
	return f.end, nil
}
func (f *fakeOffsets) Committed(context.Context) (Offsets, error) { return f.committed, nil }
func (f *fakeOffsets) TopicIDs(context.Context, []string) (map[string]string, error) {
	return f.ids, nil
}

type fakeCheckpoints struct {
	saved      store.QueueCheckpoints
	receiptsOK bool
	saveErr    error
}

func (f *fakeCheckpoints) LoadQueueCheckpoints(context.Context, []string) (store.QueueCheckpoints, error) {
	return f.saved, nil
}
func (f *fakeCheckpoints) ReceiptsCover(context.Context, string, int32, int64, int64) (bool, error) {
	return f.receiptsOK, nil
}
func (f *fakeCheckpoints) SaveQueueCheckpoints(_ context.Context, cp store.QueueCheckpoints, _ time.Time) error {
	if f.saveErr != nil {
		return f.saveErr
	}
	f.saved = cp
	return nil
}

func TestProgressProvesHandoff(t *testing.T) {
	t0 := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	f := &fakeOffsets{
		start:     Offsets{"x_V": {0: 0}, "x_connectivity": {0: 0}},
		end:       Offsets{"x_V": {0: 10}, "x_connectivity": {0: 2}},
		committed: Offsets{"x_V": {0: 4}},
		ids:       map[string]string{"x_V": "topic-v", "x_connectivity": "topic-c"},
	}
	h := &fakeCheckpoints{receiptsOK: true}
	p := &Progress{Reader: f, Checkpoints: h, Topics: []string{"x_V", "x_connectivity"}}
	ctx := context.Background()

	// Startup with a backlog: nothing proven.
	if err := p.Tick(ctx, t0); err != nil {
		t.Fatal(err)
	}
	if s := p.State(); !s.AccountedThrough.IsZero() || s.LagRecords == nil || *s.LagRecords != 8 {
		t.Fatalf("backlog: %+v", s)
	}
	// Stalled: commits do not move, so AccountedThrough never advances.
	for i := 1; i <= 3; i++ {
		_ = p.Tick(ctx, t0.Add(time.Duration(i)*15*time.Second))
	}
	if s := p.State(); !s.AccountedThrough.IsZero() {
		t.Fatalf("stalled consumer advanced accounting: %+v", s)
	}
	// The consumer reaches the earlier snapshot while new records arrive:
	// accounted through that snapshot's time, not now.
	f.committed = Offsets{"x_V": {0: 10}, "x_connectivity": {0: 2}}
	f.end = Offsets{"x_V": {0: 12}, "x_connectivity": {0: 2}}
	t1 := t0.Add(time.Minute)
	_ = p.Tick(ctx, t1)
	if s := p.State(); !s.AccountedThrough.Equal(t0.Add(45*time.Second)) || *s.LagRecords != 2 {
		t.Fatalf("partial catch-up: %+v", s)
	}
	// Fully caught up: accounted through the tick time.
	f.committed = Offsets{"x_V": {0: 12}, "x_connectivity": {0: 2}}
	_ = p.Tick(ctx, t1.Add(15*time.Second))
	if s := p.State(); !s.AccountedThrough.Equal(t1.Add(15*time.Second)) || *s.LagRecords != 0 {
		t.Fatalf("caught up: %+v", s)
	}
	// A missing partition or a broker error proves nothing and clears lag.
	f.end = Offsets{"x_V": {0: 12}}
	if err := p.Tick(ctx, t1.Add(30*time.Second)); err == nil {
		t.Fatal("missing topic accepted")
	}
	if s := p.State(); !s.AccountedThrough.IsZero() || s.LagRecords != nil || s.Err == nil {
		t.Fatalf("missing partition: %+v", s)
	}
	f.endErr = errors.New("broker down")
	_ = p.Tick(ctx, t1.Add(45*time.Second))
	if s := p.State(); !s.AccountedThrough.IsZero() {
		t.Fatalf("broker failure did not fail closed: %+v", s)
	}
}

func TestProgressRejectsRetainedSuffixWithoutHistory(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	f := &fakeOffsets{
		start: Offsets{"x_V": {0: 100}}, end: Offsets{"x_V": {0: 110}},
		committed: Offsets{"x_V": {0: 110}}, ids: map[string]string{"x_V": "generation-1"},
	}
	h := &fakeCheckpoints{receiptsOK: false}
	p := &Progress{Reader: f, Checkpoints: h, Topics: []string{"x_V"}}
	if err := p.Tick(context.Background(), now); err == nil {
		t.Fatal("retained suffix established complete billing history")
	}
	if s := p.State(); !s.AccountedThrough.IsZero() || s.LagRecords != nil {
		t.Fatalf("retained suffix did not fail closed: %+v", s)
	}
}

func TestProgressRestoresDurableHistoryAcrossRestart(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	f := &fakeOffsets{
		start: Offsets{"x_V": {0: 100}}, end: Offsets{"x_V": {0: 110}},
		committed: Offsets{"x_V": {0: 110}}, ids: map[string]string{"x_V": "generation-1"},
	}
	h := &fakeCheckpoints{saved: store.QueueCheckpoints{"x_V": {0: {TopicID: "generation-1", NextOffset: 100}}}}
	p := &Progress{Reader: f, Checkpoints: h, Topics: []string{"x_V"}}
	if err := p.Tick(context.Background(), now); err != nil {
		t.Fatal(err)
	}
	if s := p.State(); !s.AccountedThrough.Equal(now) || s.LagRecords == nil || *s.LagRecords != 0 {
		t.Fatalf("durable restart history not restored: %+v", s)
	}
	if got := h.saved["x_V"][0].NextOffset; got != 110 {
		t.Fatalf("checkpoint = %d, want 110", got)
	}
}

func TestProgressRejectsTopicResetAndRetentionPastCheckpoint(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	base := &fakeOffsets{
		start: Offsets{"x_V": {0: 100}}, end: Offsets{"x_V": {0: 110}},
		committed: Offsets{"x_V": {0: 110}}, ids: map[string]string{"x_V": "generation-2"},
	}
	h := &fakeCheckpoints{saved: store.QueueCheckpoints{"x_V": {0: {TopicID: "generation-1", NextOffset: 100}}}}
	p := &Progress{Reader: base, Checkpoints: h, Topics: []string{"x_V"}}
	if err := p.Tick(context.Background(), now); err == nil {
		t.Fatal("replacement topic accepted as historical continuation")
	}

	base.ids["x_V"] = "generation-1"
	base.start["x_V"][0] = 101
	if err := p.Tick(context.Background(), now.Add(time.Second)); err == nil {
		t.Fatal("retention past durable checkpoint accepted")
	}
}
