package commander

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func scopeToken(scopes ...string) string {
	b, _ := json.Marshal(map[string]any{"scp": scopes, "sub": "synthetic-owner"})
	return "synthetic." + base64.RawURLEncoding.EncodeToString(b) + ".signature"
}

func TestCommandCapabilitiesFailClosedWithoutTeslaCalls(t *testing.T) {
	s, store, _, _ := fixture(t, func(http.ResponseWriter, *http.Request) { t.Error("capabilities called Tesla") })
	query := func() commandCapabilities {
		req := httptest.NewRequest("GET", "/v1/vehicles/1/commands", nil)
		req.Header.Set("Authorization", "Bearer "+s.c.Secret)
		w := httptest.NewRecorder()
		s.PrivateHandler().ServeHTTP(w, req)
		var got commandCapabilities
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &got) != nil {
			t.Fatal("bad capabilities")
		}
		if slices.Contains(got.Commands, "locate") {
			t.Fatal("unsupported boombox advertised")
		}
		return got
	}
	check := func(reason string) {
		t.Helper()
		v := query()
		if v.Available || v.Reason == nil || *v.Reason != reason {
			t.Fatalf("expected %s, got %+v", reason, v)
		}
	}
	check("stub_mode")
	s.c.Mode = "live"
	check("authorization_required")
	authorize(t, store, "https://telemetry.example.com")
	check("command_scope_required")
	tokens := store.tokens()
	tokens.Access = scopeToken("vehicle_cmds", "vehicle_charging_cmds")
	if err := store.saveTokens(tokens); err != nil {
		t.Fatal(err)
	}
	if v := query(); !v.Available || v.Reason != nil {
		t.Fatal("scoped token unavailable")
	}
	tokens.ReauthRequired = true
	_ = store.saveTokens(tokens)
	check("reauthorization_required")
	s.c.Enabled = false
	check("commands_unavailable")
}

func TestCommandScopeMetadata(t *testing.T) {
	for _, tc := range []struct {
		tokens *Tokens
		want   bool
	}{
		{nil, false}, {&Tokens{Access: "opaque"}, false},
		{&Tokens{Access: scopeToken("vehicle_cmds")}, false},
		{&Tokens{Access: scopeToken("vehicle_cmds", "vehicle_charging_cmds")}, true},
		{&Tokens{Access: "opaque", Scope: CommandScopes}, true},
		{&Tokens{Access: scopeToken("vehicle_device_data"), Scope: CommandScopes}, false},
		{&Tokens{Access: "invalid.??.signature", Scope: "vehicle_cmds"}, false},
	} {
		if got := hasCommandScopes(tc.tokens); got != tc.want {
			t.Fatalf("scope readiness %v, wanted %v", got, tc.want)
		}
	}
}

func TestCommandScopeUpgradePreservesExistingConnection(t *testing.T) {
	s, store, up, _ := fixture(t, func(http.ResponseWriter, *http.Request) { t.Error("unexpected upstream") })
	authorize(t, store, up.URL)
	oldAccess := scopeToken("vehicle_device_data")
	oldTokens := store.tokens()
	oldTokens.Access = oldAccess
	_ = store.saveTokens(oldTokens)
	s.oauth.c.Mode = "live"
	link, _, err := s.oauth.Start("7")
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(link)
	if u.Query().Get("scope") != RequestedScopes(s.c) {
		t.Fatal("missing requested command scopes")
	}
	if !s.oauth.Status().Connected {
		t.Fatal("upgrade disconnected read account")
	}
	if result := s.oauth.Complete(context.Background(), "7", u.Query().Get("state"), "", "access_denied"); result.OK {
		t.Fatal("denial accepted")
	}
	if !s.oauth.Status().Connected || store.tokens().Access != oldAccess {
		t.Fatal("denial changed old credentials")
	}
	tokens := store.tokens()
	tokens.Access = scopeToken("vehicle_cmds", "vehicle_charging_cmds")
	_ = store.saveTokens(tokens)
	if _, _, err = s.oauth.Start("7"); err == nil || err.Error.Code != "already_authorized" {
		t.Fatal("unnecessary relink allowed")
	}
}

func TestLiveCommandsRejectMissingScopesBeforeSending(t *testing.T) {
	var sent atomic.Int32
	s, store, up, _ := fixture(t, func(http.ResponseWriter, *http.Request) { sent.Add(1) })
	authorize(t, store, up.URL)
	s.c.Mode = "live"
	w := call(s, "lock", "{}", "scope-test-intent-1")
	assertCode(t, w, 409, "command_scope_required")
	if sent.Load() != 0 || len(store.snapshot().Receipts) != 0 {
		t.Fatal("scope rejection sent/reserved command")
	}
}

func TestAddedClimateCommandMappings(t *testing.T) {
	cases := []struct {
		name, body, upstream string
		params               map[string]any
	}{
		{"seat_heater", `{"heater":4,"level":3}`, "remote_seat_heater_request", map[string]any{"seat_position": 4, "level": 3}},
		{"steering_wheel_heat", `{"on":true}`, "remote_steering_wheel_heater_request", map[string]any{"on": true}},
		{"defrost", `{"on":false}`, "set_preconditioning_max", map[string]any{"on": false}},
	}
	for _, tc := range cases {
		dec := json.NewDecoder(strings.NewReader(tc.body))
		dec.UseNumber()
		var p map[string]any
		_ = dec.Decode(&p)
		c, err := ParseCommand(tc.name, p)
		if err != nil || c.Upstream != tc.upstream || !reflect.DeepEqual(c.Params, tc.params) {
			t.Fatalf("mapping %s: %+v %v", tc.name, c, err)
		}
	}
	for _, tc := range []struct{ name, body string }{
		{"seat_heater", `{"heater":0.5,"level":1}`}, {"seat_heater", `{"heater":0,"level":4}`},
		{"seat_heater", `{"heater":0,"level":"1"}`}, {"seat_heater", `{"heater":0,"level":1,"extra":true}`},
		{"defrost", `{"on":"true"}`}, {"steering_wheel_heat", `{"on":null}`}, {"locate", `{}`},
	} {
		dec := json.NewDecoder(strings.NewReader(tc.body))
		dec.UseNumber()
		var p map[string]any
		_ = dec.Decode(&p)
		if _, err := ParseCommand(tc.name, p); err == nil {
			t.Fatalf("accepted invalid %s %s", tc.name, tc.body)
		}
	}
}

func TestCommandBudgetChargesOnceAndBlocksBeforeUpstream(t *testing.T) {
	var calls atomic.Int32
	s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		reply(w, 200, `{"response":{"result":true}}`)
	})
	authorize(t, store, up.URL)
	tokens := store.tokens()
	tokens.Access = scopeToken("vehicle_cmds", "vehicle_charging_cmds")
	_ = store.saveTokens(tokens)
	s.c.Mode = "live"
	s.c.MonthlyBudgetUSD = .001
	first := call(s, "lock", "{}", "budget-command-intent-1")
	if first.Header().Get("X-Volta-Command-Mode") != "live" {
		t.Fatal("missing execution mode")
	}
	if first.Code != 200 {
		t.Fatalf("first failed: %s", first.Body.String())
	}
	replay := call(s, "lock", "{}", "budget-command-intent-1")
	if replay.Code != 200 || replay.Header().Get("Idempotency-Replayed") != "true" {
		t.Fatal("receipt replay failed")
	}
	assertCode(t, call(s, "lock", "{}", "budget-command-intent-2"), 429, "command_budget_exhausted")
	if calls.Load() != 1 || math.Abs(store.snapshot().Usage.USD-.001) > 1e-9 {
		t.Fatal("replay or blocked command billed")
	}
}

func TestCommandRequestPriceCategories(t *testing.T) {
	var reserved []float64
	s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "wake_up") {
			reply(w, 200, `{"response":{"state":"online"}}`)
			return
		}
		reply(w, 200, `{"response":{"result":true}}`)
	})
	authorize(t, store, up.URL)
	s.fleet.reserve = func(_ context.Context, cost float64) *Result { reserved = append(reserved, cost); return nil }
	_ = s.fleet.send(context.Background(), store.tokens(), testVIN, Command{Name: "lock", Upstream: "door_lock", Params: map[string]any{}})
	_ = s.fleet.wake(context.Background(), store.tokens(), testVIN)
	_, _, _ = s.fleet.commandRequest(context.Background(), "GET", up.URL+"/api/1/vehicles/fixture", "fixture", nil)
	if !reflect.DeepEqual(reserved, []float64{.001, .02, .002}) {
		t.Fatal(fmt.Sprint(reserved))
	}
}

func TestCommandBudgetMonthRollover(t *testing.T) {
	s, store, _, _ := fixture(t, func(http.ResponseWriter, *http.Request) {})
	s.c.Mode = "live"
	s.c.MonthlyBudgetUSD = .001
	_ = store.update(func(d *diskState) { d.Usage = &Usage{Month: month(time.Now().AddDate(0, -1, 0)), USD: 10} })
	if result := s.reserveCommandCall(context.Background(), .001); result != nil {
		t.Fatal(result)
	}
	if store.snapshot().Usage.Month != month(time.Now()) {
		t.Fatal("month not rolled")
	}
}

func TestCommandBudgetPreservesTelemetryReserve(t *testing.T) {
	for _, tc := range []struct {
		name  string
		meter telemetryMeterStatus
		usage float64
		code  string
	}{
		{"unknown accounting", telemetryMeterStatus{}, 0, "command_budget_unavailable"},
		{"combined operating cap", completeMeter(time.Now(), "stop", 25), 2.9995, "command_budget_exhausted"},
		{"available headroom", completeMeter(time.Now(), "ok", 1), 1, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/v1/usage" {
					t.Error("unexpected billable call")
				}
				writeJSON(w, 200, tc.meter)
			})
			s.c.Mode = "live"
			s.c.MonthlyBudgetUSD = 5
			s.c.TotalMonthlyCapUSD = 30
			s.c.TelemetryDeleteReserveUSD = 2
			s.c.TelemetryMeterURL = up.URL + "/v1/usage"
			s.telemetry = NewTelemetryController(s, up.Client())
			_ = store.update(func(d *diskState) { d.Usage = &Usage{Month: month(time.Now()), USD: tc.usage} })
			result := s.reserveCommandCall(context.Background(), .001)
			if tc.code == "" {
				if result != nil {
					t.Fatal(result)
				}
				return
			}
			if result == nil || result.Error.Code != tc.code {
				t.Fatalf("got %+v, wanted %s", result, tc.code)
			}
			if store.snapshot().Usage.USD != tc.usage {
				t.Fatal("refused command used budget")
			}
		})
	}
}

func TestConsentUpgradePreservesNamespaceAndRejectsAccountSwitch(t *testing.T) {
	for _, sameAccount := range []bool{true, false} {
		t.Run(fmt.Sprint(sameAccount), func(t *testing.T) {
			fresh := scopeToken("vehicle_cmds", "vehicle_charging_cmds")
			if !sameAccount {
				b, _ := json.Marshal(map[string]any{"scp": []string{"vehicle_cmds", "vehicle_charging_cmds"}, "sub": "different-synthetic-owner"})
				fresh = "synthetic." + base64.RawURLEncoding.EncodeToString(b) + ".signature"
			}
			s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/token" {
					t.Error("unnecessary region/vehicle request")
				}
				writeJSON(w, 200, map[string]any{"access_token": fresh, "refresh_token": "synthetic-new-refresh", "expires_in": 3600})
			})
			authorize(t, store, up.URL)
			old := store.tokens()
			old.Access = scopeToken("vehicle_device_data")
			old.LinkID = "synthetic-history-link"
			_ = store.saveTokens(old)
			before, _, err := s.oauth.Namespace()
			if err != nil {
				t.Fatal(err)
			}
			s.oauth.c.Mode = "live"
			link, _, err := s.oauth.Start("7")
			if err != nil {
				t.Fatal(err)
			}
			u, _ := url.Parse(link)
			outcome := s.oauth.Complete(context.Background(), "7", u.Query().Get("state"), "synthetic-code", "")
			after, _, err := s.oauth.Namespace()
			if err != nil {
				t.Fatal(err)
			}
			if after != before || store.tokens().FleetBase != old.FleetBase {
				t.Fatal("upgrade changed history or region")
			}
			if sameAccount {
				if !outcome.OK || !hasCommandScopes(store.tokens()) {
					t.Fatal("same account upgrade failed")
				}
			} else if outcome.Error == nil || outcome.Error.Code != "already_authorized" || store.tokens().Access != old.Access {
				t.Fatal("upgrade allowed account switch")
			}
		})
	}
}

func TestBudgetReservationRefusalCanRetrySameIntent(t *testing.T) {
	var sent atomic.Int32
	s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		sent.Add(1)
		reply(w, 200, `{"response":{"result":true}}`)
	})
	authorize(t, store, up.URL)
	blocked := true
	s.fleet.reserve = func(context.Context, float64) *Result {
		if blocked {
			r := failure(503, "command_budget_unavailable", "Unavailable")
			return &r
		}
		return nil
	}
	assertCode(t, call(s, "lock", "{}", "transient-budget-intent"), 503, "command_budget_unavailable")
	if len(store.snapshot().Receipts) != 0 || sent.Load() != 0 {
		t.Fatal("refusal reserved or sent command")
	}
	blocked = false
	if w := call(s, "lock", "{}", "transient-budget-intent"); w.Code != 200 || sent.Load() != 1 {
		t.Fatal("same intent did not recover")
	}
}

func TestWakeWaitPreservesReservationFailure(t *testing.T) {
	s, store, up, _ := fixture(t, func(http.ResponseWriter, *http.Request) { t.Error("reservation failure contacted upstream") })
	authorize(t, store, up.URL)
	for _, code := range []string{"command_budget_unavailable", "command_budget_exhausted", "storage_unavailable", "command_not_sent"} {
		s.fleet.reserve = func(context.Context, float64) *Result { r := failure(503, code, "Refused"); return &r }
		result := s.fleet.waitOnline(context.Background(), store.tokens(), testVIN)
		if result == nil || result.Error.Code != code {
			t.Fatalf("lost %s", code)
		}
	}
}

func TestCommandReservationRespectsDeadlineWhileCollectorBusy(t *testing.T) {
	s, store, _, _ := fixture(t, func(http.ResponseWriter, *http.Request) {})
	s.c.Mode = "live"
	s.c.MonthlyBudgetUSD = 5
	s.collector.mu.Lock()
	defer s.collector.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	result := s.reserveCommandCall(ctx, .001)
	if result == nil || result.Error.Code != "command_not_sent" || store.snapshot().Usage != nil {
		t.Fatal("cancelled reservation sent or charged")
	}
}

func TestReplayedReceiptKeepsOriginalExecutionMode(t *testing.T) {
	s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) { reply(w, 200, `{"response":{"result":true}}`) })
	authorize(t, store, up.URL)
	if w := call(s, "lock", "{}", "stub-to-live-intent"); w.Code != 200 || w.Header().Get("X-Volta-Command-Mode") != "stub" {
		t.Fatal("stub mode missing")
	}
	s.c.Mode = "live"
	w := call(s, "lock", "{}", "stub-to-live-intent")
	if w.Code != 200 || w.Header().Get("X-Volta-Command-Mode") != "stub" || w.Header().Get("Idempotency-Replayed") != "true" {
		t.Fatal("stub receipt upgraded to live execution")
	}
}
