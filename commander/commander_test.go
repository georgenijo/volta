package commander

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const testVIN = "5YJ3E1EA7KF000001" // synthetic, never George's VIN
var testKey = bytes.Repeat([]byte{42}, 32)

func fixture(t *testing.T, handler http.HandlerFunc) (*Service, *Store, *httptest.Server, *bytes.Buffer) {
	t.Helper()
	upstream := httptest.NewServer(handler)
	t.Cleanup(upstream.Close)
	c := Config{Mode: "stub", Enabled: true, Secret: strings.Repeat("fixture-secret-", 3), EncryptionKey: testKey, Vehicles: map[string]string{"1": testVIN}, Audience: upstream.URL, TokenURL: upstream.URL + "/token", AuthorizeURL: upstream.URL + "/authorize", RedirectURI: "http://127.0.0.1:8091/oauth/callback", ProxyURL: upstream.URL, ClientID: "fixture-client", ClientSecret: "fixture-client-secret", RateLimit: 100, WakeTimeout: 50 * time.Millisecond, WakeInterval: time.Millisecond, CommandTimeout: time.Second}
	c.OAuthEnabled = true
	store, err := OpenStore(t.TempDir(), testKey)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	logs := &bytes.Buffer{}
	svc, err := NewService(c, store, upstream.Client(), slog.New(slog.NewJSONHandler(logs, nil)))
	if err != nil {
		t.Fatal(err)
	}
	return svc, store, upstream, logs
}
func authorize(t *testing.T, s *Store, base string) {
	t.Helper()
	if err := s.saveTokens(&Tokens{Access: "fixture-access", Refresh: "fixture-refresh", Expires: time.Now().Add(time.Hour), FleetBase: base}); err != nil {
		t.Fatal(err)
	}
}
func call(s *Service, name, body, key string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "/v1/vehicles/1/commands/"+name, strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+s.c.Secret)
	r.Header.Set("Idempotency-Key", key)
	w := httptest.NewRecorder()
	s.PrivateHandler().ServeHTTP(w, r)
	return w
}
func reply(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, body)
}
func assertCode(t *testing.T, w *httptest.ResponseRecorder, status int, code string) {
	t.Helper()
	var result Result
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if w.Code != status || result.Error == nil || result.Error.Code != code {
		t.Fatalf("got %d %s; want %d %s", w.Code, w.Body.String(), status, code)
	}
}

func TestOAuthPKCEStateDiscoveryAndRefresh(t *testing.T) {
	var verifier, challenge string
	var exchanges, refreshes atomic.Int32
	var base string
	s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/token":
			if err := r.ParseForm(); err != nil {
				t.Error(err)
			}
			if r.Form.Get("grant_type") == "authorization_code" {
				exchanges.Add(1)
				verifier = r.Form.Get("code_verifier")
				sum := sha256.Sum256([]byte(verifier))
				if base64.RawURLEncoding.EncodeToString(sum[:]) != challenge {
					t.Error("PKCE challenge mismatch")
				}
				if r.Form.Get("audience") != base || r.Form.Get("client_secret") != "fixture-client-secret" || r.Form.Get("code") != "fixture-code" {
					t.Error("bad code exchange")
				}
				reply(w, 200, `{"access_token":"new-access","refresh_token":"refresh-1","expires_in":3600}`)
			} else {
				refreshes.Add(1)
				if r.Form.Get("refresh_token") != "refresh-1" {
					t.Error("refresh rotation not used")
				}
				reply(w, 200, `{"access_token":"refreshed-access","refresh_token":"refresh-2","expires_in":3600}`)
			}
		case "/api/1/users/region":
			if r.Header.Get("Authorization") != "Bearer new-access" {
				t.Error("region token missing")
			}
			reply(w, 200, fmt.Sprintf(`{"response":{"region":"stub","fleet_api_base_url":%q}}`, base))
		default:
			t.Errorf("unexpected endpoint %s", r.URL.Path)
		}
	})
	base = up.URL
	link, _, errResult := s.oauth.Start("7")
	if errResult != nil {
		t.Fatal(errResult)
	}
	u, _ := url.Parse(link)
	q := u.Query()
	challenge = q.Get("code_challenge")
	if q.Get("code_challenge_method") != "S256" || q.Get("scope") != RequestedScopes(s.c) || q.Get("state") == "" {
		t.Fatal("incomplete authorization URL")
	}
	bad := s.oauth.Complete(context.Background(), "7", "wrong-state", "fixture-code", "")
	if bad.Status != 400 || exchanges.Load() != 0 {
		t.Fatal("invalid state contacted token server")
	}
	if res := s.oauth.Complete(context.Background(), "8", q.Get("state"), "fixture-code", ""); res.Status != 409 || exchanges.Load() != 0 {
		t.Fatal("another device completed the sign-in", res)
	}
	ok := s.oauth.Complete(context.Background(), "7", q.Get("state"), "fixture-code", "")
	if !ok.OK {
		t.Fatal(ok)
	}
	if res := s.oauth.Complete(context.Background(), "7", q.Get("state"), "fixture-code", ""); !res.OK || exchanges.Load() != 1 {
		t.Fatal("replay re-exchanged the code or lost its outcome")
	}
	if res := s.oauth.Complete(context.Background(), "8", q.Get("state"), "fixture-code", ""); res.Status != 400 || exchanges.Load() != 1 {
		t.Fatal("replay outcome disclosed to another device")
	}
	if _, _, err := s.oauth.Start("7"); err == nil || err.Error.Code != "already_authorized" {
		t.Fatal("account overwrite allowed")
	}
	tokens := store.tokens()
	if tokens.FleetBase != base || tokens.Refresh != "refresh-1" {
		t.Fatal("discovery or token persistence failed")
	}
	tokens.Expires = time.Now().Add(-time.Second)
	if err := store.saveTokens(tokens); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			token, err := s.oauth.Token(context.Background())
			if err != nil || token.Access != "refreshed-access" {
				t.Error("refresh failed", err)
			}
		}()
	}
	wg.Wait()
	if refreshes.Load() != 1 || store.tokens().Refresh != "refresh-2" {
		t.Fatal("concurrent refresh raced")
	}
	data, _ := os.ReadFile(store.path)
	for _, secret := range []string{"new-access", "refresh-1", "refresh-2", "refreshed-access"} {
		if bytes.Contains(data, []byte(secret)) {
			t.Fatal("plaintext tokens on disk")
		}
	}
}

func TestCommandMapping(t *testing.T) {
	cases := []struct{ name, body, path, params string }{
		{"lock", "{}", "command/door_lock", "{}"}, {"unlock", "{}", "command/door_unlock", "{}"}, {"climate_on", "{}", "command/auto_conditioning_start", "{}"}, {"climate_off", "{}", "command/auto_conditioning_stop", "{}"},
		{"set_temps", `{"driverTempC":20.5,"passengerTempC":21}`, "command/set_temps", `{"driver_temp":20.5,"passenger_temp":21}`},
		{"charge_start", "{}", "command/charge_start", "{}"}, {"charge_stop", "{}", "command/charge_stop", "{}"}, {"set_charge_limit", `{"percent":80}`, "command/set_charge_limit", `{"percent":80}`},
		{"open_charge_port", "{}", "command/charge_port_door_open", "{}"}, {"close_charge_port", "{}", "command/charge_port_door_close", "{}"},
		{"actuate_trunk", `{"whichTrunk":"front"}`, "command/actuate_trunk", `{"which_trunk":"front"}`}, {"actuate_trunk", `{"whichTrunk":"rear"}`, "command/actuate_trunk", `{"which_trunk":"rear"}`},
		{"window_control", `{"command":"vent"}`, "command/window_control", `{"command":"vent"}`}, {"window_control", `{"command":"close"}`, "command/window_control", `{"command":"close"}`},
		{"honk", "{}", "command/honk_horn", "{}"}, {"flash", "{}", "command/flash_lights", "{}"}, {"sentry_on", "{}", "command/set_sentry_mode", `{"on":true}`}, {"sentry_off", "{}", "command/set_sentry_mode", `{"on":false}`},
		{"trigger_homelink", `{"latitude":40,"longitude":-73}`, "command/trigger_homelink", `{"lat":40,"lon":-73}`}, {"wake_up", "{}", "wake_up", "{}"},
	}
	for _, tc := range cases {
		t.Run(tc.name+tc.body, func(t *testing.T) {
			var hits atomic.Int32
			s, store, up, logs := fixture(t, func(w http.ResponseWriter, r *http.Request) {
				hits.Add(1)
				if r.Method != "POST" || r.URL.Path != "/api/1/vehicles/"+testVIN+"/"+tc.path || r.Header.Get("Authorization") != "Bearer fixture-access" {
					t.Errorf("incorrect mapping: %s %s", r.Method, r.URL.Path)
				}
				body, _ := io.ReadAll(r.Body)
				var got, want any
				_ = json.Unmarshal(body, &got)
				_ = json.Unmarshal([]byte(tc.params), &want)
				a, _ := json.Marshal(got)
				b, _ := json.Marshal(want)
				if !bytes.Equal(a, b) {
					t.Errorf("params got %s want %s", a, b)
				}
				if tc.name == "wake_up" {
					reply(w, 200, `{"response":{"state":"online"}}`)
				} else {
					reply(w, 200, `{"response":{"result":true}}`)
				}
			})
			authorize(t, store, up.URL)
			res := call(s, tc.name, tc.body, "fixture-request-0001")
			if res.Code != 200 || hits.Load() != 1 {
				t.Fatalf("got %d %s hits=%d", res.Code, res.Body.String(), hits.Load())
			}
			if !strings.Contains(logs.String(), "command_completed") || strings.Contains(logs.String(), "fixture-access") || strings.Contains(logs.String(), testVIN) || strings.Contains(logs.String(), "latitude") {
				t.Fatal("audit missing or contains private data")
			}
		})
	}
}

func TestValidationAndAuthNeverContactFleet(t *testing.T) {
	s, _, _, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) { t.Errorf("validation contacted Fleet: %s", r.URL.Path) })
	for _, tc := range []struct{ name, body, key string }{
		{"erase_user_data", "{}", "fixture-key-00001"}, {"lock", `{"foo":1}`, "fixture-key-00001"}, {"set_temps", `{"driverTempC":14,"passengerTempC":20}`, "fixture-key-00001"}, {"set_temps", `{"driverTempC":"20","passengerTempC":20}`, "fixture-key-00001"},
		{"set_charge_limit", `{"percent":80.5}`, "fixture-key-00001"}, {"set_charge_limit", `{"percent":101}`, "fixture-key-00001"}, {"actuate_trunk", `{"whichTrunk":"side"}`, "fixture-key-00001"}, {"window_control", `{"command":"open"}`, "fixture-key-00001"}, {"trigger_homelink", `{"latitude":91,"longitude":0}`, "fixture-key-00001"},
		{"lock", "null", "fixture-key-00001"}, {"lock", "{} {}", "fixture-key-00001"}, {"set_charge_limit", `{"percent":80,"percent":90}`, "fixture-key-00001"}, {"lock", "{}", "short"}, {"lock", `{"x":"` + strings.Repeat("a", 5000) + `"}`, "fixture-key-00001"},
	} {
		if res := call(s, tc.name, tc.body, tc.key); res.Code != 400 {
			t.Errorf("accepted %s %s: %d %s", tc.name, tc.body, res.Code, res.Body.String())
		}
	}
	r := httptest.NewRequest("POST", "/v1/vehicles/1/commands/lock", strings.NewReader("{}"))
	w := httptest.NewRecorder()
	s.PrivateHandler().ServeHTTP(w, r)
	assertCode(t, w, 401, "unauthorized")
	w = httptest.NewRecorder()
	s.PublicHandler().ServeHTTP(w, r)
	if w.Code != 404 {
		t.Fatal("public command route exposed")
	}
	s.c.Enabled = false
	assertCode(t, call(s, "lock", "{}", "fixture-key-00001"), 501, "commands_unavailable")
}

func TestWakeThenRetry(t *testing.T) {
	var commands, wakes, polls atomic.Int32
	s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/command/door_lock"):
			if commands.Add(1) == 1 {
				reply(w, 500, `{"error":"vehicle unavailable: vehicle is offline or asleep"}`)
			} else {
				reply(w, 200, `{"response":{"result":true}}`)
			}
		case strings.HasSuffix(r.URL.Path, "/wake_up"):
			wakes.Add(1)
			reply(w, 200, `{"response":{"state":"asleep"}}`)
		case r.Method == "GET":
			if polls.Add(1) == 1 {
				reply(w, 200, `{"response":{"state":"asleep"}}`)
			} else {
				reply(w, 200, `{"response":{"state":"online"}}`)
			}
		default:
			t.Error("unexpected wake path")
		}
	})
	authorize(t, store, up.URL)
	res := call(s, "lock", "{}", "fixture-wake-0001")
	if res.Code != 200 || commands.Load() != 2 || wakes.Load() != 1 || polls.Load() != 2 {
		t.Fatalf("wake retry failed %d %s counts=%d/%d/%d", res.Code, res.Body.String(), commands.Load(), wakes.Load(), polls.Load())
	}
}

func TestFleetErrorsNoBlindRetries(t *testing.T) {
	cases := []struct {
		status     int
		body, code string
		httpStatus int
	}{
		{500, `{"error":"vehicle rejected request: your public key has not been paired with the vehicle"}`, "virtual_key_missing", 409},
		{412, `{"error":"key_not_paired"}`, "virtual_key_missing", 409},
		{408, `{"error":"vehicle is offline"}`, "vehicle_offline", 409},
		{200, `{"response":{"result":false,"reason":"not in park"}}`, "command_rejected", 409},
		{401, `{"error":"unauthorized"}`, "reauthorization_required", 409},
		{403, `{"error":"missing scopes"}`, "permission_denied", 403},
		{429, `{"error":"too many requests"}`, "tesla_rate_limited", 429},
		{404, `{"error":"not found"}`, "vehicle_not_found", 404},
		{500, `{"error":"internal server error"}`, "command_outcome_unknown", 502},
		{408, `{"error":"request timeout"}`, "command_outcome_unknown", 502},
		{200, `{"response":{}}`, "command_outcome_unknown", 502},
	}
	for _, tc := range cases {
		t.Run(tc.code+fmt.Sprint(tc.status), func(t *testing.T) {
			var hits atomic.Int32
			s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) { hits.Add(1); reply(w, tc.status, tc.body) })
			authorize(t, store, up.URL)
			assertCode(t, call(s, "honk", "{}", "fixture-error-001"), tc.httpStatus, tc.code)
			if hits.Load() != 1 {
				t.Fatal("blind retry")
			}
			if tc.status == 429 && call(s, "honk", "{}", "fixture-error-001").Header().Get("Retry-After") == "" {
				t.Fatal("missing replay retry-after")
			}
		})
	}
}

func TestWakeTimeoutAndOffline(t *testing.T) {
	for _, state := range []string{"asleep", "offline"} {
		t.Run(state, func(t *testing.T) {
			var commands, wakes atomic.Int32
			s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
				if strings.Contains(r.URL.Path, "/command/") {
					commands.Add(1)
					reply(w, 408, `{"error":"vehicle asleep"}`)
				} else if strings.HasSuffix(r.URL.Path, "/wake_up") {
					wakes.Add(1)
					reply(w, 200, `{"response":{"state":"asleep"}}`)
				} else {
					reply(w, 200, fmt.Sprintf(`{"response":{"state":%q}}`, state))
				}
			})
			authorize(t, store, up.URL)
			assertCode(t, call(s, "lock", "{}", "fixture-timeout-01"), 409, "vehicle_"+state)
			if commands.Load() != 1 || wakes.Load() != 1 {
				t.Fatal("unbounded retry")
			}
		})
	}
}

func TestIdempotencyConcurrentPersistentAndConflict(t *testing.T) {
	var hits atomic.Int32
	s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		reply(w, 200, `{"response":{"result":true}}`)
	})
	authorize(t, store, up.URL)
	// Concurrent requests share a logger backed by a synchronized writer.
	s.audit = slog.New(slog.NewJSONHandler(io.Discard, nil))
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if w := call(s, "actuate_trunk", `{"whichTrunk":"rear"}`, "fixture-concurrent-01"); w.Code != 200 {
				t.Error(w.Body.String())
			}
		}()
	}
	wg.Wait()
	if hits.Load() != 1 {
		t.Fatal("duplicate actuation", hits.Load())
	}
	assertCode(t, call(s, "honk", "{}", "fixture-concurrent-01"), 409, "idempotency_conflict")
	statePath := filepath.Dir(store.path)
	store.Close()
	reopened, err := OpenStore(statePath, testKey)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	s.store = reopened
	s.oauth.store = reopened
	w := call(s, "actuate_trunk", `{"whichTrunk":"rear"}`, "fixture-concurrent-01")
	if w.Code != 200 || w.Header().Get("Idempotency-Replayed") != "true" || hits.Load() != 1 {
		t.Fatal("restart replay failed", w.Code, w.Body.String())
	}
	if err = reopened.update(func(d *diskState) {
		d.Receipts[hash("fixture-pending-01")] = Receipt{Fingerprint: hash("1\nhonk\n{}"), Created: time.Now()}
	}); err != nil {
		t.Fatal(err)
	}
	assertCode(t, call(s, "honk", "{}", "fixture-pending-01"), 409, "command_outcome_unknown")
	if hits.Load() != 1 {
		t.Fatal("pending receipt resubmitted")
	}
}

func TestPersistentRateLimitAndReplayBudget(t *testing.T) {
	var hits atomic.Int32
	s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		reply(w, 200, `{"response":{"result":true}}`)
	})
	s.c.RateLimit = 1
	authorize(t, store, up.URL)
	if call(s, "lock", "{}", "fixture-limit-001").Code != 200 {
		t.Fatal("first denied")
	}
	if call(s, "lock", "{}", "fixture-limit-001").Code != 200 {
		t.Fatal("replay rate limited")
	}
	w := call(s, "lock", "{}", "fixture-limit-002")
	assertCode(t, w, 429, "rate_limited")
	if w.Header().Get("Retry-After") == "" || hits.Load() != 1 {
		t.Fatal("rate limit failed")
	}
	store.Close()
	reopened, err := OpenStore(filepath.Dir(store.path), testKey)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	s.store = reopened
	s.oauth.store = reopened
	assertCode(t, call(s, "lock", "{}", "fixture-limit-002"), 429, "rate_limited")
}

func TestStoreTamperKeyAndSingleWriter(t *testing.T) {
	dir := t.TempDir()
	s, err := OpenStore(dir, testKey)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := OpenStore(dir, testKey); err == nil {
		t.Fatal("second writer allowed")
	}
	authorize(t, s, "http://fixture")
	info, _ := os.Stat(s.path)
	if info.Mode().Perm() != 0600 {
		t.Fatal("insecure state mode")
	}
	s.Close()
	if _, err := OpenStore(dir, bytes.Repeat([]byte{43}, 32)); err == nil {
		t.Fatal("wrong key accepted")
	}
	b, _ := os.ReadFile(filepath.Join(dir, "state.enc"))
	b[len(b)-1] ^= 1
	_ = os.WriteFile(filepath.Join(dir, "state.enc"), b, 0600)
	if _, err := OpenStore(dir, testKey); err == nil {
		t.Fatal("tampered state accepted")
	}
}

func TestRefreshErrorsAndRegionURLAllowlist(t *testing.T) {
	t.Run("refresh denied", func(t *testing.T) {
		s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) { reply(w, 401, `{"error":"login_required"}`) })
		authorize(t, store, up.URL)
		tok := store.tokens()
		tok.Expires = time.Now()
		_ = store.saveTokens(tok)
		_, err := s.oauth.Token(context.Background())
		if err == nil || err.Error.Code != "reauthorization_required" {
			t.Fatal("refresh denial mapping", err)
		}
	})
	t.Run("malicious region", func(t *testing.T) {
		s, store, _, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
			reply(w, 200, `{"response":{"fleet_api_base_url":"https://evil.invalid"}}`)
		})
		authorize(t, store, "")
		tok := store.tokens()
		tok.FleetBase = ""
		_ = store.saveTokens(tok)
		_, err := s.oauth.Token(context.Background())
		if err == nil || err.Error.Code != "region_unavailable" || store.tokens().FleetBase != "" {
			t.Fatal("untrusted region URL accepted", err)
		}
	})
}

func TestConfigStubIsolation(t *testing.T) {
	t.Setenv("COMMANDER_MODE", "stub")
	t.Setenv("COMMANDER_INTERNAL_SECRET", strings.Repeat("s", 32))
	t.Setenv("COMMANDER_ENCRYPTION_KEY", base64.StdEncoding.EncodeToString(testKey))
	t.Setenv("COMMANDER_COMMANDS_ENABLED", "true")
	t.Setenv("COMMANDER_VEHICLES", `{"1":"`+testVIN+`"}`)
	t.Setenv("TESLA_CLIENT_ID", "STUB_ONLY")
	t.Setenv("TESLA_CLIENT_SECRET", "STUB_ONLY")
	t.Setenv("TESLA_REDIRECT_URI", "http://127.0.0.1:8091/oauth/callback")
	t.Setenv("COMMANDER_STUB_URL", "http://127.0.0.1:19090")
	c, err := ConfigFromEnv()
	if err != nil || c.Audience != "http://127.0.0.1:19090" {
		t.Fatal("stub config", err)
	}
	t.Setenv("COMMANDER_STUB_URL", "http://127.0.0.1:19090/")
	if c, err := ConfigFromEnv(); err != nil || c.TokenURL != "http://127.0.0.1:19090/token" {
		t.Fatal("trailing slash not normalized", err)
	}
	t.Setenv("COMMANDER_STUB_URL", NorthAmerica)
	if _, err := ConfigFromEnv(); err == nil {
		t.Fatal("stub can contact real Tesla")
	}
	t.Setenv("COMMANDER_MODE", "live")
	if _, err := ConfigFromEnv(); err == nil {
		t.Fatal("live accepts insecure callback/proxy")
	}
}
