// Package meter turns the billing receipts into a budget state that
// commander (the only component holding Tesla credentials) acts on: add
// telemetry spend to its shared ledger and, at the stop threshold, delete
// the vehicle's fleet_telemetry_config before Tesla's billing cap would
// remove every configuration and suspend polling too.
//
// Contract with commander: commander MUST stop streaming immediately on "stop".
// For "unknown" or an unavailable endpoint, only a bounded, conservative
// burn projection from durable last-complete accounting permits grace;
// otherwise commander deletes. Recovery never clears budget/operator stops.
// "unknown" means
// the meter cannot prove the count is complete, so the real spend may
// already be past the stop threshold.
//
// The count is conservative: every datum of every record handed off
// durably to the queue is counted at handoff, accepted or rejected, for
// any VIN, before validation. It is complete only through
// AccountedThrough; the state is "unknown" whenever that is not recent, the
// receiver is not observed alive, a batch is not stored, any record could
// not be counted or dated, or the store cannot be read. It starts
// "unknown" and never reports "ok" before the first complete accounting.
//
// The endpoint is private (internal Docker network, bearer secret) and
// returns aggregate numbers only: no VIN, no location, no values.
package meter

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"math"
	"net/http"
	"strings"
	"sync"
	"time"
)

// SignalsPerUSD mirrors fleetconfig.SignalsPerUSD.
const SignalsPerUSD = 150000

// Usage is the billable receipt total for one UTC month.
type Usage struct {
	Signals     int64
	Uncountable int64 // records whose signals could not be counted
	Undated     int64 // records with no receiver or broker time
}

// Counter is the store query the meter needs.
type Counter interface {
	MonthUsage(ctx context.Context, now time.Time) (Usage, error)
}

// CounterFunc adapts a function to Counter.
type CounterFunc func(ctx context.Context, now time.Time) (Usage, error)

// MonthUsage implements Counter.
func (f CounterFunc) MonthUsage(ctx context.Context, now time.Time) (Usage, error) {
	return f(ctx, now)
}

// Coverage is what the consumer can prove about the handoff.
type Coverage struct {
	// AccountedThrough: every record the queue held at this time has its
	// receipt stored. Zero until proven once.
	AccountedThrough time.Time
	// Retrying is true while a polled batch is not yet stored.
	Retrying bool
	// ReceiverSeenAt is the last time the receiver was observed alive.
	ReceiverSeenAt time.Time
}

// States. Unknown permits only commander's bounded projected-spend grace.
const (
	StateOK      = "ok"
	StateWarn    = "warn"
	StateStop    = "stop"
	StateUnknown = "unknown"
)

// Confidence of the signal count.
const (
	// ConfidenceComplete: the count covers every record through
	// AccountedThrough, which is recent.
	ConfidenceComplete = "complete"
	// ConfidenceLowerBound: the real count may be higher; see Reasons.
	ConfidenceLowerBound = "lower_bound"
)

// Reasons the state is unknown.
const (
	ReasonStarting           = "starting"
	ReasonAccountingUnproven = "accounting_not_proven"
	ReasonAccountingStale    = "accounting_stale"
	ReasonStoreRetrying      = "store_retrying"
	ReasonUncountable        = "uncountable_records"
	ReasonUndated            = "undated_records"
	ReasonReceiverUnobserved = "receiver_unobserved"
	ReasonStoreError         = "store_error"
	ReasonMeterStale         = "meter_stale"
)

// Status is the public (to commander) usage view.
type Status struct {
	Month              string  `json:"month"`
	Signals            int64   `json:"signals"`
	UncountableRecords int64   `json:"uncountableRecords"`
	UndatedRecords     int64   `json:"undatedRecords"`
	USD                float64 `json:"usd"`
	ReservationUSD     float64 `json:"reservationUsd"`
	WarnUSD            float64 `json:"warnUsd"`
	StopUSD            float64 `json:"stopUsd"`
	State              string  `json:"state"`
	Confidence         string  `json:"confidence"`
	// AccountedThrough is the time the count is complete through (null
	// when never proven). CheckedAt is when the meter evaluated; the two
	// are deliberately separate.
	AccountedThrough *time.Time `json:"accountedThrough"`
	CheckedAt        time.Time  `json:"checkedAt"`
	Reasons          []string   `json:"reasons"`
}

// Meter caches the latest status.
type Meter struct {
	Counter        Counter
	ReservationUSD float64
	WarnRatio      float64
	StopRatio      float64
	// MaxAccountingAge bounds how old AccountedThrough and the cached
	// status may be. MaxReceiverAge bounds the receiver observation.
	MaxAccountingAge time.Duration
	MaxReceiverAge   time.Duration

	mu   sync.RWMutex
	last *Status
}

// Default freshness bounds.
const (
	DefaultMaxAccountingAge = 2 * time.Minute
	DefaultMaxReceiverAge   = 90 * time.Second
)

func (m *Meter) base(now time.Time) Status {
	return Status{
		Month:          now.UTC().Format("2006-01"),
		ReservationUSD: m.ReservationUSD,
		WarnUSD:        round6(m.ReservationUSD * m.WarnRatio),
		StopUSD:        round6(m.ReservationUSD * m.StopRatio),
		State:          StateUnknown,
		Confidence:     ConfidenceLowerBound,
		CheckedAt:      now.UTC(),
		Reasons:        []string{},
	}
}

// Evaluate classifies a usage total under the given coverage.
func (m *Meter) Evaluate(u Usage, cov Coverage, now time.Time) Status {
	s := m.base(now)
	s.Signals, s.UncountableRecords, s.UndatedRecords = u.Signals, u.Uncountable, u.Undated
	usd := float64(u.Signals) / SignalsPerUSD
	s.USD = math.Round(usd*10000) / 10000
	if !cov.AccountedThrough.IsZero() {
		at := cov.AccountedThrough.UTC()
		s.AccountedThrough = &at
	}
	maxAcct, maxRecv := m.MaxAccountingAge, m.MaxReceiverAge
	if maxAcct <= 0 {
		maxAcct = DefaultMaxAccountingAge
	}
	if maxRecv <= 0 {
		maxRecv = DefaultMaxReceiverAge
	}
	switch {
	case cov.AccountedThrough.IsZero():
		s.Reasons = append(s.Reasons, ReasonAccountingUnproven)
	case now.Sub(cov.AccountedThrough) > maxAcct:
		s.Reasons = append(s.Reasons, ReasonAccountingStale)
	}
	if cov.Retrying {
		s.Reasons = append(s.Reasons, ReasonStoreRetrying)
	}
	if u.Uncountable > 0 {
		s.Reasons = append(s.Reasons, ReasonUncountable)
	}
	if u.Undated > 0 {
		s.Reasons = append(s.Reasons, ReasonUndated)
	}
	if cov.ReceiverSeenAt.IsZero() || now.Sub(cov.ReceiverSeenAt) > maxRecv {
		s.Reasons = append(s.Reasons, ReasonReceiverUnobserved)
	}
	if len(s.Reasons) == 0 {
		s.Confidence = ConfidenceComplete
	}
	switch {
	case usd >= s.StopUSD:
		// A lower bound past the stop threshold is still a stop.
		s.State = StateStop
	case len(s.Reasons) > 0:
		s.State = StateUnknown
	case usd >= s.WarnUSD:
		s.State = StateWarn
	default:
		s.State = StateOK
	}
	return s
}

// round6 removes float noise (3 * 0.8 = 2.4000000000000004) so a threshold
// is reached exactly at its signal count.
func round6(v float64) float64 { return math.Round(v*1e6) / 1e6 }

// Refresh queries the store and caches the status. A store error makes the
// state unknown (commander applies its bounded grace).
func (m *Meter) Refresh(ctx context.Context, cov Coverage, now time.Time) Status {
	u, err := m.Counter.MonthUsage(ctx, now)
	var s Status
	if err != nil {
		s = m.base(now)
		s.Reasons = append(s.Reasons, ReasonStoreError)
	} else {
		s = m.Evaluate(u, cov, now)
	}
	m.mu.Lock()
	m.last = &s
	m.mu.Unlock()
	return s
}

// Last returns the cached status as of now: unknown before the first
// refresh, and unknown when the cached status is older than
// MaxAccountingAge (the refresh loop has stalled).
func (m *Meter) Last(now time.Time) Status {
	m.mu.RLock()
	last := m.last
	m.mu.RUnlock()
	if last == nil || last.Month != now.UTC().Format("2006-01") {
		s := m.base(now)
		s.Reasons = append(s.Reasons, ReasonStarting)
		return s
	}
	s := *last
	s.Reasons = append([]string{}, last.Reasons...)
	maxAge := m.MaxAccountingAge
	if maxAge <= 0 {
		maxAge = DefaultMaxAccountingAge
	}
	if now.Sub(s.CheckedAt) > maxAge {
		s.Reasons = append(s.Reasons, ReasonMeterStale)
		s.Confidence = ConfidenceLowerBound
		if s.State != StateStop {
			s.State = StateUnknown
		}
	}
	return s
}

// Handler serves GET /v1/usage with a bearer secret. Anything else is 404;
// a bad or missing secret is 401 with no body detail.
func (m *Meter) Handler(secret []byte) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/usage", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		got, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || len(secret) == 0 || subtle.ConstantTimeCompare([]byte(got), secret) != 1 {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(m.Last(time.Now()))
	})
	return mux
}
