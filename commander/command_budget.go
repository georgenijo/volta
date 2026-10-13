package commander

import (
	"context"
	"errors"
	"time"
)

// Commands, wakes, and wake-state reads share the existing Fleet API budget.
// Reserve each top-level request before sending, including rejected and
// uncertain replies. Same-key receipt replays never reach this path.
func (s *Service) reserveCommandCall(ctx context.Context, cost float64) *Result {
	if s.c.Mode != "live" {
		return nil
	}
	var meterUSD float64
	if s.telemetry != nil {
		m, err := s.telemetry.meter(ctx)
		if err != nil || m.Confidence != "complete" {
			r := failure(503, "command_budget_unavailable", "Vehicle controls are paused while usage accounting is unavailable.")
			return &r
		}
		meterUSD = m.USD
	}
	// The collector saves a read/modify/write usage snapshot, so join its lock
	// as well as the store transaction to preserve concurrent reservations.
	for !s.collector.mu.TryLock() {
		timer := time.NewTimer(10 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			r := failure(503, "command_not_sent", "Command deadline elapsed before sending; try again later.")
			return &r
		case <-timer.C:
		}
	}
	defer s.collector.mu.Unlock()
	if ctx.Err() != nil {
		r := failure(503, "command_not_sent", "Command deadline elapsed before sending; try again later.")
		return &r
	}
	now := time.Now()
	err := s.store.updateChecked(func(d *diskState) error {
		u := Usage{Month: month(now)}
		if d.Usage != nil && d.Usage.Month == u.Month {
			u = *d.Usage
		}
		safetyUSD := 0.0
		if d.Safety != nil && d.Safety.Month == u.Month {
			safetyUSD = d.Safety.USD
		}
		if max(0, u.USD-safetyUSD)+cost > s.c.MonthlyBudgetUSD+1e-9 {
			return errFleetBudget
		}
		if s.telemetry != nil && meterUSD+u.USD+cost > s.c.TotalMonthlyCapUSD-s.c.TelemetryDeleteReserveUSD+1e-9 {
			return errFleetBudget
		}
		u.Calls++
		u.USD += cost
		d.Usage = &u
		return nil
	})
	if err != nil {
		r := failure(503, "storage_unavailable", "Cannot safely reserve command usage; nothing was sent.")
		if errors.Is(err, errFleetBudget) {
			r = failure(429, "command_budget_exhausted", "The monthly vehicle controls budget is used up.")
		}
		return &r
	}
	return nil
}

// These errors arise before the next physical-command request. Earlier steps
// can only have been an explicit asleep rejection, wake, or status read.
func commandReservationRefused(code string) bool {
	switch code {
	case "command_budget_unavailable", "command_budget_exhausted", "storage_unavailable", "command_not_sent":
		return true
	default:
		return false
	}
}
