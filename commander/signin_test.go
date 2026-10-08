package commander

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Synthetic values only; the assertions below prove none of them leak.
const (
	fixtureCode   = "SYNTHETIC-CODE-0001"
	fixtureAccess = "SYNTHETIC-ACCESS-0001"
)

func linkFixture(t *testing.T, tokenStatus *atomic.Int32, exchanges *atomic.Int32) (*Service, *Store, *httptest.Server, *strings.Builder) {
	t.Helper()
	var base string
	s, store, up, logs := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/token":
			_ = r.ParseForm()
			if r.Form.Get("grant_type") == "authorization_code" {
				exchanges.Add(1)
			}
			if status := int(tokenStatus.Load()); status != 200 {
				reply(w, status, `{"error":"invalid_grant"}`)
				return
			}
			reply(w, 200, `{"access_token":"`+fixtureAccess+`","refresh_token":"SYNTHETIC-REFRESH","expires_in":3600}`)
		case "/api/1/users/region":
			reply(w, 200, fmt.Sprintf(`{"response":{"fleet_api_base_url":%q}}`, base))
		default:
			reply(w, 404, `{"error":"not_found"}`)
		}
	})
	base = up.URL
	s.c.Enabled, s.oauth.c.Enabled = false, false
	tokenStatus.Store(200)
	out := &strings.Builder{}
	t.Cleanup(func() {
		all := logs.String()
		for _, secret := range []string{fixtureCode, fixtureAccess, "SYNTHETIC-REFRESH", "fixture-client-secret"} {
			if strings.Contains(all, secret) {
				t.Errorf("audit log leaked %q", secret)
			}
		}
	})
	return s, store, up, out
}

func startState(t *testing.T, s *Service, device string) string {
	t.Helper()
	link, _, err := s.oauth.Start(device)
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(link)
	return u.Query().Get("state")
}

func TestSignInSupersedeCancelDenialAndRestart(t *testing.T) {
	var status, exchanges atomic.Int32
	s, store, _, _ := linkFixture(t, &status, &exchanges)

	first := startState(t, s, "7")
	second := startState(t, s, "7")
	if r := s.oauth.Complete(context.Background(), "7", first, fixtureCode, ""); r.Status != 400 || r.Error.Code != "oauth_state_invalid" {
		t.Fatal("superseded state accepted", r)
	}
	if s.oauth.Cancel("8"); store.snapshot().Link == nil {
		t.Fatal("another device cancelled the sign-in")
	}
	if s.oauth.Cancel("7"); store.snapshot().Link != nil {
		t.Fatal("cancel kept the pending sign-in")
	}
	if r := s.oauth.Complete(context.Background(), "7", second, fixtureCode, ""); r.Status != 400 {
		t.Fatal("cancelled state accepted")
	}

	denied := startState(t, s, "7")
	if r := s.oauth.Complete(context.Background(), "7", denied, "", "access_denied"); r.Error == nil || r.Error.Code != "oauth_denied" {
		t.Fatal("denial not reported", r)
	}
	if r := s.oauth.Complete(context.Background(), "7", denied, fixtureCode, ""); r.Error == nil || r.Error.Code != "oauth_denied" || exchanges.Load() != 0 {
		t.Fatal("denied state reused for an exchange", r)
	}

	// A sign-in started before a restart finishes after it.
	pending := startState(t, s, "7")
	dir := filepath.Dir(store.path)
	store.Close()
	reopened, err := OpenStore(dir, testKey)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { reopened.Close() })
	s.store, s.oauth.store = reopened, reopened
	if r := s.oauth.Complete(context.Background(), "7", pending, fixtureCode, ""); !r.OK {
		t.Fatal("restart lost the pending sign-in", r)
	}
	if st := s.oauth.Status(); !st.Connected || st.LinkPending {
		t.Fatal("status after link", st)
	}
	snap, _ := json.Marshal(reopened.snapshot().Link)
	if strings.Contains(string(snap), pending) {
		t.Fatal("raw state persisted")
	}
}

func TestRejectedCodeAndRevokedRefreshRequireReauth(t *testing.T) {
	var status, exchanges atomic.Int32
	s, store, up, _ := linkFixture(t, &status, &exchanges)
	state := startState(t, s, "7")
	status.Store(400)
	if r := s.oauth.Complete(context.Background(), "7", state, fixtureCode, ""); r.Error == nil || r.Error.Code != "oauth_code_rejected" || store.tokens() != nil {
		t.Fatal("rejected code linked an account", r)
	}

	if err := store.saveTokens(&Tokens{Access: "old", Refresh: "old", Expires: time.Now(), FleetBase: up.URL}); err != nil {
		t.Fatal(err)
	}
	status.Store(401)
	if _, err := s.oauth.Token(context.Background()); err == nil || err.Error.Code != "reauthorization_required" {
		t.Fatal("revoked refresh not detected")
	}
	before := exchanges.Load()
	status.Store(200)
	if _, err := s.oauth.Token(context.Background()); err == nil || err.Error.Code != "reauthorization_required" {
		t.Fatal("revoked token retried")
	}
	if st := s.oauth.Status(); st.Connected || !st.NeedsReauth {
		t.Fatal("status did not show reauth", st)
	}
	// Reconnecting is allowed without a manual disconnect.
	if r := s.oauth.Complete(context.Background(), "7", startState(t, s, "7"), fixtureCode, ""); !r.OK || exchanges.Load() != before+1 {
		t.Fatal("relink failed", r)
	}
	if st := s.oauth.Status(); !st.Connected || st.NeedsReauth {
		t.Fatal("relink status", st)
	}
}

func TestFailedExchangeIsTerminalAndSuccessReplays(t *testing.T) {
	var status, exchanges atomic.Int32
	s, store, _, _ := linkFixture(t, &status, &exchanges)
	state := startState(t, s, "7")
	status.Store(503)
	r := s.oauth.Complete(context.Background(), "7", state, fixtureCode, "")
	if r.Status != 400 || r.Error == nil || r.Error.Code != "oauth_link_failed" || store.tokens() != nil {
		t.Fatal("consumed failed exchange was retryable", r)
	}
	// Tesla recovers, but the code and link are spent: retrying never re-exchanges.
	status.Store(200)
	if r := s.oauth.Complete(context.Background(), "7", state, fixtureCode, ""); r.Status != 400 || r.Error == nil || r.Error.Code != "oauth_link_failed" || exchanges.Load() != 1 {
		t.Fatal("retry of a consumed exchange", r, exchanges.Load())
	}
	// A fresh sign-in works, and its success replays without another exchange,
	// including after a restart.
	fresh := startState(t, s, "7")
	if r := s.oauth.Complete(context.Background(), "7", fresh, fixtureCode, ""); !r.OK || exchanges.Load() != 2 {
		t.Fatal("fresh sign-in after failure", r)
	}
	dir := filepath.Dir(store.path)
	store.Close()
	reopened, err := OpenStore(dir, testKey)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { reopened.Close() })
	s.store, s.oauth.store = reopened, reopened
	if r := s.oauth.Complete(context.Background(), "7", fresh, fixtureCode, ""); !r.OK || exchanges.Load() != 2 {
		t.Fatal("successful retry was not idempotent across restart", r, exchanges.Load())
	}
}

func privateCall(s *Service, method, path, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+s.c.Secret)
	w := httptest.NewRecorder()
	s.PrivateHandler().ServeHTTP(w, r)
	return w
}

func TestPrivateSignInRoutesNeverExposeSecrets(t *testing.T) {
	var status, exchanges atomic.Int32
	s, _, _, _ := linkFixture(t, &status, &exchanges)
	w := privateCall(s, "POST", "/oauth/start", `{"deviceId":"7"}`)
	var start struct {
		URL     string `json:"authorizationUrl"`
		Scheme  string `json:"callbackScheme"`
		Expires string `json:"expiresAt"`
	}
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &start) != nil || start.Scheme != "volta" || start.Expires == "" {
		t.Fatal(w.Code, w.Body.String())
	}
	u, _ := url.Parse(start.URL)
	if u.Query().Get("scope") != ReadScopes || u.Query().Get("redirect_uri") != s.c.RedirectURI || strings.Contains(start.URL, "client_secret") {
		t.Fatal("authorization URL", u.Query())
	}
	for _, body := range []string{`{"deviceId":7}`, `{"deviceId":"7","extra":"x"}`, `{"deviceId":"7","deviceId":"8"}`, `[]`} {
		if w := privateCall(s, "POST", "/oauth/start", body); w.Code != 400 {
			t.Fatal("accepted", body)
		}
	}
	if w := privateCall(s, "POST", "/oauth/start", `{"deviceId":"x y"}`); w.Code != 400 {
		t.Fatal("accepted invalid device")
	}
	state := u.Query().Get("state")
	w = privateCall(s, "POST", "/oauth/complete", fmt.Sprintf(`{"deviceId":"7","state":%q,"code":%q}`, state, fixtureCode))
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"connected":true`) {
		t.Fatal(w.Code, w.Body.String())
	}
	w = privateCall(s, "GET", "/oauth/status", "")
	for _, secret := range []string{fixtureAccess, "SYNTHETIC-REFRESH", state, fixtureCode} {
		if strings.Contains(w.Body.String(), secret) {
			t.Fatal("status leaked a credential")
		}
	}
	var view statusView
	if err := json.Unmarshal(w.Body.Bytes(), &view); err != nil || !view.Available || !view.Connected || view.Budget.MonthlyLimitUSD != s.c.MonthlyBudgetUSD {
		t.Fatal(w.Body.String())
	}
	if w := privateCall(s, "POST", "/oauth/cancel", `{"deviceId":"7"}`); w.Code != 200 {
		t.Fatal("cancel", w.Code)
	}
	r := httptest.NewRequest("GET", "/oauth/status", nil)
	w = httptest.NewRecorder()
	s.PrivateHandler().ServeHTTP(w, r)
	assertCode(t, w, 401, "unauthorized")
}

func TestCallbackBounceIsStatelessAndStrict(t *testing.T) {
	s, _, _, logs := fixture(t, func(w http.ResponseWriter, r *http.Request) { t.Error("bounce contacted upstream") })
	s.c.RedirectURI = "https://example.com/volta/oauth/callback"
	h := s.PublicHandler()
	get := func(target string) *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", target, nil))
		return w
	}
	w := get("/volta/oauth/callback?code=" + fixtureCode + "&state=s1&issuer=https%3A%2F%2Fauth.example&locale=en")
	if w.Code != 302 || w.Header().Get("Location") != "volta://tesla-callback?code="+fixtureCode+"&state=s1" {
		t.Fatal(w.Code, w.Header().Get("Location"))
	}
	if w.Header().Get("Cache-Control") != "no-store" || w.Header().Get("Referrer-Policy") != "no-referrer" || w.Header().Get("X-Content-Type-Options") != "nosniff" || w.Body.Len() != 0 {
		t.Fatal("bounce headers or body", w.Header(), w.Body.String())
	}
	if w := get("/volta/oauth/callback?error=access_denied&state=s1"); w.Code != 302 || w.Header().Get("Location") != "volta://tesla-callback?error=access_denied&state=s1" {
		t.Fatal("denial bounce", w.Header().Get("Location"))
	}
	for _, bad := range []string{"", "?code=a", "?state=s", "?state=s&code=a&error=b", "?state=s&state=t&code=a", "?state=s&code=a&code=b", "?state=&code=a", "?state=s&code=", "?state=s&code=%zz", "?state=s&code=" + strings.Repeat("a", 5000)} {
		if w := get("/volta/oauth/callback" + bad); w.Code != 400 || w.Header().Get("Location") != "" {
			t.Fatal("accepted", bad)
		}
	}
	if w := get("/oauth/callback?state=s&code=a"); w.Code != 404 {
		t.Fatal("old callback path still served")
	}
	r := httptest.NewRequest("POST", "/volta/oauth/callback?state=s&code=a", nil)
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 405 && w.Code != 404 {
		t.Fatal("POST bounce", w.Code)
	}
	if strings.Contains(logs.String(), fixtureCode) {
		t.Fatal("bounce logged the code")
	}
}

func collectorFixture(t *testing.T, handler http.HandlerFunc) (*Service, *Store, *httptest.Server) {
	t.Helper()
	s, store, up, _ := fixture(t, handler)
	s.c.CollectorEnabled = true
	s.c.CollectorSecret = strings.Repeat("collector-", 4)
	s.c.MonthlyBudgetUSD, s.c.CallCostUSD, s.c.CacheTTL = 20, 1.0/500, time.Minute
	return s, store, up
}

func collect(s *Service, method, target, secret string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, target, nil)
	if secret != "" {
		r.Header.Set("Authorization", "Bearer "+secret)
	}
	w := httptest.NewRecorder()
	s.CollectorHandler().ServeHTTP(w, r)
	return w
}

func TestCollectorAllowlistCacheAndBudget(t *testing.T) {
	var calls atomic.Int32
	var lastQuery string
	s, store, up := collectorFixture(t, func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Method != "GET" || r.Header.Get("Authorization") != "Bearer fixture-access" {
			t.Errorf("collector sent %s with wrong credentials", r.Method)
		}
		lastQuery = r.URL.RawQuery
		switch r.URL.Path {
		case "/api/1/products":
			reply(w, 200, `{"response":[{"id":1,"vehicle_id":2,"vin":"`+testVIN+`"}],"count":1}`)
		default:
			reply(w, 200, `{"response":{"state":"online"}}`)
		}
	})
	secret := s.c.CollectorSecret
	if w := collect(s, "GET", "/api/1/products", ""); w.Code != 401 {
		t.Fatal("unauthenticated collector call")
	}
	if w := collect(s, "GET", "/api/1/products", s.c.Secret); w.Code != 401 {
		t.Fatal("internal secret accepted by collector")
	}
	if w := collect(s, "POST", "/oauth2/v3/token", secret); w.Code != 200 || strings.Contains(w.Body.String(), "fixture") {
		t.Fatal("token emulation", w.Body.String())
	}
	if w := collect(s, "GET", "/api/1/products", secret); w.Code != 200 || !strings.Contains(w.Body.String(), `"response":[]`) || calls.Load() != 0 {
		t.Fatal("unlinked products", w.Body.String())
	}
	authorize(t, store, up.URL)
	for _, target := range []string{"/api/1/vehicles/1/wake_up", "/api/1/vehicles/1/command/honk_horn", "/api/1/vehicles/1/vehicle_data?endpoints=location_data&x=1", "/api/1/vehicles/1/vehicle_data?endpoints=secret_state", "/api/1/users/me", "/api/1/vehicles/../users/me", "/api/1/products?x=1"} {
		if w := collect(s, "GET", target, secret); w.Code != 404 {
			t.Fatal("allowed", target, w.Code)
		}
	}
	if w := collect(s, "POST", "/api/1/vehicles/1/wake_up", secret); w.Code != 404 {
		t.Fatal("POST allowed")
	}
	if calls.Load() != 0 {
		t.Fatal("denied request reached Tesla")
	}
	if w := collect(s, "GET", "/api/1/products", secret); w.Code != 200 || !strings.Contains(w.Body.String(), testVIN) {
		t.Fatal("products", w.Body.String())
	}
	s.collector.last = time.Time{} // let the next paced read through
	w := collect(s, "GET", "/api/1/vehicles/1/vehicle_data?endpoints=charge_state%3Blocation_data", secret)
	if w.Code != 200 || lastQuery != "endpoints=charge_state%3Blocation_data" {
		t.Fatal("vehicle data", w.Code, lastQuery)
	}
	if w := collect(s, "GET", "/api/1/products", secret); w.Code != 200 || calls.Load() != 2 {
		t.Fatal("cache not used", calls.Load())
	}
	if u := store.snapshot().Usage; u == nil || u.Calls != 2 || u.Month != month(time.Now()) {
		t.Fatal("usage not recorded", u)
	}
	// At the cap: cached answers keep TeslaMate quiet, uncached reads stop.
	_ = store.update(func(d *diskState) { d.Usage.USD = 20 })
	if w := collect(s, "GET", "/api/1/vehicles/1", secret); w.Code != 429 || w.Header().Get("Retry-After") == "" || calls.Load() != 2 {
		t.Fatal("budget not enforced", w.Code)
	}
	if !s.budget().Paused {
		t.Fatal("budget status not paused")
	}
	s.collector.cache["/api/1/products"] = cached{status: 200, body: []byte(`{}`), at: time.Now().Add(-time.Hour)}
	if w := collect(s, "GET", "/api/1/products", secret); w.Code != 200 || calls.Load() != 2 {
		t.Fatal("stale cache not served at cap")
	}
	_ = store.update(func(d *diskState) { d.Usage.Month = "2000-01" })
	if s.budget().Paused || s.budget().SpentUSD != 0 {
		t.Fatal("budget did not reset for a new month")
	}
}

func TestCollectorUnauthorizedUpstreamRefreshesQuietly(t *testing.T) {
	var refreshes atomic.Int32
	s, store, up := collectorFixture(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/token":
			refreshes.Add(1)
			reply(w, 200, `{"access_token":"rotated","refresh_token":"r2","expires_in":3600}`)
		case r.Header.Get("Authorization") == "Bearer rotated":
			reply(w, 200, `{"response":{"state":"asleep"}}`)
		default:
			reply(w, 401, `{"error":"token expired"}`)
		}
	})
	authorize(t, store, up.URL)
	if w := collect(s, "GET", "/api/1/vehicles/1", s.c.CollectorSecret); w.Code != 503 {
		t.Fatal("401 passed to TeslaMate", w.Code)
	}
	s.collector.last = time.Time{}
	if w := collect(s, "GET", "/api/1/vehicles/1", s.c.CollectorSecret); w.Code != 200 || refreshes.Load() != 1 {
		t.Fatal("did not refresh after 401", w.Code, refreshes.Load())
	}
}

// accountFixture links real accounts through Start/Complete. Each code
// exchange issues the next synthetic account; products names it by token.
func accountFixture(t *testing.T, products http.HandlerFunc) (*Service, *atomic.Int32) {
	t.Helper()
	var issued, upstream atomic.Int32
	var base string
	s, _, up := collectorFixture(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/token":
			n := issued.Add(1)
			reply(w, 200, fmt.Sprintf(`{"access_token":"SYNTHETIC-ACCESS-%c","refresh_token":"SYNTHETIC-REFRESH","expires_in":3600}`, 'A'+n-1))
		case "/api/1/users/region":
			reply(w, 200, fmt.Sprintf(`{"response":{"fleet_api_base_url":%q}}`, base))
		default:
			upstream.Add(1)
			products(w, r)
		}
	})
	base = up.URL
	s.c.Enabled, s.oauth.c.Enabled = false, false
	return s, &upstream
}

func linkAccount(t *testing.T, s *Service) {
	t.Helper()
	if r := s.oauth.Complete(context.Background(), "7", startState(t, s, "7"), fixtureCode, ""); !r.OK {
		t.Fatal("link failed", r)
	}
}

func productsFor(w http.ResponseWriter, r *http.Request) {
	account := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer SYNTHETIC-ACCESS-")
	reply(w, 200, `{"response":[{"id":1,"vin":"SYNTHETIC-VIN-`+account+`"}],"count":1}`)
}

func TestCollectorNeverServesPreviousAccount(t *testing.T) {
	s, upstream := accountFixture(t, productsFor)
	secret := s.c.CollectorSecret
	linkAccount(t, s)
	if w := collect(s, "GET", "/api/1/products", secret); !strings.Contains(w.Body.String(), "SYNTHETIC-VIN-A") {
		t.Fatal("account A products", w.Body.String())
	}
	if r := s.oauth.Disconnect(); !r.OK {
		t.Fatal(r)
	}
	if w := collect(s, "GET", "/api/1/products", secret); w.Code != 200 || !strings.Contains(w.Body.String(), `"response":[]`) {
		t.Fatal("disconnected collector served account A", w.Body.String())
	}
	linkAccount(t, s)
	// Within A's cache TTL and pacing window, B must still be read fresh.
	w := collect(s, "GET", "/api/1/products", secret)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "SYNTHETIC-VIN-B") || strings.Contains(w.Body.String(), "SYNTHETIC-VIN-A") || upstream.Load() != 2 {
		t.Fatal("account B got account A's products", w.Body.String(), upstream.Load())
	}
}

func TestCollectorDropsReplyFromReplacedAccount(t *testing.T) {
	inFlight, release := make(chan struct{}), make(chan struct{})
	s, upstream := accountFixture(t, func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.Header.Get("Authorization"), "-A") {
			close(inFlight)
			<-release
		}
		productsFor(w, r)
	})
	secret := s.c.CollectorSecret
	linkAccount(t, s)
	done := make(chan *httptest.ResponseRecorder)
	go func() { done <- collect(s, "GET", "/api/1/products", secret) }()
	<-inFlight
	if r := s.oauth.Disconnect(); !r.OK {
		t.Fatal(r)
	}
	linkAccount(t, s)
	close(release)
	if w := <-done; w.Code != 503 || strings.Contains(w.Body.String(), "SYNTHETIC-VIN") {
		t.Fatal("in-flight reply from account A returned", w.Code, w.Body.String())
	}
	if w := collect(s, "GET", "/api/1/products", secret); !strings.Contains(w.Body.String(), "SYNTHETIC-VIN-B") || upstream.Load() != 2 {
		t.Fatal("account A reply was cached for B", w.Body.String(), upstream.Load())
	}
}

func TestCollectorPacesFailedReads(t *testing.T) {
	var calls atomic.Int32
	status := atomic.Int32{}
	status.Store(403)
	s, store, up := collectorFixture(t, func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		reply(w, int(status.Load()), `{"error":"synthetic"}`)
	})
	authorize(t, store, up.URL)
	secret := s.c.CollectorSecret
	for range 5 {
		if w := collect(s, "GET", "/api/1/products", secret); w.Code != 403 {
			t.Fatal("billed failure not reused", w.Code)
		}
	}
	if calls.Load() != 1 {
		t.Fatal("repeated failures each billed", calls.Load())
	}
	// A different read inside the pacing window waits instead of calling Tesla.
	w := collect(s, "GET", "/api/1/vehicles/1", secret)
	retry := w.Header().Get("Retry-After")
	if w.Code != 429 || retry == "" || retry == "0" || calls.Load() != 1 {
		t.Fatal("uncached read bypassed pacing", w.Code, retry, calls.Load())
	}
	// Even after the cache TTL, failures cannot re-poll faster than pacing.
	s.collector.cache["/api/1/products"] = cached{status: 403, body: []byte(`{}`), at: time.Now().Add(-time.Hour)}
	if w := collect(s, "GET", "/api/1/products", secret); w.Code != 403 || calls.Load() != 1 {
		t.Fatal("expired failure re-polled inside pacing", w.Code, calls.Load())
	}
	// Unbilled 5xx replies are never cached but still start the pacing window.
	status.Store(503)
	s.collector.last = time.Time{}
	if w := collect(s, "GET", "/api/1/vehicles/1", secret); w.Code != 503 || calls.Load() != 2 {
		t.Fatal("5xx not passed through", w.Code)
	}
	if w := collect(s, "GET", "/api/1/vehicles/1", secret); w.Code != 429 || calls.Load() != 2 {
		t.Fatal("5xx retry bypassed pacing", w.Code, calls.Load())
	}
	if u := store.snapshot().Usage; u == nil || u.Calls != 2 {
		t.Fatal("ledger does not match upstream calls", u)
	}
}

// teslaMateSim drives the collector the way pinned TeslaMate v4.3.0 polls with
// streaming off (vehicle.ex fetch_with_unreachable_assumption and
// fetch_with_reachable_assumption): one fetch reads first, then second only
// if first's reply calls for it, and a 429 reschedules the whole fetch after
// Retry-After. Time is simulated; upstream counts calls per path.
type teslaMateSim struct {
	t        *testing.T
	s        *Service
	now      time.Time
	upstream map[string]int
	mu       sync.Mutex
}

func newTeslaMateSim(t *testing.T, vehicle func(path string) (int, string)) *teslaMateSim {
	t.Helper()
	sim := &teslaMateSim{t: t, now: time.Date(2026, 10, 10, 0, 0, 0, 0, time.UTC), upstream: map[string]int{}}
	s, store, up := collectorFixture(t, func(w http.ResponseWriter, r *http.Request) {
		sim.mu.Lock()
		sim.upstream[r.URL.Path]++
		sim.mu.Unlock()
		status, body := vehicle(r.URL.Path)
		reply(w, status, body)
	})
	s.c.MonthlyBudgetUSD = 10 // the operator-selected budget
	s.collector.clock = func() time.Time { return sim.now }
	authorize(t, store, up.URL)
	sim.s = s
	return sim
}

func (sim *teslaMateSim) get(path string) *httptest.ResponseRecorder {
	return collect(sim.s, "GET", path, sim.s.c.CollectorSecret)
}

func (sim *teslaMateSim) calls(path string) int {
	sim.mu.Lock()
	defer sim.mu.Unlock()
	return sim.upstream[path]
}

const simData = "/vehicle_data?endpoints=charge_state%3Bclimate_state%3Bclosures_state%3Bdrive_state%3Bgui_settings%3Blocation_data%3Bvehicle_config%3Bvehicle_state%3Bvehicle_data_combo"

// fetch runs one TeslaMate fetch and returns the delay before the next one.
func (sim *teslaMateSim) fetch(first, second string, needSecond func(*httptest.ResponseRecorder) bool) (time.Duration, bool) {
	w := sim.get(first)
	if w.Code == 200 || w.Code == 408 {
		if !needSecond(w) {
			return 30 * time.Second, false
		}
		w = sim.get(second)
	}
	if w.Code == 429 {
		retry, err := strconv.Atoi(w.Header().Get("Retry-After"))
		if err != nil || retry < 1 {
			sim.t.Fatal("429 without Retry-After", w.Header())
		}
		return time.Duration(retry) * time.Second, false
	}
	return 30 * time.Second, w.Code == 200 || w.Code == 408
}

func TestCollectorLetsTeslaMateReachVehicleData(t *testing.T) {
	sim := newTeslaMateSim(t, func(path string) (int, string) {
		if strings.HasSuffix(path, "/vehicle_data") {
			return 200, `{"response":{"state":"online","drive_state":{}}}`
		}
		return 200, `{"response":{"state":"online"}}`
	})
	start, interval := sim.now, sim.s.pacing(sim.now, Usage{})
	online := func(w *httptest.ResponseRecorder) bool { return strings.Contains(w.Body.String(), `"online"`) }
	completed := 0
	for sim.now.Before(start.Add(6 * time.Hour)) {
		wait, ok := sim.fetch("/api/1/vehicles/1", "/api/1/vehicles/1"+simData, online)
		if ok {
			completed++
		}
		sim.now = sim.now.Add(wait)
	}
	data, summary := sim.calls("/api/1/vehicles/1/vehicle_data"), sim.calls("/api/1/vehicles/1")
	t.Logf("6h at $10: interval=%s summary=%d vehicle_data=%d completed=%d", interval, summary, data, completed)
	if data == 0 || completed == 0 {
		t.Fatalf("vehicle_data starved: summary=%d vehicle_data=%d completed=%d", summary, data, completed)
	}
	// Dependent reads share the budget: never more calls than the paced rate.
	if total, limit := data+summary, int(6*time.Hour/interval)+2; total > limit {
		t.Fatalf("spent %d calls in 6h, pacing allows %d", total, limit)
	}
	if u := sim.s.store.snapshot().Usage; u == nil || u.Calls != data+summary {
		t.Fatal("ledger does not match upstream calls", u)
	}
}

func TestCollectorLetsTeslaMateSeeVehicleFallAsleep(t *testing.T) {
	sim := newTeslaMateSim(t, func(path string) (int, string) {
		if strings.HasSuffix(path, "/vehicle_data") {
			return 408, `{"error":"vehicle unavailable: vehicle is offline or asleep"}`
		}
		return 200, `{"response":{"state":"asleep"}}`
	})
	unavailable := func(w *httptest.ResponseRecorder) bool { return w.Code == 408 }
	sawAsleep := false
	for start := sim.now; !sawAsleep && sim.now.Before(start.Add(6*time.Hour)); {
		wait, ok := sim.fetch("/api/1/vehicles/1"+simData, "/api/1/vehicles/1", unavailable)
		sawAsleep = ok && sim.calls("/api/1/vehicles/1") > 0
		sim.now = sim.now.Add(wait)
	}
	t.Logf("vehicle_data=%d summary=%d", sim.calls("/api/1/vehicles/1/vehicle_data"), sim.calls("/api/1/vehicles/1"))
	if !sawAsleep {
		t.Fatalf("summary starved after vehicle_data 408: vehicle_data=%d summary=%d", sim.calls("/api/1/vehicles/1/vehicle_data"), sim.calls("/api/1/vehicles/1"))
	}
}

func TestCollectorSharesSlotsAcrossVehicles(t *testing.T) {
	sim := newTeslaMateSim(t, func(path string) (int, string) { return 200, `{"response":{"state":"asleep"}}` })
	// Both asleep cars poll every 30s; vehicle 1 always asks first.
	for start := sim.now; sim.now.Before(start.Add(6 * time.Hour)); sim.now = sim.now.Add(30 * time.Second) {
		sim.get("/api/1/vehicles/1")
		sim.get("/api/1/vehicles/2")
	}
	one, two := sim.calls("/api/1/vehicles/1"), sim.calls("/api/1/vehicles/2")
	t.Logf("6h at $10: vehicle1=%d vehicle2=%d", one, two)
	if two == 0 || one-two > 1 || two-one > 1 {
		t.Fatalf("unfair slots: vehicle1=%d vehicle2=%d", one, two)
	}
}

func TestCollectorFollowUpStaysWithinBudget(t *testing.T) {
	var status atomic.Int32
	status.Store(200)
	sim := newTeslaMateSim(t, func(string) (int, string) { return int(status.Load()), `{"response":{"state":"online"}}` })
	interval := sim.s.pacing(sim.now, Usage{})
	expect := func(path string, code int) {
		t.Helper()
		if w := sim.get(path); w.Code != code {
			t.Fatalf("%s: got %d, want %d", path, w.Code, code)
		}
	}
	expect("/api/1/vehicles/1", 200)
	expect("/api/1/vehicles/2", 429) // another vehicle cannot join the cycle
	expect("/api/1/vehicles/1"+simData, 200)
	expect("/api/1/vehicles/1/vehicle_data", 429) // one dependent read per cycle
	// Two calls billed: the next cycle waits two paced intervals.
	sim.now = sim.now.Add(interval + time.Second)
	expect("/api/1/vehicles/1/vehicle_data", 429)
	sim.now = sim.now.Add(interval)
	expect("/api/1/vehicles/2", 200)
	// The dependent read must follow within the window.
	sim.now = sim.now.Add(followUpWindow)
	expect("/api/1/vehicles/2"+simData, 429)
	// An unanswered read cannot lead to a dependent one.
	sim.now = sim.now.Add(3 * interval)
	status.Store(503)
	expect("/api/1/vehicles/1/vehicle_data", 503)
	status.Store(200)
	expect("/api/1/vehicles/1/vehicle_data?endpoints=location_data", 429)
	if total, u := sim.calls("/api/1/vehicles/1")+sim.calls("/api/1/vehicles/1/vehicle_data")+sim.calls("/api/1/vehicles/2"), sim.s.store.snapshot().Usage; total != 4 || u.Calls != 4 {
		t.Fatal("upstream calls", total, u.Calls)
	}
}

func TestPacingSpreadsRemainingBudget(t *testing.T) {
	s := &Service{c: Config{MonthlyBudgetUSD: 20, CallCostUSD: 1.0 / 500, CacheTTL: time.Minute}}
	now := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	got := s.pacing(now, Usage{})
	if want := 31 * 24 * time.Hour / 10000; got != want {
		t.Fatal(got, want)
	}
	if got := s.pacing(now, Usage{USD: 19.999}); got != 31*24*time.Hour {
		t.Fatal("exhausted pacing", got)
	}
	s.c.MonthlyBudgetUSD = 1000
	if s.pacing(now, Usage{}) != time.Minute {
		t.Fatal("cache TTL floor")
	}
}

func TestConfigRedirectSecretFileAndCollector(t *testing.T) {
	t.Setenv("COMMANDER_MODE", "stub")
	t.Setenv("COMMANDER_INTERNAL_SECRET", strings.Repeat("s", 32))
	t.Setenv("COMMANDER_ENCRYPTION_KEY", base64.StdEncoding.EncodeToString(testKey))
	t.Setenv("COMMANDER_OAUTH_ENABLED", "true")
	t.Setenv("TESLA_CLIENT_ID", "STUB_ONLY")
	t.Setenv("TESLA_CLIENT_SECRET", "")
	file := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(file, []byte("STUB$SECRET'\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TESLA_CLIENT_SECRET_FILE", file)
	t.Setenv("TESLA_REDIRECT_URI", "https://example.com/volta/oauth/callback")
	c, err := ConfigFromEnv()
	if err != nil || c.ClientSecret != "STUB$SECRET'" || c.CollectorEnabled || c.MonthlyBudgetUSD != 20 || c.CacheTTL != time.Minute {
		t.Fatal("config", err)
	}
	if strings.Contains(err2str(err), "STUB") {
		t.Fatal("error leaked secret")
	}
	for _, bad := range []string{"https://example.com/volta/oauth/callback?x=1", "https://example.com/volta/../callback", "https://example.com/", "https://example.com/volta/oauth/callback/", "http://example.com/volta/oauth/callback", "https://user@example.com/cb", "https://example.com/cb#f", "volta://tesla-callback"} {
		t.Setenv("TESLA_REDIRECT_URI", bad)
		if _, err := ConfigFromEnv(); err == nil {
			t.Fatal("accepted redirect", bad)
		}
	}
	t.Setenv("TESLA_REDIRECT_URI", "https://example.com/volta/oauth/callback")
	t.Setenv("TESLA_CLIENT_SECRET", "both")
	if _, err := ConfigFromEnv(); err == nil {
		t.Fatal("accepted both secret sources")
	}
	t.Setenv("TESLA_CLIENT_SECRET", "")
	_ = os.WriteFile(file, []byte("one\ntwo\n"), 0600)
	if _, err := ConfigFromEnv(); err == nil {
		t.Fatal("accepted multi-line secret file")
	}
	_ = os.WriteFile(file, []byte("STUB_ONLY\n"), 0600)
	t.Setenv("COMMANDER_COLLECTOR_ENABLED", "true")
	t.Setenv("COMMANDER_COLLECTOR_SECRET", strings.Repeat("s", 32))
	if _, err := ConfigFromEnv(); err == nil {
		t.Fatal("collector reused the internal secret")
	}
	t.Setenv("COMMANDER_COLLECTOR_SECRET", strings.Repeat("c", 32))
	t.Setenv("COMMANDER_MONTHLY_BUDGET_USD", "-1")
	if _, err := ConfigFromEnv(); err == nil {
		t.Fatal("negative budget")
	}
	t.Setenv("COMMANDER_MONTHLY_BUDGET_USD", "35")
	if c, err := ConfigFromEnv(); err != nil || !c.CollectorEnabled || c.MonthlyBudgetUSD != 35 || RequestedScopes(c) != ReadScopes {
		t.Fatal("collector config", err)
	}
	// Live read-only collection runs without the command-signing proxy.
	t.Setenv("COMMANDER_MODE", "live")
	t.Setenv("TESLA_PROXY_CA_FILE", "")
	if _, err := ConfigFromEnv(); err != nil {
		t.Fatal("read-only live mode required the signing proxy", err)
	}
	t.Setenv("COMMANDER_COMMANDS_ENABLED", "true")
	t.Setenv("COMMANDER_VEHICLES", `{"1":"`+testVIN+`"}`)
	if _, err := ConfigFromEnv(); err == nil || !strings.Contains(err.Error(), "live proxy") {
		t.Fatal("live commands allowed without the signing proxy", err)
	}
}

func err2str(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func TestRegisterPartnerUsesClientCredentialsQuietly(t *testing.T) {
	var steps []string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/token":
			_ = r.ParseForm()
			if r.Form.Get("grant_type") != "client_credentials" || r.Form.Get("client_secret") != "fixture-client-secret" || r.Form.Get("scope") != ReadScopes {
				t.Error("bad partner token request")
			}
			steps = append(steps, "token")
			reply(w, 200, `{"access_token":"partner-token"}`)
		case "/api/1/partner_accounts":
			var body map[string]string
			_ = json.NewDecoder(r.Body).Decode(&body)
			if r.Method != "POST" || body["domain"] != "example.com" || r.Header.Get("Authorization") != "Bearer partner-token" {
				t.Error("bad registration")
			}
			steps = append(steps, "register")
			reply(w, 200, `{"response":{}}`)
		case "/api/1/partner_accounts/public_key":
			steps = append(steps, "verify")
			reply(w, 200, `{"response":{"public_key":"04ab"}}`)
		}
	}))
	defer up.Close()
	c := Config{ClientID: "fixture-client", ClientSecret: "fixture-client-secret", TokenURL: up.URL + "/token", Audience: up.URL}
	if err := RegisterPartner(context.Background(), c, up.Client(), "example.com"); err != nil || strings.Join(steps, ",") != "token,register,verify" {
		t.Fatal(err, steps)
	}
	if err := RegisterPartner(context.Background(), c, up.Client(), "https://example.com"); err == nil {
		t.Fatal("accepted URL as domain")
	}
}
