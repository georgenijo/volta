package commander

import (
	"context"
	"crypto/x509"
	_ "embed"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"math"
	"net/http"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed telemetry_profiles.json
var telemetryProfilesJSON []byte

type telemetryFieldConfig struct {
	IntervalSeconds int      `json:"interval_seconds"`
	MinimumDelta    *float64 `json:"minimum_delta,omitempty"`
	IncludeFields   []string `json:"include_fields,omitempty"`
}

var telemetryProfiles = func() map[string]map[string]telemetryFieldConfig {
	var p map[string]map[string]telemetryFieldConfig
	if err := json.Unmarshal(telemetryProfilesJSON, &p); err != nil || len(p["normal"]) == 0 || len(p["economy"]) == 0 {
		panic("invalid embedded telemetry profiles")
	}
	return p
}()

type telemetryMeterStatus struct {
	Month              string     `json:"month"`
	Signals            int64      `json:"signals"`
	UncountableRecords int64      `json:"uncountableRecords"`
	UndatedRecords     int64      `json:"undatedRecords"`
	USD                float64    `json:"usd"`
	ReservationUSD     float64    `json:"reservationUsd"`
	WarnUSD            float64    `json:"warnUsd"`
	StopUSD            float64    `json:"stopUsd"`
	State              string     `json:"state"`
	Confidence         string     `json:"confidence"`
	AccountedThrough   *time.Time `json:"accountedThrough"`
	CheckedAt          time.Time  `json:"checkedAt"`
	Reasons            []string   `json:"reasons"`
}

type TelemetryController struct {
	service *Service
	client  *http.Client
	mu      sync.Mutex
	now     func() time.Time
}

func NewTelemetryController(s *Service, client *http.Client) *TelemetryController {
	return &TelemetryController{service: s, client: client, now: time.Now}
}

func (s *Service) TelemetryEnabled() bool           { return s.telemetry != nil }
func (s *Service) RunTelemetry(ctx context.Context) { s.telemetry.Run(ctx) }

// Run begins with the durable managed state. It never assumes that an empty
// process-local cache means no config exists on the car.
func (t *TelemetryController) Run(ctx context.Context) {
	t.reconcile(ctx)
	every := t.service.c.TelemetryRefresh
	if every <= 0 {
		every = 15 * time.Second
	}
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			t.reconcile(ctx)
		}
	}
}

func (t *TelemetryController) meter(ctx context.Context) (telemetryMeterStatus, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, t.service.c.TelemetryMeterURL, nil)
	if err != nil {
		return telemetryMeterStatus{}, err
	}
	req.Header.Set("Authorization", "Bearer "+t.service.c.TelemetryMeterSecret)
	res, err := t.client.Do(req)
	if err != nil {
		return telemetryMeterStatus{}, errors.New("meter_unreachable")
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(res.Body, 4096))
		return telemetryMeterStatus{}, errors.New("meter_unavailable")
	}
	var m telemetryMeterStatus
	dec := json.NewDecoder(io.LimitReader(res.Body, 64<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&m); err != nil {
		return telemetryMeterStatus{}, errors.New("meter_invalid")
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		return telemetryMeterStatus{}, errors.New("meter_invalid")
	}
	now := t.now().UTC()
	if m.Month != month(now) && m.Month == month(now.AddDate(0, 0, -1)) && now.Sub(monthStart(now)) < telemetryUnknownGrace {
		return m, errors.New("meter_month_starting")
	}
	maxAge := t.service.c.TelemetryMaxAge
	if maxAge <= 0 {
		maxAge = 2 * time.Minute
	}
	expectedUSD := float64(m.Signals) / 150000
	// The meter rounds USD to four decimal places; allow that rounding only.
	usdUnderstated := m.USD+0.000051 < expectedUSD
	if m.Month != month(now) || m.Signals < 0 || m.UncountableRecords < 0 || m.UndatedRecords < 0 || math.IsNaN(m.USD) || math.IsInf(m.USD, 0) || m.USD < 0 || usdUnderstated || m.CheckedAt.IsZero() || m.AccountedThrough == nil || m.AccountedThrough.IsZero() || now.Sub(m.CheckedAt) > maxAge || now.Sub(*m.AccountedThrough) > maxAge || m.CheckedAt.After(now.Add(30*time.Second)) || m.AccountedThrough.After(now.Add(30*time.Second)) {
		return m, errors.New("meter_stale_or_wrong_month")
	}
	badConfidence := m.Confidence != "complete" && m.Confidence != "lower_bound"
	badReasons := (m.Confidence == "complete" && len(m.Reasons) != 0) || (m.Confidence == "lower_bound" && len(m.Reasons) == 0)
	badCompleteCounts := m.Confidence == "complete" && (m.UncountableRecords != 0 || m.UndatedRecords != 0)
	if (m.State != "ok" && m.State != "warn" && m.State != "stop") || (m.State != "stop" && m.Confidence != "complete") || badConfidence || badReasons || badCompleteCounts {
		return m, errors.New("meter_unknown")
	}
	return m, nil
}

// The bound exceeds a full snapshot of every configured field per second.
// It is an operating assumption, not a guarantee against arbitrary upstream
// replay; Tesla portal limits remain an independent deployment gate.
const telemetryWorstSignalsPerSecond = 1000.0
const telemetryUnknownGrace = 5 * time.Minute
const telemetryProjectionMargin = 30 * time.Second
const telemetryResumeHealthyWindow = 10 * time.Minute
const telemetryMaxAutoResumes = 3

func telemetryMayExist(state TelemetryManaged) bool {
	return state.ConfigMayExist || state.Profile == "normal" || state.Profile == "economy" || state.PendingAction != ""
}

func telemetryResumeRetry(attempts int) time.Duration {
	return min(telemetryResumeHealthyWindow*time.Duration(1<<min(max(attempts-1, 0), 12)), 6*time.Hour)
}

func (t *TelemetryController) trackRecovery(state TelemetryManaged, healthy bool) TelemetryManaged {
	now := t.now().UTC()
	maxAge := t.service.c.TelemetryMaxAge
	if maxAge <= 0 {
		maxAge = 2 * time.Minute
	}
	if !healthy {
		state.HealthySince, state.LastHealthyCheck = time.Time{}, time.Time{}
		return state
	}
	if state.AutoResumeMonth != month(now) {
		state.AutoResumeMonth, state.AutoResumeAttempts = month(now), 0
	}
	if state.HealthySince.IsZero() || now.Sub(state.LastHealthyCheck) > maxAge || now.Before(state.LastHealthyCheck) {
		state.HealthySince = now
	}
	state.LastHealthyCheck = now
	return state
}

func monthStart(now time.Time) time.Time {
	now = now.UTC()
	return time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
}

func (t *TelemetryController) unknownGrace(id string, state TelemetryManaged, reason string, m telemetryMeterStatus, usageUSD float64) bool {
	now := t.now().UTC()
	if state.UnknownSince.IsZero() {
		state.UnknownSince = now
	}
	baseline, through := state.LastKnownUSD, state.LastKnownThrough
	if state.LastKnownMonth != month(now) {
		if state.LastKnownMonth != month(now.AddDate(0, 0, -1)) || now.Sub(monthStart(now)) >= telemetryUnknownGrace {
			return false
		}
		baseline, through = 0, monthStart(now)
	}
	if through.IsZero() || through.After(now) || now.Sub(state.UnknownSince) >= telemetryUnknownGrace {
		return false
	}
	// Even incomplete/stale current-month receipts are a lower bound. Never
	// grant grace against a lower known total than the latest observation.
	if m.Month == month(now) && !math.IsNaN(m.USD) && !math.IsInf(m.USD, 0) {
		baseline = max(baseline, m.USD, float64(max(0, m.Signals))/150000)
	}
	elapsed := now.Sub(through) + telemetryProjectionMargin
	projected := baseline + telemetryWorstSignalsPerSecond*float64(len(t.service.c.Vehicles))*elapsed.Seconds()/150000
	if projected >= t.service.c.TelemetryStopUSD || projected+usageUSD >= t.service.c.TotalMonthlyCapUSD-t.service.c.TelemetryDeleteReserveUSD {
		return false
	}
	state.LastMeter, state.LastError, state.LastChecked = reason, reason, now
	return t.service.store.update(func(d *diskState) { d.Telemetry[id] = state }) == nil
}

func (t *TelemetryController) reconcile(ctx context.Context) {
	t.mu.Lock()
	defer t.mu.Unlock()
	states := t.service.store.snapshot().Telemetry
	if len(states) == 0 {
		return
	}
	meter, meterErr := t.meter(ctx)
	usage := t.service.usage(t.now())
	combinedStopped := meterErr == nil && meter.USD+usage.USD >= t.service.c.TotalMonthlyCapUSD-t.service.c.TelemetryDeleteReserveUSD
	// A current-month lower bound past budget proves a budget stop even when
	// freshness/completeness validation fails. It must never become resumable.
	lowerUSD := max(meter.USD, float64(max(0, meter.Signals))/150000)
	observedBudgetStop := meter.Month == month(t.now()) && !math.IsNaN(lowerUSD) && !math.IsInf(lowerUSD, 0) &&
		(lowerUSD >= t.service.c.TelemetryStopUSD || lowerUSD+usage.USD >= t.service.c.TotalMonthlyCapUSD-t.service.c.TelemetryDeleteReserveUSD)
	for id, state := range states {
		if !state.Managed {
			continue
		}
		if state.Profile == "stopped" && state.PendingAction == "" {
			prior := state
			healthy := meterErr == nil && meter.Confidence == "complete" && meter.State == "ok" && meter.USD < t.service.c.TelemetryWarnUSD && !combinedStopped
			state = t.trackRecovery(state, healthy)
			// Complete receipts save recovery and meter state together below.
			// On an outage, persist only the transition that clears the window.
			if meterErr != nil && state != prior {
				if t.service.store.update(func(d *diskState) { d.Telemetry[id] = state }) != nil {
					continue
				}
			}
		}
		if state.PendingAction == "delete" && t.now().Before(state.NextRetry) {
			continue
		}
		if state.PendingAction != "" {
			reason := state.StopReason
			if reason == "" {
				reason = "config_outcome_unknown"
			}
			if strings.HasPrefix(reason, "meter_") && (observedBudgetStop || (meterErr == nil && meter.State == "stop")) {
				reason = "budget_stop"
			}
			t.stopManaged(ctx, id, state, reason, meter, meterErr == nil)
			continue
		}
		if state.Profile == "stopped" {
			if strings.HasPrefix(state.StopReason, "meter_") && observedBudgetStop {
				state.StopReason = "budget_stop"
				_ = t.service.store.update(func(d *diskState) { d.Telemetry[id] = state })
			}
			if meterErr == nil {
				if strings.HasPrefix(state.StopReason, "meter_") && (meter.State == "stop" || meter.USD >= t.service.c.TelemetryStopUSD || combinedStopped) {
					state.StopReason = "budget_stop"
				}
				state = t.recordMeter(id, state, meter)
				if state.StopLatched && strings.HasPrefix(state.StopReason, "meter_") && !state.HealthySince.IsZero() &&
					t.now().Sub(state.HealthySince) >= telemetryResumeHealthyWindow &&
					meter.AccountedThrough.Sub(state.HealthySince) >= telemetryResumeHealthyWindow && !t.now().Before(state.NextResume) {
					if state.AutoResumeAttempts >= telemetryMaxAutoResumes {
						state.StopReason, state.LastError = "auto_resume_limit", "telemetry_auto_resume_limit"
						_ = t.service.store.update(func(d *diskState) { d.Telemetry[id] = state })
						continue
					}
					if result := t.createHeadroom(id); result != nil {
						state.StopReason, state.LastError = "delete_reserve_stop", result.Error.Code
						_ = t.service.store.update(func(d *diskState) { d.Telemetry[id] = state })
						continue
					}
					// Count before paid preflight; success, operator creates and DELETE
					// never reset the month's automatic recovery history/cooldown.
					state.AutoResumeAttempts++
					state.NextResume = t.now().UTC().Add(telemetryResumeRetry(state.AutoResumeAttempts))
					state.LastError = "telemetry_resume_pending"
					if t.service.store.update(func(d *diskState) { d.Telemetry[id] = state }) != nil {
						continue
					}
					result := t.preflight(ctx, id, meter.USD)
					if result == nil {
						result = t.applyProfile(ctx, id, state, "normal", meter)
					}
					if result != nil {
						t.resumeFailed(id, result)
					}
				}
			}
			continue
		}
		if meterErr != nil {
			if t.unknownGrace(id, state, meterErr.Error(), meter, usage.USD) {
				continue
			}
			reason := meterErr.Error()
			if observedBudgetStop {
				reason = "budget_stop"
			}
			t.stopManaged(ctx, id, state, reason, meter, false)
			continue
		}
		if meter.State == "stop" || meter.USD >= t.service.c.TelemetryStopUSD || combinedStopped {
			reason := "budget_stop"
			if combinedStopped {
				reason = "shared_budget_stop"
			}
			t.stopManaged(ctx, id, state, reason, meter, true)
			continue
		}
		state = t.recordMeter(id, state, meter)
		if !state.StopLatched && state.Profile == "normal" && (meter.State == "warn" || meter.USD >= t.service.c.TelemetryWarnUSD) {
			t.applyProfile(ctx, id, state, "economy", meter)
		} else if !state.StopLatched && (state.Profile == "normal" || state.Profile == "economy") && !state.ConfigExpires.IsZero() && state.ConfigExpires.Before(t.now().UTC().Add(24*time.Hour)) {
			t.applyProfile(ctx, id, state, state.Profile, meter)
		}
	}
}

func (t *TelemetryController) resumeFailed(id string, result *Result) {
	// An attempted POST may already have created a pending delete. Never
	// replace its ownership/latch with the stale preflight state.
	_ = t.service.store.update(func(d *diskState) {
		state := d.Telemetry[id]
		if state.PendingAction != "" || !strings.HasPrefix(state.StopReason, "meter_") {
			return
		}
		state.LastError = result.Error.Code
		switch result.Error.Code {
		case "virtual_key_not_paired", "telemetry_client_too_old":
			state.StopReason = "resume_" + result.Error.Code // operator action required
		case "fleet_budget_stopped":
			state.StopReason = "budget_stop"
		case "telemetry_delete_reserve_insufficient":
			state.StopReason = "delete_reserve_stop"
		}
		d.Telemetry[id] = state
	})
}

func (t *TelemetryController) recordMeter(id string, state TelemetryManaged, m telemetryMeterStatus) TelemetryManaged {
	state.Month, state.LastMeter, state.LastChecked, state.MeterUSD = m.Month, m.State, t.now().UTC(), m.USD
	state.UnknownSince = time.Time{}
	if m.Confidence == "complete" {
		state.LastKnownMonth, state.LastKnownUSD, state.LastKnownThrough = m.Month, m.USD, *m.AccountedThrough
	}
	_ = t.service.store.update(func(d *diskState) { d.Telemetry[id] = state })
	return state
}

func (t *TelemetryController) stopManaged(ctx context.Context, id string, state TelemetryManaged, reason string, m telemetryMeterStatus, meterKnown bool) {
	mayExist := telemetryMayExist(state)
	state.ConfigMayExist = mayExist
	state.HealthySince, state.LastHealthyCheck = time.Time{}, time.Time{}
	state.Managed, state.Synced, state.StopLatched, state.PendingAction = true, false, true, ""
	if mayExist {
		state.PendingAction = "delete"
	}
	if strings.HasPrefix(reason, "meter_") && state.AutoResumeMonth == month(t.now()) && state.AutoResumeAttempts >= telemetryMaxAutoResumes {
		reason = "auto_resume_limit"
	}
	state.StopReason = reason
	state.Profile, state.LastMeter, state.LastError, state.LastChecked = "stopped", reason, reason, t.now().UTC()
	if m.Month != "" {
		state.Month, state.MeterUSD = m.Month, m.USD
	}
	if err := t.service.store.update(func(d *diskState) { d.Telemetry[id] = state }); err != nil {
		return
	}
	if !mayExist {
		return
	}
	var meterUSD *float64
	if meterKnown {
		meterUSD = &m.USD
	}
	deleteErr := t.deleteRemote(ctx, id, meterUSD)
	state = t.deletionAttempts(id, state)
	if err := deleteErr; err != nil {
		state.Failures++
		state.LastError = err.Error()
		state.NextRetry = t.now().UTC().Add(telemetryRetry(state.Failures))
		_ = t.service.store.update(func(d *diskState) { d.Telemetry[id] = state })
		return
	}
	state.ConfigMayExist, state.DeleteConfirmed = false, true
	state.PendingAction, state.LastError, state.Failures, state.LastAction, state.NextRetry = "", "", 0, t.now().UTC(), time.Time{}
	_ = t.service.store.update(func(d *diskState) { d.Telemetry[id] = state })
}

func telemetryRetry(failures int) time.Duration {
	if failures < 1 {
		failures = 1
	}
	shift := min(failures-1, 12)
	return min(15*time.Second*time.Duration(1<<shift), 6*time.Hour)
}

var errFleetBudget = errors.New("fleet_budget_stopped")
var errDeleteReserve = errors.New("telemetry_delete_reserve_exhausted")

var errDeleteHeadroom = errors.New("telemetry_delete_reserve_insufficient")

func (t *TelemetryController) deleteHeadroom(d diskState, now time.Time, id string) bool {
	spent := 0.0
	if d.Safety != nil && d.Safety.Month == month(now) {
		spent = d.Safety.USD
	}
	claims := 2 // target needs two fresh attempts for this POST
	for other, state := range d.Telemetry {
		if other != id && telemetryMayExist(state) {
			claims += telemetryUnusedDeletes(state, now)
		}
	}
	return spent+float64(claims)*t.service.c.CallCostUSD <= t.service.c.TelemetryDeleteReserveUSD+1e-9
}

// Every possibly-live config owns its two remaining attempts. Attempts are
// recorded with the paid reservation, including failed/crashed requests. A
// new POST intent starts a new config's claim; month rollover replenishes
// the monthly lane. This prevents both starvation and stranded final calls.
func telemetryUnusedDeletes(state TelemetryManaged, now time.Time) int {
	if state.DeleteAttemptsMonth != month(now) {
		return 2
	}
	return max(0, 2-state.DeleteAttempts)
}

func (t *TelemetryController) deletionAttempts(id string, state TelemetryManaged) TelemetryManaged {
	latest := t.service.store.snapshot().Telemetry[id]
	state.DeleteAttemptsMonth, state.DeleteAttempts = latest.DeleteAttemptsMonth, latest.DeleteAttempts
	return state
}

func (t *TelemetryController) createHeadroom(id string) *Result {
	if !t.deleteHeadroom(t.service.store.snapshot(), t.now(), id) {
		r := failure(429, errDeleteHeadroom.Error(), "Telemetry requires two DELETE attempts for this configuration and unused DELETE claims for other vehicles.")
		return &r
	}
	return nil
}

func (t *TelemetryController) reserveCalls(now time.Time, meterUSD *float64, safetyDelete bool, calls int) error {
	return t.reserveConfigCalls(now, meterUSD, safetyDelete, calls, "")
}

func (t *TelemetryController) reserveConfigCalls(now time.Time, meterUSD *float64, safetyDelete bool, calls int, id string) error {
	if calls < 1 {
		return errors.New("invalid reservation")
	}
	return t.service.store.updateChecked(func(d *diskState) error {
		if id != "" && !safetyDelete && !t.deleteHeadroom(*d, now, id) {
			return errDeleteHeadroom
		}
		u := Usage{Month: month(now)}
		if d.Usage != nil && d.Usage.Month == u.Month {
			u = *d.Usage
		}
		safety := SafetyUsage{Month: u.Month}
		if d.Safety != nil && d.Safety.Month == u.Month {
			safety = *d.Safety
		}
		cost := t.service.c.CallCostUSD * float64(calls)
		if safetyDelete {
			// Preserve each other config's own unused two-attempt claim.
			protected := 0.0
			if id != "" {
				for other, state := range d.Telemetry {
					if other != id && telemetryMayExist(state) {
						protected += float64(telemetryUnusedDeletes(state, now)) * t.service.c.CallCostUSD
					}
				}
			}
			if safety.USD+cost+protected > t.service.c.TelemetryDeleteReserveUSD+1e-9 {
				return errDeleteReserve
			}
			if id != "" {
				state := d.Telemetry[id]
				if state.DeleteAttemptsMonth != u.Month {
					state.DeleteAttemptsMonth, state.DeleteAttempts = u.Month, 0
				}
				state.DeleteAttempts += calls
				d.Telemetry[id] = state
			}
			safety.Calls += calls
			safety.USD += cost
			d.Safety = &safety
		} else {
			regularUSD := max(0, u.USD-safety.USD)
			operatingCap := t.service.c.TotalMonthlyCapUSD - t.service.c.TelemetryDeleteReserveUSD
			if meterUSD == nil || regularUSD+cost > t.service.c.MonthlyBudgetUSD+1e-9 || *meterUSD+u.USD+cost > operatingCap+1e-9 {
				return errFleetBudget
			}
		}
		u.Calls += calls
		u.USD += cost
		d.Usage = &u
		return nil
	})
}

func (t *TelemetryController) preflight(ctx context.Context, id string, meterUSD float64) *Result {
	vin, ok := t.service.c.Vehicles[id]
	if !ok {
		r := failure(404, "vehicle_not_found", "Vehicle is not configured in commander.")
		return &r
	}
	tokens, tokenResult := t.service.oauth.Token(ctx)
	if tokenResult != nil {
		r := failure(503, "oauth_unavailable", "Tesla authorization is unavailable.")
		return &r
	}
	if err := t.reserveCalls(t.now(), &meterUSD, false, 1); err != nil {
		code, status := "storage_unavailable", 503
		if errors.Is(err, errFleetBudget) {
			code, status = "fleet_budget_stopped", 429
		}
		r := failure(status, code, "The Fleet API budget has no room for another paid call.")
		return &r
	}
	status, reply, callErr := t.service.fleet.request(ctx, http.MethodPost, tokens.FleetBase+"/api/1/vehicles/fleet_status", tokens.Access, map[string]any{"vins": []string{vin}})
	if callErr != nil {
		return callErr
	}
	if status != http.StatusOK || reply.Error != "" {
		if mapped := mapFleetError(status, reply); mapped != nil {
			return mapped
		}
		r := failure(502, "fleet_status_unavailable", "Tesla fleet status is unavailable.")
		return &r
	}
	var response struct {
		KeyPaired []string `json:"key_paired_vins"`
		Info      map[string]struct {
			FleetTelemetryVersion string `json:"fleet_telemetry_version"`
		} `json:"vehicle_info"`
	}
	if json.Unmarshal(reply.Response, &response) != nil {
		r := failure(502, "fleet_status_invalid", "Tesla fleet status was not understood.")
		return &r
	}
	if !slices.Contains(response.KeyPaired, vin) {
		r := failure(409, "virtual_key_not_paired", "Pair Volta's virtual key in the Tesla app before enabling telemetry.")
		return &r
	}
	if !versionAtLeast(response.Info[vin].FleetTelemetryVersion, 1, 3, 0) {
		r := failure(409, "telemetry_client_too_old", "The vehicle requires Fleet Telemetry client 1.3.0 or newer for co-timed fields.")
		return &r
	}
	return nil
}

func versionAtLeast(value string, major, minor, patch int) bool {
	parts := strings.Split(value, ".")
	if len(parts) != 3 {
		return false
	}
	got := make([]int, 3)
	for i := range parts {
		v, err := strconv.Atoi(parts[i])
		if err != nil || v < 0 {
			return false
		}
		got[i] = v
	}
	want := []int{major, minor, patch}
	for i := range got {
		if got[i] != want[i] {
			return got[i] > want[i]
		}
	}
	return true
}

func (t *TelemetryController) caChain() (string, error) {
	b, err := os.ReadFile(t.service.c.TelemetryCAFile)
	if err != nil || len(b) == 0 || strings.Contains(string(b), "PRIVATE KEY") {
		return "", errors.New("telemetry_ca_unavailable")
	}
	rest, certs := b, 0
	for len(rest) > 0 {
		block, next := pem.Decode(rest)
		if block == nil {
			return "", errors.New("telemetry_ca_invalid")
		}
		if block.Type != "CERTIFICATE" {
			return "", errors.New("telemetry_ca_invalid")
		}
		if _, err := x509.ParseCertificate(block.Bytes); err != nil {
			return "", errors.New("telemetry_ca_invalid")
		}
		certs++
		rest = next
	}
	if certs == 0 {
		return "", errors.New("telemetry_ca_invalid")
	}
	return string(b), nil
}

func (t *TelemetryController) configBody(id, profile string) (map[string]any, error) {
	vin, ok := t.service.c.Vehicles[id]
	fields, profileOK := telemetryProfiles[profile]
	if !ok || !profileOK {
		return nil, errors.New("invalid telemetry target")
	}
	ca, err := t.caChain()
	if err != nil {
		return nil, err
	}
	return map[string]any{"vins": []string{vin}, "config": map[string]any{
		"hostname": t.service.c.TelemetryHostname, "port": t.service.c.TelemetryPort, "ca": ca,
		"fields": fields, "exp": t.now().UTC().Add(30 * 24 * time.Hour).Unix(), "delivery_policy": "latest",
	}}, nil
}

func (t *TelemetryController) applyProfile(ctx context.Context, id string, state TelemetryManaged, profile string, meter telemetryMeterStatus) *Result {
	body, err := t.configBody(id, profile)
	if err != nil {
		r := failure(503, err.Error(), "Telemetry configuration is unavailable.")
		return &r
	}
	tokens, tokenResult := t.service.oauth.Token(ctx)
	if tokenResult != nil {
		r := failure(503, "oauth_unavailable", "Tesla authorization is unavailable.")
		return &r
	}
	// Reserve the POST/receipt and check DELETE headroom before ownership is
	// changed. A refused first create cannot have installed a remote config.
	if err := t.reserveConfigCalls(t.now(), &meter.USD, false, 2, id); err != nil {
		code, status := "storage_unavailable", 503
		if errors.Is(err, errFleetBudget) {
			code, status = "fleet_budget_stopped", 429
		}
		if errors.Is(err, errDeleteHeadroom) {
			code, status = errDeleteHeadroom.Error(), 429
		}
		if status == 429 {
			reason := "budget_stop"
			if errors.Is(err, errDeleteHeadroom) {
				reason = "delete_reserve_stop"
			}
			// Keep live ownership for guarded deletion; no phantom DELETE for
			// a stopped/never-created config whose reservation was refused.
			state.ConfigMayExist = telemetryMayExist(state)
			state.Managed, state.Synced, state.Profile, state.StopLatched = true, false, "stopped", true
			state.StopReason, state.LastError = reason, code
			state.PendingAction = ""
			if state.ConfigMayExist {
				state.PendingAction = "delete"
			}
			_ = t.service.store.update(func(d *diskState) { d.Telemetry[id] = state })
		}
		r := failure(status, code, "The Fleet API budget or DELETE reserve cannot support configuration.")
		return &r
	}
	// Ownership is durable before POST, including an unknown/crashed outcome.
	state.DeleteAttemptsMonth, state.DeleteAttempts = month(t.now()), 0
	state.DeleteConfirmed = false
	state.Managed, state.Synced, state.StopLatched, state.ConfigMayExist = true, false, false, true
	state.StopReason, state.UnknownSince = "", time.Time{}
	state.HealthySince, state.LastHealthyCheck = time.Time{}, time.Time{}
	state.LastKnownMonth, state.LastKnownUSD, state.LastKnownThrough = meter.Month, meter.USD, *meter.AccountedThrough
	state.Profile, state.PendingAction, state.LastChecked, state.LastMeter, state.MeterUSD = "stopped", "create_"+profile, t.now().UTC(), meter.State, meter.USD
	if err := t.service.store.update(func(d *diskState) { d.Telemetry[id] = state }); err != nil {
		r := failure(503, "storage_unavailable", "Telemetry state could not be saved.")
		return &r
	}
	status, reply, callErr := t.service.fleet.request(ctx, http.MethodPost, t.service.c.ProxyURL+"/api/1/vehicles/fleet_telemetry_config", tokens.Access, body)
	if callErr != nil {
		t.failAction(id, state, callErr.Error.Code)
		return callErr
	}
	var response struct {
		Updated int                 `json:"updated_vehicles"`
		Skipped map[string][]string `json:"skipped_vehicles"`
	}
	if status < 200 || status >= 300 || reply.Error != "" || json.Unmarshal(reply.Response, &response) != nil || response.Updated != 1 {
		code := "telemetry_config_rejected"
		if len(response.Skipped["missing_key"]) > 0 {
			code = "virtual_key_not_paired"
		}
		t.failAction(id, state, code)
		r := failure(409, code, "Tesla did not apply the Fleet Telemetry configuration.")
		return &r
	}
	state.Profile, state.PendingAction, state.LastError, state.Failures, state.LastAction, state.NextRetry = profile, "", "", 0, t.now().UTC(), time.Time{}
	state.ConfigExpires = t.now().UTC().Add(30 * 24 * time.Hour)
	state.Managed, state.StopLatched, state.Month = true, false, month(t.now())
	synced, syncResult := t.remoteSync(ctx, id, &meter.USD, true)
	if syncResult != nil {
		t.failAction(id, state, syncResult.Error.Code)
		return syncResult
	}
	state.Synced = synced
	if err := t.service.store.update(func(d *diskState) { d.Telemetry[id] = state }); err != nil {
		r := failure(503, "storage_unavailable", "Telemetry was configured but local confirmation could not be saved; the guard will delete it.")
		return &r
	}
	return nil
}

func (t *TelemetryController) failAction(id string, state TelemetryManaged, code string) {
	state.Managed, state.Profile, state.PendingAction, state.StopLatched, state.Synced = true, "stopped", "delete", true, false
	state.StopReason = "config_" + code
	state.Failures++
	state.LastError = code
	state.NextRetry = t.now().UTC()
	_ = t.service.store.update(func(d *diskState) { d.Telemetry[id] = state })
}

func (t *TelemetryController) remoteSync(ctx context.Context, id string, meterUSD *float64, reserved bool) (bool, *Result) {
	vin, ok := t.service.c.Vehicles[id]
	if !ok {
		r := failure(404, "vehicle_not_found", "Vehicle is not configured in commander.")
		return false, &r
	}
	tokens, tokenResult := t.service.oauth.Token(ctx)
	if tokenResult != nil {
		return false, tokenResult
	}
	if !reserved {
		if err := t.reserveCalls(t.now(), meterUSD, false, 1); err != nil {
			code, status := "storage_unavailable", 503
			if errors.Is(err, errFleetBudget) {
				code, status = "fleet_budget_stopped", 429
			}
			r := failure(status, code, "The Fleet API budget has no room for another paid call.")
			return false, &r
		}
	}
	status, reply, callResult := t.service.fleet.request(ctx, http.MethodGet, tokens.FleetBase+"/api/1/vehicles/"+vin+"/fleet_telemetry_config", tokens.Access, nil)
	if callResult != nil {
		return false, callResult
	}
	if status != http.StatusOK || reply.Error != "" {
		r := failure(502, "telemetry_status_unavailable", "Tesla telemetry configuration status is unavailable.")
		return false, &r
	}
	var response struct {
		Synced    bool `json:"synced"`
		KeyPaired bool `json:"key_paired"`
	}
	if json.Unmarshal(reply.Response, &response) != nil {
		r := failure(502, "telemetry_status_invalid", "Tesla telemetry configuration status was not understood.")
		return false, &r
	}
	return response.Synced, nil
}

func (t *TelemetryController) deleteRemote(ctx context.Context, id string, meterUSD *float64) error {
	vin, ok := t.service.c.Vehicles[id]
	if !ok {
		return errors.New("vehicle_not_found")
	}
	tokens, err := t.service.oauth.Token(ctx)
	if err != nil {
		return errors.New("oauth_unavailable")
	}
	if err := t.reserveConfigCalls(t.now(), meterUSD, true, 1, id); err != nil {
		return err
	}
	status, reply, callErr := t.service.fleet.request(ctx, http.MethodDelete, t.service.c.ProxyURL+"/api/1/vehicles/"+vin+"/fleet_telemetry_config", tokens.Access, nil)
	if callErr != nil {
		return errors.New(callErr.Error.Code)
	}
	if status < 200 || status >= 300 || reply.Error != "" {
		return errors.New("telemetry_delete_failed")
	}
	return nil
}

func (s *Service) handleTelemetryStatus(w http.ResponseWriter, _ *http.Request) {
	if s.telemetry == nil {
		writeResult(w, failure(501, "telemetry_unavailable", "Fleet Telemetry control is disabled."))
		return
	}
	states := s.store.snapshot().Telemetry
	if states == nil {
		states = map[string]TelemetryManaged{}
	}
	writeJSON(w, 200, map[string]any{"enabled": true, "vehicles": states, "budget": map[string]float64{"warnUsd": s.c.TelemetryWarnUSD, "stopUsd": s.c.TelemetryStopUSD, "capUsd": s.c.TelemetryCapUSD, "pollingUsd": s.c.MonthlyBudgetUSD, "deleteReserveUsd": s.c.TelemetryDeleteReserveUSD, "operatingUsd": s.c.TotalMonthlyCapUSD - s.c.TelemetryDeleteReserveUSD, "totalUsd": s.c.TotalMonthlyCapUSD}})
}

func (s *Service) handleTelemetryCreate(w http.ResponseWriter, r *http.Request) {
	if s.telemetry == nil {
		writeResult(w, failure(501, "telemetry_unavailable", "Fleet Telemetry control is disabled."))
		return
	}
	if !telemetryBodyEmpty(r) {
		writeResult(w, failure(400, "invalid_params", "This endpoint accepts no request body."))
		return
	}
	s.telemetry.mu.Lock()
	defer s.telemetry.mu.Unlock()
	meter, err := s.telemetry.meter(r.Context())
	if err != nil {
		writeResult(w, failure(503, "telemetry_meter_unknown", "Telemetry accounting is incomplete or stale; streaming stays stopped."))
		return
	}
	if meter.State == "stop" || meter.USD >= s.c.TelemetryStopUSD {
		writeResult(w, failure(409, "telemetry_budget_stopped", "The monthly telemetry stop threshold has been reached."))
		return
	}
	id := r.PathValue("id")
	if result := s.telemetry.createHeadroom(id); result != nil {
		writeResult(w, *result)
		return
	}
	if preflight := s.telemetry.preflight(r.Context(), id, meter.USD); preflight != nil {
		writeResult(w, *preflight)
		return
	}
	profile := "normal"
	if meter.State == "warn" || meter.USD >= s.c.TelemetryWarnUSD {
		profile = "economy"
	}
	state := s.store.snapshot().Telemetry[id]
	if result := s.telemetry.applyProfile(r.Context(), id, state, profile, meter); result != nil {
		writeResult(w, *result)
		return
	}
	state = s.store.snapshot().Telemetry[id]
	status := http.StatusOK
	if !state.Synced {
		status = http.StatusAccepted
	}
	writeJSON(w, status, map[string]any{"ok": true, "profile": profile, "guard": "active", "synced": state.Synced})
}

func (s *Service) handleTelemetryRemoteStatus(w http.ResponseWriter, r *http.Request) {
	if s.telemetry == nil {
		writeResult(w, failure(501, "telemetry_unavailable", "Fleet Telemetry control is disabled."))
		return
	}
	if !telemetryBodyEmpty(r) {
		writeResult(w, failure(400, "invalid_params", "This endpoint accepts no request body."))
		return
	}
	s.telemetry.mu.Lock()
	defer s.telemetry.mu.Unlock()
	id := r.PathValue("id")
	meter, meterErr := s.telemetry.meter(r.Context())
	if meterErr != nil {
		writeResult(w, failure(503, "telemetry_meter_unknown", "Telemetry accounting is incomplete or stale; paid status reads are stopped."))
		return
	}
	synced, result := s.telemetry.remoteSync(r.Context(), id, &meter.USD, false)
	if result != nil {
		writeResult(w, *result)
		return
	}
	state := s.store.snapshot().Telemetry[id]
	state.Synced, state.LastChecked = synced, s.telemetry.now().UTC()
	if synced {
		state.ConfigMayExist, state.Managed, state.DeleteConfirmed = true, true, false
		// A confirmed external config cannot masquerade as an already stopped
		// car. Honor an existing operator/budget stop through durable deletion.
		if state.Profile == "stopped" && state.StopLatched && state.PendingAction == "" {
			state.PendingAction, state.NextRetry = "delete", s.telemetry.now().UTC()
		}
	}
	if err := s.store.update(func(d *diskState) { d.Telemetry[id] = state }); err != nil {
		writeResult(w, failure(503, "storage_unavailable", "Telemetry status could not be saved."))
		return
	}
	writeJSON(w, 200, map[string]any{"synced": synced, "profile": state.Profile, "guard": map[bool]string{true: "active", false: "pending"}[synced]})
}

func (s *Service) handleTelemetryDelete(w http.ResponseWriter, r *http.Request) {
	if s.telemetry == nil {
		writeResult(w, failure(501, "telemetry_unavailable", "Fleet Telemetry control is disabled."))
		return
	}
	if !telemetryBodyEmpty(r) {
		writeResult(w, failure(400, "invalid_params", "This endpoint accepts no request body."))
		return
	}
	s.telemetry.mu.Lock()
	defer s.telemetry.mu.Unlock()
	id, now := r.PathValue("id"), s.telemetry.now().UTC()
	if _, ok := s.c.Vehicles[id]; !ok {
		writeResult(w, failure(404, "vehicle_not_found", "Vehicle is not configured in commander."))
		return
	}
	state := s.store.snapshot().Telemetry[id]
	mayExist := telemetryMayExist(state)
	state.ConfigMayExist = mayExist
	state.HealthySince, state.LastHealthyCheck = time.Time{}, time.Time{}
	state.StopReason = "operator_stop"
	state.Managed, state.Synced, state.StopLatched, state.Profile, state.PendingAction, state.LastAction = true, false, true, "stopped", "", now
	if mayExist {
		state.PendingAction = "delete"
	}
	if err := s.store.update(func(d *diskState) { d.Telemetry[id] = state }); err != nil {
		writeResult(w, failure(503, "storage_unavailable", "Telemetry stop state could not be saved."))
		return
	}
	if !mayExist {
		if state.DeleteConfirmed {
			writeJSON(w, 200, map[string]any{"ok": true, "profile": "stopped", "guard": "latched", "alreadyDeleted": true})
			return
		}
		writeResult(w, failure(409, "telemetry_config_not_owned", "No remote configuration has been created or confirmed; query remote status before treating rollback as complete."))
		return
	}
	meter, meterErr := s.telemetry.meter(r.Context())
	var meterUSD *float64
	if meterErr == nil {
		meterUSD = &meter.USD
	}
	deleteErr := s.telemetry.deleteRemote(r.Context(), id, meterUSD)
	state = s.telemetry.deletionAttempts(id, state)
	if err := deleteErr; err != nil {
		state.Failures++
		state.LastError = err.Error()
		state.NextRetry = now.Add(telemetryRetry(state.Failures))
		_ = s.store.update(func(d *diskState) { d.Telemetry[id] = state })
		writeResult(w, failure(503, "telemetry_delete_pending", "Deletion is saved and the guard will keep retrying."))
		return
	}
	state.ConfigMayExist, state.DeleteConfirmed = false, true
	state.PendingAction, state.LastError, state.Failures, state.NextRetry = "", "", 0, time.Time{}
	_ = s.store.update(func(d *diskState) { d.Telemetry[id] = state })
	writeJSON(w, 200, map[string]any{"ok": true, "profile": "stopped", "guard": "latched"})
}

func telemetryBodyEmpty(r *http.Request) bool {
	b, err := io.ReadAll(io.LimitReader(r.Body, 2))
	return err == nil && len(b) == 0
}
