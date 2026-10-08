package meter

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/georgenijo/volta/ingestion/internal/testvin"
)

type counter struct {
	u   Usage
	err error
}

func (c counter) MonthUsage(context.Context, time.Time) (Usage, error) { return c.u, c.err }

var now = time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)

// healthy is full coverage at now.
var healthy = Coverage{AccountedThrough: now.Add(-20 * time.Second), ReceiverSeenAt: now.Add(-10 * time.Second)}

func newMeter() *Meter { return &Meter{ReservationUSD: 3, WarnRatio: 0.6, StopRatio: 0.8} }

func TestStatesWithFullCoverage(t *testing.T) {
	m := newMeter()
	cases := map[int64]string{0: StateOK, 269_999: StateOK, 270_000: StateWarn, 359_999: StateWarn, 360_000: StateStop, 1_000_000: StateStop}
	for n, want := range cases {
		s := m.Evaluate(Usage{Signals: n}, healthy, now)
		if s.State != want || s.Confidence != ConfidenceComplete || len(s.Reasons) != 0 {
			t.Errorf("%d signals: %+v want %s", n, s, want)
		}
	}
}

func TestUnknownUnlessProven(t *testing.T) {
	m := newMeter()
	cases := []struct {
		name   string
		u      Usage
		cov    Coverage
		reason string
	}{
		{"never_accounted", Usage{}, Coverage{ReceiverSeenAt: now}, ReasonAccountingUnproven},
		{"stalled", Usage{}, Coverage{AccountedThrough: now.Add(-3 * time.Minute), ReceiverSeenAt: now}, ReasonAccountingStale},
		{"retrying", Usage{}, Coverage{AccountedThrough: now, ReceiverSeenAt: now, Retrying: true}, ReasonStoreRetrying},
		{"uncountable", Usage{Signals: 10, Uncountable: 1}, healthy, ReasonUncountable},
		{"undated", Usage{Signals: 10, Undated: 1}, healthy, ReasonUndated},
		{"receiver_never_seen", Usage{}, Coverage{AccountedThrough: now}, ReasonReceiverUnobserved},
		{"receiver_stale", Usage{}, Coverage{AccountedThrough: now, ReceiverSeenAt: now.Add(-2 * time.Minute)}, ReasonReceiverUnobserved},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := m.Evaluate(c.u, c.cov, now)
			if s.State != StateUnknown || s.Confidence != ConfidenceLowerBound || !slices.Contains(s.Reasons, c.reason) {
				t.Fatalf("%+v", s)
			}
		})
	}
	// A lower bound already past stop is a stop.
	if s := m.Evaluate(Usage{Signals: 400_000, Uncountable: 1}, Coverage{}, now); s.State != StateStop || s.Confidence != ConfidenceLowerBound {
		t.Fatalf("lower bound past stop: %+v", s)
	}
}

func TestStartupStoreErrorAndStaleCache(t *testing.T) {
	m := newMeter()
	if s := m.Last(now); s.State != StateUnknown || !slices.Contains(s.Reasons, ReasonStarting) {
		t.Fatalf("startup: %+v", s)
	}
	m.Counter = counter{err: errors.New("db down")}
	if s := m.Refresh(context.Background(), healthy, now); s.State != StateUnknown || !slices.Contains(s.Reasons, ReasonStoreError) {
		t.Fatalf("db error: %+v", s)
	}
	m.Counter = counter{u: Usage{Signals: 1}}
	if s := m.Refresh(context.Background(), healthy, now); s.State != StateOK {
		t.Fatalf("healthy: %+v", s)
	}
	if s := m.Last(now.Add(3 * time.Minute)); s.State != StateUnknown || !slices.Contains(s.Reasons, ReasonMeterStale) {
		t.Fatalf("stale cache: %+v", s)
	}
}

func TestMonthRolloverNeverReturnsPreviousSpend(t *testing.T) {
	m := newMeter()
	old := time.Date(2026, 10, 31, 23, 59, 59, 0, time.UTC)
	m.Counter = counter{u: Usage{Signals: 400_000}}
	m.Refresh(context.Background(), Coverage{AccountedThrough: old, ReceiverSeenAt: old}, old)
	next := old.Add(time.Second)
	s := m.Last(next)
	if s.Month != "2026-11" || s.State != StateUnknown || s.Signals != 0 || s.USD != 0 || !slices.Contains(s.Reasons, ReasonStarting) {
		t.Fatalf("rollover: %+v", s)
	}
	m.Counter = counter{u: Usage{Signals: 1}}
	m.Refresh(context.Background(), Coverage{AccountedThrough: next, ReceiverSeenAt: next}, next)
	if s = m.Last(next); s.State != StateOK || s.Signals != 1 {
		t.Fatalf("refreshed: %+v", s)
	}
}

func TestHandler(t *testing.T) {
	m := newMeter()
	at := time.Now().UTC()
	m.Counter = counter{u: Usage{Signals: 300_000}}
	m.Refresh(context.Background(), Coverage{AccountedThrough: at, ReceiverSeenAt: at}, at)
	h := m.Handler([]byte("s3cret"))

	do := func(method, path, auth string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, nil)
		if auth != "" {
			r.Header.Set("Authorization", auth)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	if w := do("GET", "/v1/usage", ""); w.Code != http.StatusUnauthorized || w.Body.Len() != 0 {
		t.Fatalf("no auth: %d %q", w.Code, w.Body.String())
	}
	if w := do("GET", "/v1/usage", "Bearer wrong"); w.Code != http.StatusUnauthorized {
		t.Fatalf("bad auth: %d", w.Code)
	}
	if w := do("POST", "/v1/usage", "Bearer s3cret"); w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("post: %d", w.Code)
	}
	if w := do("GET", "/v1/other", "Bearer s3cret"); w.Code != http.StatusNotFound {
		t.Fatalf("other path: %d", w.Code)
	}
	w := do("GET", "/v1/usage", "Bearer s3cret")
	if w.Code != 200 {
		t.Fatalf("ok: %d", w.Code)
	}
	var s Status
	if err := json.Unmarshal(w.Body.Bytes(), &s); err != nil {
		t.Fatal(err)
	}
	if s.State != StateWarn || s.Signals != 300_000 || s.USD != 2 || s.Confidence != ConfidenceComplete || s.AccountedThrough == nil {
		t.Fatalf("status %+v", s)
	}
	for _, k := range []string{`"accountedThrough":`, `"checkedAt":`, `"confidence":`, `"reasons":[]`} {
		if !strings.Contains(w.Body.String(), k) {
			t.Fatalf("missing %s: %s", k, w.Body.String())
		}
	}
	if strings.Contains(w.Body.String(), testvin.A[:11]) {
		t.Fatal("usage leaks a VIN")
	}
	// Empty configured secret never authorizes.
	h2 := m.Handler(nil)
	r := httptest.NewRequest("GET", "/v1/usage", nil)
	r.Header.Set("Authorization", "Bearer ")
	w2 := httptest.NewRecorder()
	h2.ServeHTTP(w2, r)
	if w2.Code != http.StatusUnauthorized {
		t.Fatalf("empty secret: %d", w2.Code)
	}
}
