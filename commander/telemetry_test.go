package commander

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"log/slog"
	"math"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestTelemetryConfigDefaultsAndIsolation(t *testing.T) {
	t.Setenv("COMMANDER_MODE", "stub")
	t.Setenv("COMMANDER_COMMANDS_ENABLED", "false")
	t.Setenv("COMMANDER_INTERNAL_SECRET", strings.Repeat("i", 32))
	t.Setenv("COMMANDER_ENCRYPTION_KEY", base64.StdEncoding.EncodeToString(make([]byte, 32)))
	t.Setenv("COMMANDER_TELEMETRY_ENABLED", "true")
	t.Setenv("COMMANDER_TELEMETRY_METER_SECRET", strings.Repeat("m", 32))
	t.Setenv("COMMANDER_TELEMETRY_METER_URL", "http://127.0.0.1:8449/v1/usage")
	t.Setenv("COMMANDER_TELEMETRY_CA_FILE", testCA(t))
	t.Setenv("COMMANDER_TELEMETRY_HOSTNAME", "volta-node.example.ts.net")
	t.Setenv("COMMANDER_VEHICLES", `{"1":"`+telemetryTestVIN+`"}`)
	t.Setenv("TESLA_CLIENT_ID", "STUB_ONLY")
	t.Setenv("TESLA_CLIENT_SECRET", "STUB_ONLY")
	t.Setenv("TESLA_REDIRECT_URI", "http://127.0.0.1:8091/oauth/callback")
	c, err := ConfigFromEnv()
	if err != nil || !c.TelemetryEnabled || !c.OAuthEnabled || c.Enabled || c.MonthlyBudgetUSD != 5 || c.TelemetryWarnUSD != 20 || c.TelemetryStopUSD != 23 || c.TelemetryCapUSD != 25 || c.TelemetryDeleteReserveUSD != 2 || c.TotalMonthlyCapUSD != 30 || RequestedScopes(c) != ReadScopes {
		t.Fatalf("config=%+v err=%v", c, err)
	}
	meterSecretFile := filepath.Join(t.TempDir(), "meter-secret")
	if err := os.WriteFile(meterSecretFile, []byte(strings.Repeat("f", 32)+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("COMMANDER_TELEMETRY_METER_SECRET", "")
	t.Setenv("COMMANDER_TELEMETRY_METER_SECRET_FILE", meterSecretFile)
	if c, err := ConfigFromEnv(); err != nil || c.TelemetryMeterSecret != strings.Repeat("f", 32) {
		t.Fatalf("meter secret file: %v", err)
	}
	t.Setenv("COMMANDER_TELEMETRY_METER_SECRET", strings.Repeat("m", 32))
	if _, err := ConfigFromEnv(); err == nil {
		t.Fatal("accepted both meter secret sources")
	}
	t.Setenv("COMMANDER_TELEMETRY_METER_SECRET_FILE", "")
	t.Setenv("COMMANDER_TELEMETRY_METER_URL", "http://example.com/v1/usage")
	if _, err := ConfigFromEnv(); err == nil {
		t.Fatal("accepted external meter URL")
	}
	t.Setenv("COMMANDER_TELEMETRY_METER_URL", "http://127.0.0.1:8449/v1/usage")
	t.Setenv("COMMANDER_TELEMETRY_STOP_USD", "20")
	if _, err := ConfigFromEnv(); err == nil {
		t.Fatal("accepted overlapping warn/stop")
	}
	t.Setenv("COMMANDER_TELEMETRY_STOP_USD", "23")
	t.Setenv("COMMANDER_TELEMETRY_HOSTNAME", "")
	if _, err := ConfigFromEnv(); err == nil || !strings.Contains(err.Error(), "COMMANDER_TELEMETRY_HOSTNAME") {
		t.Fatalf("telemetry enabled without a receiver hostname: %v", err)
	}
	t.Setenv("COMMANDER_TELEMETRY_HOSTNAME", "volta-node.example.ts.net")
	t.Setenv("COMMANDER_MODE", "live")
	t.Setenv("TESLA_REDIRECT_URI", "https://georgenijo.com/volta/oauth/callback")
	t.Setenv("TESLA_PROXY_CA_FILE", "")
	if _, err := ConfigFromEnv(); err == nil || !strings.Contains(err.Error(), "live proxy") {
		t.Fatalf("live telemetry allowed without proxy trust: %v", err)
	}
}

const telemetryTestVIN = "5YJ3E1EA0XF000000"

type telemetryFake struct {
	mu              sync.Mutex
	meter           telemetryMeterStatus
	meterCode       int
	paired          bool
	version         string
	fleetStatusCode int
	posts, deletes  int
	statusReads     int
	deleteCode      int
	postDrop        bool
	postReply       string
	profiles        []map[string]telemetryFieldConfig
}

func completeMeter(now time.Time, state string, usd float64) telemetryMeterStatus {
	accounted := now.UTC()
	return telemetryMeterStatus{Month: month(now), USD: usd, State: state, Confidence: "complete", AccountedThrough: &accounted, CheckedAt: accounted, Reasons: []string{}}
}

func (f *telemetryFake) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	switch {
	case r.URL.Path == "/v1/usage":
		if f.meterCode != 0 {
			w.WriteHeader(f.meterCode)
			_, _ = io.WriteString(w, `{}`)
			return
		}
		_ = json.NewEncoder(w).Encode(f.meter)
	case r.URL.Path == "/api/1/vehicles/fleet_status":
		if f.fleetStatusCode != 0 {
			w.WriteHeader(f.fleetStatusCode)
			_, _ = io.WriteString(w, `{"error":"scope denied"}`)
			return
		}
		paired, unpaired := []string{}, []string{telemetryTestVIN}
		if f.paired {
			paired, unpaired = unpaired, paired
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"response": map[string]any{"key_paired_vins": paired, "unpaired_vins": unpaired, "vehicle_info": map[string]any{telemetryTestVIN: map[string]any{"fleet_telemetry_version": f.version}}}})
	case r.Method == http.MethodPost && r.URL.Path == "/api/1/vehicles/fleet_telemetry_config":
		var body struct {
			Config struct {
				Fields map[string]telemetryFieldConfig `json:"fields"`
			} `json:"config"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.posts++
		f.profiles = append(f.profiles, body.Config.Fields)
		if f.postDrop {
			conn, _, err := w.(http.Hijacker).Hijack()
			if err == nil {
				_ = conn.Close()
			}
			return
		}
		if f.postReply != "" {
			_, _ = io.WriteString(w, f.postReply)
			return
		}
		_, _ = io.WriteString(w, `{"response":{"updated_vehicles":1,"skipped_vehicles":{}}}`)
	case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/fleet_telemetry_config"):
		f.statusReads++
		_, _ = io.WriteString(w, `{"response":{"synced":true,"key_paired":true}}`)
	case r.Method == http.MethodDelete && strings.HasSuffix(r.URL.Path, "/fleet_telemetry_config"):
		f.deletes++
		if f.deleteCode != 0 {
			w.WriteHeader(f.deleteCode)
			_, _ = io.WriteString(w, `{"error":"temporary"}`)
			return
		}
		_, _ = io.WriteString(w, `{"response":{}}`)
	default:
		w.WriteHeader(http.StatusNotFound)
		_, _ = io.WriteString(w, `{}`)
	}
}

func testCA(t *testing.T) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "test"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func telemetryService(t *testing.T, fake *telemetryFake, now time.Time) (*Service, *Store, *httptest.Server) {
	t.Helper()
	upstream := httptest.NewServer(fake)
	t.Cleanup(upstream.Close)
	store, err := OpenStore(t.TempDir(), make([]byte, 32))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	if err := store.saveTokens(&Tokens{Access: "test-token", Refresh: "test-refresh", Expires: time.Now().Add(24 * time.Hour), FleetBase: upstream.URL, LinkID: "test-link"}); err != nil {
		t.Fatal(err)
	}
	c := Config{Mode: "stub", Secret: strings.Repeat("i", 32), DataDir: t.TempDir(), Audience: upstream.URL, ProxyURL: upstream.URL, Vehicles: map[string]string{"1": telemetryTestVIN}, TelemetryEnabled: true, TelemetryMeterURL: upstream.URL + "/v1/usage", TelemetryMeterSecret: strings.Repeat("m", 32), TelemetryHostname: "telemetry.test", TelemetryPort: 10000, TelemetryCAFile: testCA(t), TelemetryWarnUSD: 20, TelemetryStopUSD: 23, TelemetryCapUSD: 25, TelemetryDeleteReserveUSD: 2, TotalMonthlyCapUSD: 30, MonthlyBudgetUSD: 5, CallCostUSD: .002, TelemetryMaxAge: 2 * time.Minute}
	s, err := NewService(c, store, upstream.Client(), slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	s.telemetry.now = func() time.Time { return now }
	return s, store, upstream
}

func telemetryRequest(s *Service, method, path string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, nil)
	r.Header.Set("Authorization", "Bearer "+s.c.Secret)
	w := httptest.NewRecorder()
	s.PrivateHandler().ServeHTTP(w, r)
	return w
}

func TestTelemetryCreatePreflightGates(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	t.Run("missing key", func(t *testing.T) {
		fake := &telemetryFake{meter: completeMeter(now, "ok", 1), version: "1.3.0"}
		s, _, _ := telemetryService(t, fake, now)
		w := telemetryRequest(s, http.MethodPost, "/v1/vehicles/1/telemetry/config")
		if w.Code != 409 || !strings.Contains(w.Body.String(), "virtual_key_not_paired") || fake.posts != 0 {
			t.Fatalf("code=%d body=%s posts=%d", w.Code, w.Body.String(), fake.posts)
		}
	})
	t.Run("scope denied", func(t *testing.T) {
		fake := &telemetryFake{meter: completeMeter(now, "ok", 1), paired: true, version: "1.3.0", fleetStatusCode: 403}
		s, _, _ := telemetryService(t, fake, now)
		w := telemetryRequest(s, http.MethodPost, "/v1/vehicles/1/telemetry/config")
		if w.Code != 403 || !strings.Contains(w.Body.String(), "permission_denied") || fake.posts != 0 {
			t.Fatalf("code=%d body=%s", w.Code, w.Body.String())
		}
	})
	t.Run("old client", func(t *testing.T) {
		fake := &telemetryFake{meter: completeMeter(now, "ok", 1), paired: true, version: "1.2.0"}
		s, _, _ := telemetryService(t, fake, now)
		w := telemetryRequest(s, http.MethodPost, "/v1/vehicles/1/telemetry/config")
		if w.Code != 409 || !strings.Contains(w.Body.String(), "telemetry_client_too_old") {
			t.Fatalf("code=%d body=%s", w.Code, w.Body.String())
		}
	})
}

func TestTelemetryRejectedCreateLogsReasonWithoutVIN(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "ok", 1), paired: true, version: "1.3.0",
		postReply: `{"response":{"updated_vehicles":0,"skipped_vehicles":{"unsupported_firmware":["` + telemetryTestVIN + `"]}},"error":"vehicle ` + telemetryTestVIN + ` rejected"}`}
	s, _, _ := telemetryService(t, fake, now)
	var log bytes.Buffer
	s.audit = slog.New(slog.NewTextHandler(&log, nil))
	w := telemetryRequest(s, http.MethodPost, "/v1/vehicles/1/telemetry/config")
	if w.Code != 409 || !strings.Contains(w.Body.String(), "telemetry_config_rejected") {
		t.Fatalf("code=%d body=%s", w.Code, w.Body.String())
	}
	out := log.String()
	if !strings.Contains(out, "telemetry_config_rejected") || !strings.Contains(out, "unsupported_firmware:1") || !strings.Contains(out, "vehicle <vin> rejected") {
		t.Fatalf("reason not logged: %s", out)
	}
	if strings.Contains(out, telemetryTestVIN) {
		t.Fatalf("VIN logged: %s", out)
	}
}

func TestTelemetryCreateFailsClosedOnMeter(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	for name, mutate := range map[string]func(*telemetryFake){
		"unknown": func(f *telemetryFake) { f.meter.State = "unknown"; f.meter.Confidence = "lower_bound" },
		"stale": func(f *telemetryFake) {
			old := now.Add(-3 * time.Minute)
			f.meter.CheckedAt = old
			f.meter.AccountedThrough = &old
		},
		"wrong month": func(f *telemetryFake) { f.meter.Month = "2026-09" },
		"unreachable": func(f *telemetryFake) { f.meterCode = 503 },
	} {
		t.Run(name, func(t *testing.T) {
			fake := &telemetryFake{meter: completeMeter(now, "ok", 1), paired: true, version: "1.3.0"}
			mutate(fake)
			s, _, _ := telemetryService(t, fake, now)
			w := telemetryRequest(s, http.MethodPost, "/v1/vehicles/1/telemetry/config")
			if w.Code != 503 || !strings.Contains(w.Body.String(), "telemetry_meter_unknown") || fake.posts != 0 {
				t.Fatalf("code=%d body=%s", w.Code, w.Body.String())
			}
		})
	}
}

func TestTelemetryWarnDowngradesAndStopLatches(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "ok", 1), paired: true, version: "1.3.0"}
	s, store, _ := telemetryService(t, fake, now)
	if w := telemetryRequest(s, http.MethodPost, "/v1/vehicles/1/telemetry/config"); w.Code != 200 {
		t.Fatalf("create: %d %s", w.Code, w.Body.String())
	}
	fake.mu.Lock()
	fake.meter = completeMeter(now, "warn", 20)
	fake.mu.Unlock()
	s.telemetry.reconcile(context.Background())
	state := store.snapshot().Telemetry["1"]
	if state.Profile != "economy" || state.StopLatched || fake.posts != 2 {
		t.Fatalf("state=%+v posts=%d", state, fake.posts)
	}
	last := fake.profiles[len(fake.profiles)-1]["Location"]
	if last.IntervalSeconds != 10 || len(last.IncludeFields) != 3 {
		t.Fatalf("economy location=%+v", last)
	}
	fake.mu.Lock()
	fake.meter = completeMeter(now, "stop", 23)
	fake.mu.Unlock()
	s.telemetry.reconcile(context.Background())
	state = store.snapshot().Telemetry["1"]
	if state.Profile != "stopped" || !state.StopLatched || state.PendingAction != "" || fake.deletes != 1 {
		t.Fatalf("state=%+v deletes=%d", state, fake.deletes)
	}
	fake.mu.Lock()
	fake.meter = completeMeter(now, "ok", 0)
	fake.mu.Unlock()
	s.telemetry.reconcile(context.Background())
	if fake.posts != 2 || fake.deletes != 1 {
		t.Fatalf("latched guard acted again: posts=%d deletes=%d", fake.posts, fake.deletes)
	}
}

func TestTelemetryRestartAndMonthBoundaryDelete(t *testing.T) {
	now := time.Date(2026, 11, 1, 0, 1, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "ok", 0), paired: true, version: "1.3.0"}
	s, store, _ := telemetryService(t, fake, now)
	old := TelemetryManaged{Month: "2026-10", Managed: true, Profile: "normal", PendingAction: "create_normal"}
	if err := store.update(func(d *diskState) { d.Telemetry["1"] = old }); err != nil {
		t.Fatal(err)
	}
	// A new controller has no process-local memory. Durable pending state is
	// sufficient to delete before doing anything else, even in a new month.
	restarted := NewTelemetryController(s, s.collectorClient)
	restarted.now = func() time.Time { return now }
	s.telemetry = restarted
	restarted.reconcile(context.Background())
	state := store.snapshot().Telemetry["1"]
	if fake.deletes != 1 || !state.StopLatched || state.Profile != "stopped" || state.Month != month(now) {
		t.Fatalf("state=%+v deletes=%d", state, fake.deletes)
	}
}

func TestTelemetryUnknownInitialCreateOutcomeDeletesAfterRestart(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "ok", 1), paired: true, version: "1.3.0", postDrop: true}
	s, store, _ := telemetryService(t, fake, now)
	w := telemetryRequest(s, http.MethodPost, "/v1/vehicles/1/telemetry/config")
	if w.Code < 500 {
		t.Fatalf("unknown POST outcome returned %d: %s", w.Code, w.Body.String())
	}
	pending := store.snapshot().Telemetry["1"]
	if !pending.Managed || pending.PendingAction != "delete" || !pending.StopLatched {
		t.Fatalf("unsafe pending state: %+v", pending)
	}
	// Model a process restart: no controller-local state is retained. The
	// encrypted store alone must cause a DELETE before any possible re-enable.
	fake.mu.Lock()
	fake.postDrop = false
	fake.mu.Unlock()
	restarted := NewTelemetryController(s, s.collectorClient)
	restarted.now = func() time.Time { return now }
	s.telemetry = restarted
	restarted.reconcile(context.Background())
	got := store.snapshot().Telemetry["1"]
	if fake.deletes != 1 || !got.Managed || got.Profile != "stopped" || got.PendingAction != "" {
		t.Fatalf("state=%+v deletes=%d", got, fake.deletes)
	}
}

func TestTelemetryMalformedMeterDeletesManagedConfig(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	cases := map[string]func(*telemetryMeterStatus){
		"negative signals":          func(m *telemetryMeterStatus) { m.Signals = -1 },
		"understated usd":           func(m *telemetryMeterStatus) { m.Signals = 3_000_000; m.USD = 0 },
		"complete with reasons":     func(m *telemetryMeterStatus) { m.Reasons = []string{"accounting_stale"} },
		"complete with uncountable": func(m *telemetryMeterStatus) { m.UncountableRecords = 1 },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			meter := completeMeter(now, "ok", 0)
			mutate(&meter)
			fake := &telemetryFake{meter: meter, paired: true, version: "1.3.0"}
			s, store, _ := telemetryService(t, fake, now)
			if err := store.update(func(d *diskState) {
				d.Telemetry["1"] = TelemetryManaged{Month: month(now), Managed: true, Synced: true, Profile: "normal"}
			}); err != nil {
				t.Fatal(err)
			}
			s.telemetry.reconcile(context.Background())
			got := store.snapshot().Telemetry["1"]
			if fake.deletes != 1 || got.Profile != "stopped" || !got.StopLatched {
				t.Fatalf("state=%+v deletes=%d", got, fake.deletes)
			}
		})
	}
}

func TestTelemetryManagedStatePersistsAcrossStoreRestart(t *testing.T) {
	dir, key := t.TempDir(), make([]byte, 32)
	store, err := OpenStore(dir, key)
	if err != nil {
		t.Fatal(err)
	}
	want := TelemetryManaged{Month: "2026-10", Managed: true, Synced: true, Profile: "economy", PendingAction: "delete", StopLatched: true, StopReason: "operator_stop", ConfigMayExist: true, DeleteAttemptsMonth: "2026-10", DeleteAttempts: 1, AutoResumeMonth: "2026-10", AutoResumeAttempts: 2, NextResume: time.Date(2026, 10, 8, 13, 0, 0, 0, time.UTC), HealthySince: time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC), LastHealthyCheck: time.Date(2026, 10, 8, 12, 9, 0, 0, time.UTC), Failures: 3, NextRetry: time.Date(2026, 10, 8, 12, 5, 0, 0, time.UTC)}
	if err := store.update(func(d *diskState) { d.Telemetry["1"] = want }); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := OpenStore(dir, key)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	got := reopened.snapshot().Telemetry["1"]
	if got.DeleteConfirmed != want.DeleteConfirmed || got.DeleteAttemptsMonth != want.DeleteAttemptsMonth || got.DeleteAttempts != want.DeleteAttempts || got.AutoResumeMonth != want.AutoResumeMonth || got.AutoResumeAttempts != want.AutoResumeAttempts || !got.NextResume.Equal(want.NextResume) || !got.HealthySince.Equal(want.HealthySince) || !got.LastHealthyCheck.Equal(want.LastHealthyCheck) || !got.ConfigMayExist || got.Month != want.Month || got.Profile != want.Profile || got.PendingAction != want.PendingAction || got.StopReason != want.StopReason || got.Failures != want.Failures || !got.NextRetry.Equal(want.NextRetry) || !got.StopLatched {
		t.Fatalf("got=%+v want=%+v", got, want)
	}
}

func TestTelemetryDeleteFailureBacksOffDurably(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "unknown", 0), paired: true, version: "1.3.0", deleteCode: 503}
	s, store, _ := telemetryService(t, fake, now)
	if err := store.update(func(d *diskState) {
		d.Telemetry["1"] = TelemetryManaged{Month: month(now), Managed: true, Profile: "normal"}
	}); err != nil {
		t.Fatal(err)
	}
	s.telemetry.reconcile(context.Background())
	state := store.snapshot().Telemetry["1"]
	if fake.deletes != 1 || state.PendingAction != "delete" || state.NextRetry.IsZero() {
		t.Fatalf("state=%+v deletes=%d", state, fake.deletes)
	}
	s.telemetry.reconcile(context.Background())
	if fake.deletes != 1 {
		t.Fatalf("retry ignored durable backoff: %d", fake.deletes)
	}
	s.telemetry.now = func() time.Time { return now.Add(16 * time.Second) }
	s.telemetry.reconcile(context.Background())
	if fake.deletes != 2 {
		t.Fatalf("retry did not resume: %d", fake.deletes)
	}
}

func TestTelemetryRenewsOnlyActiveUnlatchedConfig(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "ok", 1), paired: true, version: "1.3.0"}
	s, store, _ := telemetryService(t, fake, now)
	state := TelemetryManaged{Month: month(now), Managed: true, Synced: true, Profile: "normal", ConfigExpires: now.Add(23 * time.Hour)}
	if err := store.update(func(d *diskState) { d.Telemetry["1"] = state }); err != nil {
		t.Fatal(err)
	}
	s.telemetry.reconcile(context.Background())
	got := store.snapshot().Telemetry["1"]
	if fake.posts != 1 || !got.ConfigExpires.Equal(now.Add(30*24*time.Hour)) {
		t.Fatalf("state=%+v posts=%d", got, fake.posts)
	}
	got.StopLatched, got.Profile, got.ConfigExpires = true, "stopped", now
	if err := store.update(func(d *diskState) { d.Telemetry["1"] = got }); err != nil {
		t.Fatal(err)
	}
	s.telemetry.reconcile(context.Background())
	if fake.posts != 1 {
		t.Fatalf("stopped config renewed: %d", fake.posts)
	}
}

func TestTelemetryPaidReadsStopAtPollingAllowance(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "ok", 1), paired: true, version: "1.3.0"}
	s, store, _ := telemetryService(t, fake, now)
	if err := store.update(func(d *diskState) { d.Usage = &Usage{Month: month(now), Calls: 2499, USD: 4.998} }); err != nil {
		t.Fatal(err)
	}
	if w := telemetryRequest(s, http.MethodGet, "/v1/vehicles/1/telemetry/config"); w.Code != 200 {
		t.Fatalf("last allowed read: %d %s", w.Code, w.Body.String())
	}
	if w := telemetryRequest(s, http.MethodGet, "/v1/vehicles/1/telemetry/config"); w.Code != 429 || !strings.Contains(w.Body.String(), "fleet_budget_stopped") {
		t.Fatalf("over-budget read: %d %s", w.Code, w.Body.String())
	}
	u := store.snapshot().Usage
	if fake.statusReads != 1 || u.Calls != 2500 || math.Abs(u.USD-5) > 1e-9 {
		t.Fatalf("reads=%d usage=%+v", fake.statusReads, u)
	}
}

func TestTelemetryProfileUpdateRequiresPostAndReceiptBudget(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "warn", 20), paired: true, version: "1.3.0"}
	s, store, _ := telemetryService(t, fake, now)
	state := TelemetryManaged{Month: month(now), Managed: true, Synced: true, Profile: "normal"}
	if err := store.update(func(d *diskState) {
		d.Usage = &Usage{Month: month(now), Calls: 2499, USD: 4.998}
		d.Telemetry["1"] = state
	}); err != nil {
		t.Fatal(err)
	}
	result := s.telemetry.applyProfile(context.Background(), "1", state, "economy", fake.meter)
	if result == nil || result.Status != 429 || result.Error.Code != "fleet_budget_stopped" {
		t.Fatalf("result=%+v", result)
	}
	snap := store.snapshot()
	if fake.posts != 0 || snap.Usage.Calls != 2499 || snap.Telemetry["1"].PendingAction != "delete" {
		t.Fatalf("posts=%d usage=%+v state=%+v", fake.posts, snap.Usage, snap.Telemetry["1"])
	}
}

func TestTelemetryGuardStopsAtCombinedOperatingLine(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "ok", 22.999), paired: true, version: "1.3.0"}
	s, store, _ := telemetryService(t, fake, now)
	if err := store.update(func(d *diskState) {
		d.Usage = &Usage{Month: month(now), Calls: 2501, USD: 5.001}
		d.Telemetry["1"] = TelemetryManaged{Month: month(now), Managed: true, Synced: true, Profile: "normal"}
	}); err != nil {
		t.Fatal(err)
	}
	s.telemetry.reconcile(context.Background())
	state := store.snapshot().Telemetry["1"]
	if fake.deletes != 1 || state.Profile != "stopped" || state.LastMeter != "shared_budget_stop" {
		t.Fatalf("state=%+v deletes=%d", state, fake.deletes)
	}
}

func TestTelemetryDeleteReserveBoundsPaidAttempts(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "unknown", 0), paired: true, version: "1.3.0"}
	s, store, _ := telemetryService(t, fake, now)
	if err := store.update(func(d *diskState) {
		d.Usage = &Usage{Month: month(now), Calls: 999, USD: 1.998}
		d.Safety = &SafetyUsage{Month: month(now), Calls: 999, USD: 1.998}
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.telemetry.deleteRemote(context.Background(), "1", nil); err != nil {
		t.Fatal(err)
	}
	if err := s.telemetry.deleteRemote(context.Background(), "1", nil); !errors.Is(err, errDeleteReserve) {
		t.Fatalf("second delete err=%v", err)
	}
	snap := store.snapshot()
	if fake.deletes != 1 || snap.Safety.Calls != 1000 || math.Abs(snap.Safety.USD-2) > 1e-9 {
		t.Fatalf("deletes=%d safety=%+v", fake.deletes, snap.Safety)
	}
}

func TestTelemetryOutageGraceAndRecovery(t *testing.T) {
	for _, kind := range []string{"reboot", "consumer_restart", "receiver_restart"} {
		t.Run(kind, func(t *testing.T) {
			now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
			fake := &telemetryFake{meter: completeMeter(now, "ok", 1), paired: true, version: "1.3.0"}
			s, store, _ := telemetryService(t, fake, now)
			if w := telemetryRequest(s, http.MethodPost, "/v1/vehicles/1/telemetry/config"); w.Code != 200 {
				t.Fatal(w.Code)
			}
			fake.meterCode = 503
			if kind == "consumer_restart" {
				fake.meterCode = 0
				fake.meter.State = "unknown"
				fake.meter.Confidence = "lower_bound"
				fake.meter.Reasons = []string{"store_retrying"}
			}
			if kind == "receiver_restart" {
				fake.meterCode = 0
				fake.meter.CheckedAt = now.Add(-3 * time.Minute)
			}
			s.telemetry = NewTelemetryController(s, s.collectorClient)
			s.telemetry.now = func() time.Time { return now.Add(20 * time.Second) }
			s.telemetry.reconcile(context.Background())
			state := store.snapshot().Telemetry["1"]
			if fake.deletes != 0 || state.StopLatched || state.UnknownSince.IsZero() {
				t.Fatalf("grace %+v", state)
			}
			s.telemetry.now = func() time.Time { return now.Add(5*time.Minute + 20*time.Second) }
			s.telemetry.reconcile(context.Background())
			state = store.snapshot().Telemetry["1"]
			if fake.deletes != 1 || !state.StopLatched || state.PendingAction != "" || !strings.HasPrefix(state.StopReason, "meter_") {
				t.Fatalf("timeout %+v", state)
			}
			recovered := now.Add(6 * time.Minute)
			fake.meterCode, fake.meter = 0, completeMeter(recovered, "ok", 2)
			s.telemetry.now = func() time.Time { return recovered }
			s.telemetry.reconcile(context.Background())
			if fake.posts != 1 {
				t.Fatal("resumed before ten minutes of complete accounting")
			}
			telemetryHealthyTicks(s, fake, recovered, 10*time.Minute, 2)
			state = store.snapshot().Telemetry["1"]
			if fake.posts != 2 || state.StopLatched || state.StopReason != "" || state.Profile != "normal" || state.LastKnownUSD != 2 {
				t.Fatalf("recovery %+v", state)
			}
		})
	}
}

func TestTelemetryShortOutageRecovery(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "ok", 1), paired: true, version: "1.3.0"}
	s, store, _ := telemetryService(t, fake, now)
	if w := telemetryRequest(s, http.MethodPost, "/v1/vehicles/1/telemetry/config"); w.Code != 200 {
		t.Fatal(w.Code)
	}
	fake.meterCode = 503
	s.telemetry.reconcile(context.Background())
	recovered := now.Add(2 * time.Minute)
	fake.meterCode, fake.meter = 0, completeMeter(recovered, "ok", 1.2)
	s.telemetry.now = func() time.Time { return recovered }
	s.telemetry.reconcile(context.Background())
	if state := store.snapshot().Telemetry["1"]; fake.deletes != 0 || fake.posts != 1 || !state.UnknownSince.IsZero() {
		t.Fatalf("state %+v", state)
	}
}

func TestTelemetryUnknownBurnStopsNearBudget(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meterCode: 503, paired: true, version: "1.3.0"}
	s, store, _ := telemetryService(t, fake, now)
	if err := store.update(func(d *diskState) {
		d.Telemetry["1"] = TelemetryManaged{Managed: true, Profile: "economy", LastKnownMonth: month(now), LastKnownUSD: 22.9, LastKnownThrough: now}
	}); err != nil {
		t.Fatal(err)
	}
	s.telemetry.reconcile(context.Background())
	if fake.deletes != 1 {
		t.Fatal("projected burn crossed stop")
	}
}

func TestTelemetryMonthRolloverGrace(t *testing.T) {
	old := time.Date(2026, 10, 31, 23, 59, 59, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(old, "ok", 1), paired: true, version: "1.3.0"}
	s, store, _ := telemetryService(t, fake, old)
	if w := telemetryRequest(s, http.MethodPost, "/v1/vehicles/1/telemetry/config"); w.Code != 200 {
		t.Fatal(w.Code)
	}
	next := old.Add(2 * time.Second)
	s.telemetry.now = func() time.Time { return next }
	s.telemetry.reconcile(context.Background())
	if fake.deletes != 0 {
		t.Fatal("previous-month cache deleted")
	}
	fake.meter = completeMeter(next, "unknown", 0)
	fake.meter.AccountedThrough = nil
	fake.meter.Confidence = "lower_bound"
	fake.meter.Reasons = []string{"starting"}
	s.telemetry.reconcile(context.Background())
	if fake.deletes != 0 {
		t.Fatal("new-month starting deleted")
	}
	fake.meter = completeMeter(next, "ok", 0)
	s.telemetry.reconcile(context.Background())
	if state := store.snapshot().Telemetry["1"]; state.LastKnownMonth != "2026-11" || state.StopLatched {
		t.Fatalf("new month %+v", state)
	}
}

func TestTelemetryOnlyMeterLatchesAutoResume(t *testing.T) {
	for _, reason := range []string{"budget_stop", "shared_budget_stop", "operator_stop", "config_outcome_unknown", ""} {
		t.Run(reason, func(t *testing.T) {
			now := time.Date(2026, 11, 1, 0, 1, 0, 0, time.UTC)
			fake := &telemetryFake{meter: completeMeter(now, "ok", 0), paired: true, version: "1.3.0"}
			s, store, _ := telemetryService(t, fake, now)
			if err := store.update(func(d *diskState) {
				d.Telemetry["1"] = TelemetryManaged{Managed: true, Profile: "stopped", StopLatched: true, StopReason: reason}
			}); err != nil {
				t.Fatal(err)
			}
			s.telemetry.reconcile(context.Background())
			if fake.posts != 0 || !store.snapshot().Telemetry["1"].StopLatched {
				t.Fatal("non-meter latch cleared")
			}
		})
	}
}

func TestTelemetrySafetyDeleteAboveTotalCap(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "stop", 31), paired: true, version: "1.3.0"}
	s, store, _ := telemetryService(t, fake, now)
	if err := store.update(func(d *diskState) { d.Usage = &Usage{Month: month(now), USD: 5} }); err != nil {
		t.Fatal(err)
	}
	usd := 31.0
	if err := s.telemetry.deleteRemote(context.Background(), "1", &usd); err != nil {
		t.Fatal(err)
	}
	if fake.deletes != 1 || store.snapshot().Safety.Calls != 1 {
		t.Fatal("delete refused above cap")
	}
}

func TestTelemetryIncompleteHighSpendCannotUseGrace(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "unknown", 24), paired: true, version: "1.3.0"}
	fake.meter.Confidence = "lower_bound"
	fake.meter.Reasons = []string{"store_retrying"}
	s, store, _ := telemetryService(t, fake, now)
	if err := store.update(func(d *diskState) {
		d.Telemetry["1"] = TelemetryManaged{Managed: true, Profile: "normal", LastKnownMonth: month(now), LastKnownUSD: 1, LastKnownThrough: now}
	}); err != nil {
		t.Fatal(err)
	}
	s.telemetry.reconcile(context.Background())
	if fake.deletes != 1 || store.snapshot().Telemetry["1"].StopReason != "budget_stop" {
		t.Fatal("incomplete spend past stop did not budget-latch")
	}
}

func TestTelemetryMeterLatchBecomesBudgetLatch(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "stop", 24), paired: true, version: "1.3.0"}
	s, store, _ := telemetryService(t, fake, now)
	if err := store.update(func(d *diskState) {
		d.Telemetry["1"] = TelemetryManaged{Managed: true, Profile: "stopped", StopLatched: true, StopReason: "meter_unavailable"}
	}); err != nil {
		t.Fatal(err)
	}
	s.telemetry.reconcile(context.Background())
	if got := store.snapshot().Telemetry["1"].StopReason; got != "budget_stop" {
		t.Fatal(got)
	}
	fake.meter = completeMeter(now, "ok", 0)
	s.telemetry.reconcile(context.Background())
	if fake.posts != 0 {
		t.Fatal("budget latch resumed")
	}
}

func TestTelemetryGraceSurvivesDurableStoreRestart(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meterCode: 503, paired: true, version: "1.3.0"}
	s, _, _ := telemetryService(t, fake, now)
	dir, key := t.TempDir(), make([]byte, 32)
	store, err := OpenStore(dir, key)
	if err != nil {
		t.Fatal(err)
	}
	if err = store.update(func(d *diskState) {
		d.Telemetry["1"] = TelemetryManaged{Managed: true, Profile: "normal", LastKnownMonth: month(now), LastKnownUSD: 1, LastKnownThrough: now, UnknownSince: now}
	}); err != nil {
		t.Fatal(err)
	}
	if err = store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := OpenStore(dir, key)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	state := reopened.snapshot().Telemetry["1"]
	if !state.UnknownSince.Equal(now) || !state.LastKnownThrough.Equal(now) || state.LastKnownUSD != 1 {
		t.Fatalf("lost durable grace %+v", state)
	}
	// Do not replace the service's token store; exercise the durable projection
	// directly so a process restart cannot reset the five-minute deadline.
	if s.telemetry.unknownGrace("1", state, "meter_unavailable", telemetryMeterStatus{}, 0) != true {
		t.Fatal("fresh grace refused")
	}
	s.telemetry.now = func() time.Time { return now.Add(5 * time.Minute) }
	if s.telemetry.unknownGrace("1", state, "meter_unavailable", telemetryMeterStatus{}, 0) {
		t.Fatal("restart extended deadline")
	}
}

func TestTelemetryResumePreflightBackoffAndPermanentFailure(t *testing.T) {
	for _, code := range []int{409, 503} {
		t.Run(strconv.Itoa(code), func(t *testing.T) {
			now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
			fake := &telemetryFake{meter: completeMeter(now, "ok", 1), paired: true, version: "1.3.0", fleetStatusCode: code}
			s, store, _ := telemetryService(t, fake, now)
			if code == 409 {
				fake.fleetStatusCode = 0
				fake.paired = false
			}
			if err := store.update(func(d *diskState) {
				d.Telemetry["1"] = TelemetryManaged{Managed: true, Profile: "stopped", StopLatched: true, StopReason: "meter_unavailable", AutoResumeMonth: month(now), HealthySince: now.Add(-10 * time.Minute), LastHealthyCheck: now}
			}); err != nil {
				t.Fatal(err)
			}
			s.telemetry.reconcile(context.Background())
			first := store.snapshot()
			if first.Usage.Calls != 1 || first.Telemetry["1"].NextResume.IsZero() {
				t.Fatalf("first %+v", first)
			}
			s.telemetry.now = func() time.Time { return now.Add(10 * time.Second) }
			s.telemetry.reconcile(context.Background())
			if store.snapshot().Usage.Calls != 1 {
				t.Fatal("backoff ignored")
			}
			telemetryHealthyTicks(s, fake, now.Add(time.Minute), 9*time.Minute, 1)
			if code == 409 {
				if store.snapshot().Usage.Calls != 1 || store.snapshot().Telemetry["1"].StopReason != "resume_virtual_key_not_paired" {
					t.Fatal("permanent preflight repeated")
				}
			} else {
				got := store.snapshot()
				if got.Usage.Calls != 2 || got.Telemetry["1"].NextResume != now.Add(30*time.Minute) {
					t.Fatalf("retry %+v", got)
				}
				s.telemetry.now = func() time.Time { return now.Add(11 * time.Minute) }
				fake.meter = completeMeter(now.Add(11*time.Minute), "ok", 1)
				s.telemetry.reconcile(context.Background())
				if store.snapshot().Usage.Calls != 2 {
					t.Fatal("exponential retry ignored")
				}
			}
		})
	}
}

func TestTelemetryResumeEarlyCAFailureBacksOff(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "ok", 1), paired: true, version: "1.3.0"}
	s, store, _ := telemetryService(t, fake, now)
	s.c.TelemetryCAFile = filepath.Join(t.TempDir(), "absent.pem")
	if err := store.update(func(d *diskState) {
		d.Telemetry["1"] = TelemetryManaged{Managed: true, Profile: "stopped", StopLatched: true, StopReason: "meter_unavailable", AutoResumeMonth: month(now), HealthySince: now.Add(-10 * time.Minute), LastHealthyCheck: now}
	}); err != nil {
		t.Fatal(err)
	}
	s.telemetry.reconcile(context.Background())
	first := store.snapshot()
	if first.Usage.Calls != 1 || first.Telemetry["1"].LastError != "telemetry_ca_unavailable" {
		t.Fatalf("first %+v", first)
	}
	s.telemetry.now = func() time.Time { return now.Add(10 * time.Second) }
	s.telemetry.reconcile(context.Background())
	if store.snapshot().Usage.Calls != 1 {
		t.Fatal("CA failure retried every tick")
	}
}

// Fresh complete receipts throughout the window; jumping the clock alone must
// not satisfy accounting hysteresis after a process/receiver outage.
func telemetryHealthyTicks(s *Service, fake *telemetryFake, start time.Time, duration time.Duration, usd float64) {
	for elapsed := time.Duration(0); elapsed <= duration; elapsed += 30 * time.Second {
		now := start.Add(elapsed)
		fake.meterCode, fake.meter = 0, completeMeter(now, "ok", usd)
		s.telemetry.now = func() time.Time { return now }
		s.telemetry.reconcile(context.Background())
	}
}

func TestTelemetryFlappingDoesNotDrainMonthlyLanes(t *testing.T) {
	for _, tc := range []struct {
		name           string
		polling, total float64
		cycles         int
	}{
		{"defaults", 5, 30, 833}, {"non-default", 15, 40, 1000},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
			fake := &telemetryFake{meter: completeMeter(now, "ok", 0), paired: true, version: "1.3.0"}
			s, store, _ := telemetryService(t, fake, now)
			s.c.MonthlyBudgetUSD, s.c.TotalMonthlyCapUSD = tc.polling, tc.total
			if w := telemetryRequest(s, http.MethodPost, "/v1/vehicles/1/telemetry/config"); w.Code != 200 {
				t.Fatal(w.Code)
			}
			for cycle := 0; cycle < tc.cycles; cycle++ {
				fake.meterCode = 503
				for _, elapsed := range []time.Duration{15 * time.Second, 5*time.Minute + 15*time.Second} {
					now = now.Add(elapsed)
					s.telemetry.now = func() time.Time { return now }
					s.telemetry.reconcile(context.Background())
				}
				// Reviewer reproduction: 5m30s outage, two healthy ticks, repeat.
				for tick := 0; tick < 2; tick++ {
					now = now.Add(15 * time.Second)
					fake.meterCode, fake.meter = 0, completeMeter(now, "ok", 0)
					s.telemetry.reconcile(context.Background())
				}
				snap := store.snapshot()
				if telemetryMayExist(snap.Telemetry["1"]) && snap.Safety != nil && snap.Safety.USD+s.c.CallCostUSD > s.c.TelemetryDeleteReserveUSD+1e-9 {
					t.Fatal("live config without deletion headroom")
				}
			}
			snap := store.snapshot()
			if fake.posts != 1 || fake.deletes != 1 || fake.statusReads != 1 || snap.Usage.Calls != 4 || snap.Safety.Calls != 1 || snap.Usage.USD-snap.Safety.USD >= .01 || snap.Telemetry["1"].PendingAction != "" {
				t.Fatalf("unbounded flapping posts=%d deletes=%d usage=%+v safety=%+v state=%+v", fake.posts, fake.deletes, snap.Usage, snap.Safety, snap.Telemetry["1"])
			}
			t.Logf("%d cycles: %d total calls, $%.3f normal lane, $%.3f DELETE reserve", tc.cycles, snap.Usage.Calls, snap.Usage.USD-snap.Safety.USD, snap.Safety.USD)
		})
	}
}

func TestTelemetrySuccessfulRecoveryPreservesMonthlyHysteresis(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "ok", 0), paired: true, version: "1.3.0"}
	s, store, _ := telemetryService(t, fake, now)
	if w := telemetryRequest(s, http.MethodPost, "/v1/vehicles/1/telemetry/config"); w.Code != 200 {
		t.Fatal(w.Code)
	}
	for cycle := 0; cycle <= telemetryMaxAutoResumes; cycle++ {
		fake.meterCode = 503
		s.telemetry.reconcile(context.Background())
		now = now.Add(5*time.Minute + 30*time.Second)
		s.telemetry.now = func() time.Time { return now }
		s.telemetry.reconcile(context.Background())
		if state := store.snapshot().Telemetry["1"]; state.ConfigMayExist || state.PendingAction != "" || state.AutoResumeAttempts != cycle {
			t.Fatalf("DELETE reset history: %+v", state)
		}
		// Recreate controller to prove process restarts cannot remove cooldown.
		s.telemetry = NewTelemetryController(s, s.collectorClient)
		now = now.Add(30 * time.Second)
		telemetryHealthyTicks(s, fake, now, 40*time.Minute, 0)
		now = now.Add(40 * time.Minute)
		state := store.snapshot().Telemetry["1"]
		if cycle < telemetryMaxAutoResumes {
			if state.Profile != "normal" || state.AutoResumeAttempts != cycle+1 || state.NextResume.IsZero() {
				t.Fatalf("resume cleared hysteresis: %+v", state)
			}
		} else if state.StopReason != "auto_resume_limit" || !state.StopLatched {
			t.Fatalf("cap did not require operator: %+v", state)
		}
	}
	snap := store.snapshot()
	if fake.posts != 4 || fake.deletes != 4 || snap.Usage.Calls != 16 || snap.Safety.Calls != 4 {
		t.Fatalf("calls=%+v safety=%+v", snap.Usage, snap.Safety)
	}
	// Rollover must not clear an operator-required latch.
	telemetryHealthyTicks(s, fake, time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC), 10*time.Minute, 0)
	if fake.posts != 4 || store.snapshot().Telemetry["1"].StopReason != "auto_resume_limit" {
		t.Fatal("rollover cleared operator latch")
	}
}

func TestTelemetryCreateAndRenewRequireTwoDeleteAttempts(t *testing.T) {
	for _, action := range []string{"operator", "resume", "renew", "economy"} {
		for _, remaining := range []int{0, 1, 2} {
			t.Run(action+strconv.Itoa(remaining), func(t *testing.T) {
				now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
				fake := &telemetryFake{meter: completeMeter(now, "ok", 0), paired: true, version: "1.3.0"}
				s, store, _ := telemetryService(t, fake, now)
				state := TelemetryManaged{Managed: true, Profile: "stopped", StopLatched: true, StopReason: "meter_unavailable", AutoResumeMonth: month(now), HealthySince: now.Add(-10 * time.Minute), LastHealthyCheck: now}
				if action == "renew" || action == "economy" {
					state.Profile = "normal"
					state.StopLatched = false
					state.ConfigMayExist = true
					state.ConfigExpires = now.Add(time.Hour)
				}
				if action == "economy" {
					fake.meter = completeMeter(now, "warn", 20)
				}
				spent := s.c.TelemetryDeleteReserveUSD - float64(remaining)*s.c.CallCostUSD
				if err := store.update(func(d *diskState) { d.Telemetry["1"] = state; d.Safety = &SafetyUsage{Month: month(now), USD: spent} }); err != nil {
					t.Fatal(err)
				}
				if action == "operator" {
					w := telemetryRequest(s, http.MethodPost, "/v1/vehicles/1/telemetry/config")
					if remaining < 2 && (w.Code != 429 || !strings.Contains(w.Body.String(), errDeleteHeadroom.Error())) {
						t.Fatalf("missing clear refusal: %d %s", w.Code, w.Body.String())
					}
				} else {
					s.telemetry.reconcile(context.Background())
				}
				if remaining < 2 {
					if fake.posts != 0 || fake.statusReads != 0 || store.snapshot().Usage != nil {
						t.Fatal("unsafe create incurred paid calls")
					}
				} else if fake.posts != 1 {
					t.Fatal("two-delete headroom rejected")
				}
			})
		}
	}
}

func TestTelemetryRefusedFirstCreateHasNoPhantomDelete(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "ok", 0), paired: true, version: "1.3.0"}
	s, store, _ := telemetryService(t, fake, now)
	if err := store.update(func(d *diskState) { d.Usage = &Usage{Month: month(now), Calls: 2498, USD: 4.996} }); err != nil {
		t.Fatal(err)
	}
	w := telemetryRequest(s, http.MethodPost, "/v1/vehicles/1/telemetry/config")
	if w.Code != 429 {
		t.Fatalf("status=%d %s", w.Code, w.Body.String())
	}
	s.telemetry.reconcile(context.Background())
	state := store.snapshot().Telemetry["1"]
	if fake.posts != 0 || fake.deletes != 0 || state.PendingAction != "" || state.ConfigMayExist || state.StopReason != "budget_stop" {
		t.Fatalf("phantom DELETE/latch mismatch %+v", state)
	}
	if w := telemetryRequest(s, http.MethodDelete, "/v1/vehicles/1/telemetry/config"); w.Code != 409 || fake.deletes != 0 || !strings.Contains(w.Body.String(), "telemetry_config_not_owned") {
		t.Fatal("operator stop falsely confirmed absent config")
	}
}

func TestTelemetryRecoveryWindowRestartsAfterIncompleteAccounting(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "ok", 0), paired: true, version: "1.3.0"}
	s, store, _ := telemetryService(t, fake, now)
	if err := store.update(func(d *diskState) {
		d.Telemetry["1"] = TelemetryManaged{Managed: true, Profile: "stopped", StopLatched: true, StopReason: "meter_unavailable"}
	}); err != nil {
		t.Fatal(err)
	}
	telemetryHealthyTicks(s, fake, now, 9*time.Minute, 0)
	if fake.posts != 0 {
		t.Fatal("resumed early")
	}
	now = now.Add(9*time.Minute + 30*time.Second)
	fake.meterCode = 503
	s.telemetry.now = func() time.Time { return now }
	s.telemetry.reconcile(context.Background())
	telemetryHealthyTicks(s, fake, now.Add(30*time.Second), 9*time.Minute, 0)
	if fake.posts != 0 {
		t.Fatal("incomplete accounting did not restart healthy window")
	}
	telemetryHealthyTicks(s, fake, now.Add(10*time.Minute), time.Minute, 0)
	if fake.posts != 1 {
		t.Fatal("complete accounting window did not resume")
	}
}

func TestTelemetryTwoVehiclesCanSpendTheirOwnDeleteClaims(t *testing.T) {
	for _, operator := range []bool{false, true} {
		t.Run(strconv.FormatBool(operator), func(t *testing.T) {
			now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
			fake := &telemetryFake{meter: completeMeter(now, "ok", 0), paired: true, version: "1.3.0", deleteCode: 503}
			s, store, _ := telemetryService(t, fake, now)
			s.c.Vehicles["2"] = telemetryTestVIN[:16] + "2"
			s.c.TelemetryDeleteReserveUSD = 4 * s.c.CallCostUSD
			if err := store.update(func(d *diskState) {
				for _, id := range []string{"1", "2"} {
					d.Telemetry[id] = TelemetryManaged{Managed: true, ConfigMayExist: true, Profile: "normal"}
				}
			}); err != nil {
				t.Fatal(err)
			}
			// A repeated operator must not consume B's two reserved attempts.
			for _, id := range []string{"1", "1", "1", "2", "2"} {
				if operator {
					telemetryRequest(s, http.MethodDelete, "/v1/vehicles/"+id+"/telemetry/config")
				} else {
					state := store.snapshot().Telemetry[id]
					s.telemetry.stopManaged(context.Background(), id, state, "operator_stop", fake.meter, true)
				}
				if id == "1" && fake.deletes > 2 {
					t.Fatal("vehicle A spent B's claim")
				}
			}
			snap := store.snapshot()
			if fake.deletes != 4 || snap.Safety.Calls != 4 || snap.Telemetry["1"].DeleteAttempts != 2 || snap.Telemetry["2"].DeleteAttempts != 2 {
				t.Fatalf("stranded/starved claims: deletes=%d safety=%+v A=%+v B=%+v", fake.deletes, snap.Safety, snap.Telemetry["1"], snap.Telemetry["2"])
			}
			// Replenish on rollover without erasing ownership or pending deletion.
			now = now.AddDate(0, 1, 0)
			s.telemetry.now = func() time.Time { return now }
			fake.deleteCode = 0
			for _, id := range []string{"1", "2"} {
				s.telemetry.stopManaged(context.Background(), id, store.snapshot().Telemetry[id], "operator_stop", fake.meter, false)
			}
			if fake.deletes != 6 || store.snapshot().Telemetry["1"].ConfigMayExist || store.snapshot().Telemetry["2"].ConfigMayExist {
				t.Fatal("rollover claims/deletion ownership broken")
			}
		})
	}
}

func TestTelemetryOperatorDeleteRequiresCreatedOrConfirmedOwnership(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	fake := &telemetryFake{meter: completeMeter(now, "ok", 0), paired: true, version: "1.3.0"}
	s, store, _ := telemetryService(t, fake, now)
	w := telemetryRequest(s, http.MethodDelete, "/v1/vehicles/1/telemetry/config")
	if w.Code != 409 || !strings.Contains(w.Body.String(), "telemetry_config_not_owned") || fake.deletes != 0 {
		t.Fatalf("unowned rollback reported stopped: %d %s", w.Code, w.Body.String())
	}
	// Remote status confirms an external config even after commander state loss.
	if w := telemetryRequest(s, http.MethodGet, "/v1/vehicles/1/telemetry/config"); w.Code != 200 {
		t.Fatal(w.Code)
	}
	if state := store.snapshot().Telemetry["1"]; !state.Managed || !state.ConfigMayExist || state.PendingAction != "delete" {
		t.Fatalf("remote confirmation lost ownership or falsely reported stopped: %+v", state)
	}
	fake.deleteCode = 503
	w = telemetryRequest(s, http.MethodDelete, "/v1/vehicles/1/telemetry/config")
	if w.Code != 503 || fake.deletes != 1 || store.snapshot().Telemetry["1"].PendingAction != "delete" {
		t.Fatal("failed confirmed deletion lost retry ownership")
	}
	fake.deleteCode = 0
	w = telemetryRequest(s, http.MethodDelete, "/v1/vehicles/1/telemetry/config")
	if w.Code != 200 || fake.deletes != 2 || store.snapshot().Telemetry["1"].ConfigMayExist {
		t.Fatal("confirmed operator rollback never deleted Tesla config")
	}
}

func TestTelemetryConfirmedDeleteIsDurablyIdempotent(t *testing.T) {
	for _, guard := range []bool{false, true} {
		t.Run(strconv.FormatBool(guard), func(t *testing.T) {
			now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
			fake := &telemetryFake{meter: completeMeter(now, "ok", 0), paired: true, version: "1.3.0"}
			s, store, _ := telemetryService(t, fake, now)
			if w := telemetryRequest(s, http.MethodPost, "/v1/vehicles/1/telemetry/config"); w.Code != 200 {
				t.Fatal(w.Code)
			}
			if guard {
				fake.meter = completeMeter(now, "stop", 23)
				s.telemetry.reconcile(context.Background())
			} else if w := telemetryRequest(s, http.MethodDelete, "/v1/vehicles/1/telemetry/config"); w.Code != 200 {
				t.Fatal(w.Code)
			}
			state := store.snapshot().Telemetry["1"]
			if !state.DeleteConfirmed || state.ConfigMayExist || state.PendingAction != "" {
				t.Fatalf("successful DELETE not confirmed: %+v", state)
			}
			// Reopen the actual encrypted store; a repeat after a lost CLI receipt
			// must return success without needing meter/OAuth/another paid call.
			if err := store.Close(); err != nil {
				t.Fatal(err)
			}
			reopened, err := OpenStore(filepath.Dir(store.path), make([]byte, 32))
			if err != nil {
				t.Fatal(err)
			}
			defer reopened.Close()
			s, err = NewService(s.c, reopened, s.collectorClient, slog.New(slog.NewTextHandler(io.Discard, nil)))
			if err != nil {
				t.Fatal(err)
			}
			fake.meterCode = 503
			s.telemetry.now = func() time.Time { return now }
			before := reopened.snapshot().Usage.Calls
			w := telemetryRequest(s, http.MethodDelete, "/v1/vehicles/1/telemetry/config")
			if w.Code != 200 || !strings.Contains(w.Body.String(), "alreadyDeleted") || fake.deletes != 1 || reopened.snapshot().Usage.Calls != before {
				t.Fatalf("repeat was not idempotent: %d %s", w.Code, w.Body.String())
			}
			// A new confirmed external config invalidates the old delete receipt.
			fake.meterCode, fake.meter = 0, completeMeter(now, "ok", 0)
			if w := telemetryRequest(s, http.MethodGet, "/v1/vehicles/1/telemetry/config"); w.Code != 200 {
				t.Fatal(w.Code)
			}
			if reopened.snapshot().Telemetry["1"].DeleteConfirmed {
				t.Fatal("remote confirmation retained stale deletion proof")
			}
			if w := telemetryRequest(s, http.MethodDelete, "/v1/vehicles/1/telemetry/config"); w.Code != 200 || fake.deletes != 2 {
				t.Fatal("new external config was not deleted")
			}
			if w := telemetryRequest(s, http.MethodPost, "/v1/vehicles/1/telemetry/config"); w.Code != 200 || reopened.snapshot().Telemetry["1"].DeleteConfirmed {
				t.Fatal("new POST retained deletion proof")
			}
		})
	}
}
