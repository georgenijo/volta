package commander

import (
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

// Synthetic charging-history fixtures only; field names follow Tesla's
// published example for GET /api/1/dx/charging/history.
const historyInvoiceID = "SYNTHETIC-CONTENT-ID"

func historySessionJSON(id int) string {
	return fmt.Sprintf(`{"sessionId":%d,"vin":%q,"siteLocationName":"Fixture Site, CA","chargeStartDateTime":"2026-09-01T11:43:45-07:00","chargeStopDateTime":"2026-09-01T12:08:35-07:00","unlatchDateTime":"2026-09-01T12:25:31-07:00","countryCode":"US","fees":[{"sessionFeeId":%d,"feeType":"CHARGING","currencyCode":"USD","pricingType":"PAYMENT","rateBase":0.46,"rateTier1":0,"rateTier3":null,"usageBase":40,"usageTier1":0,"usageTier3":null,"totalBase":18.4,"totalDue":18.4,"netDue":18.4,"uom":"kwh","isPaid":true,"status":"PAID","rawCharge":"SECRET-RAW"}],"billingType":"IMMEDIATE","invoices":[{"fileName":"FIXTURE.pdf","contentId":%q,"invoiceType":"IMMEDIATE"}],"vehicleMakeType":"TSLA","unexpected":"SECRET-UNKNOWN"}`, id, testVIN, id*10, historyInvoiceID)
}

func historyBody(ids ...int) string {
	items := []string{}
	for _, id := range ids {
		items = append(items, historySessionJSON(id))
	}
	return `{"response":{"data":[` + strings.Join(items, ",") + `]}}`
}

type historyFixture struct {
	s     *Service
	store *Store
	up    *httptest.Server
	logs  fmt.Stringer
	calls atomic.Int32
	now   atomic.Int64
}

func newHistoryFixture(t *testing.T, handler func(w http.ResponseWriter, r *http.Request)) *historyFixture {
	t.Helper()
	f := &historyFixture{}
	s, store, up, logs := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/1/dx/charging/history" {
			f.calls.Add(1)
			if r.Method != "GET" || r.Header.Get("Authorization") == "" || r.ContentLength > 0 {
				t.Error("history call must be an authorized GET without a body")
			}
		}
		handler(w, r)
	})
	f.s, f.store, f.up, f.logs = s, store, up, logs
	s.c.Enabled, s.oauth.c.Enabled = false, false
	s.c.HistoryEnabled, s.oauth.c.HistoryEnabled = true, true
	s.c.MonthlyBudgetUSD, s.c.CallCostUSD = 10, 1.0/500
	// Each read of the clock moves two seconds, past the history spacing.
	f.now.Store(time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC).UnixNano())
	s.collector.clock = func() time.Time { return time.Unix(0, f.now.Add(int64(2*time.Second))) }
	authorize(t, store, up.URL)
	return f
}

const historyQS = "/v1/history/charging?pageNo=0&pageSize=10&startTime=2026-01-01T00:00:00Z"

func (f *historyFixture) get(target string) *httptest.ResponseRecorder {
	return privateCall(f.s, "GET", target, "")
}

func decodePage(t *testing.T, w *httptest.ResponseRecorder) historyPage {
	t.Helper()
	var p historyPage
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &p) != nil || !p.OK {
		t.Fatal(w.Code, w.Body.String())
	}
	return p
}

func TestHistoryScopesNeverEnableCommands(t *testing.T) {
	if got := RequestedScopes(Config{HistoryEnabled: true}); got != ReadScopes+" vehicle_charging_cmds" || strings.Contains(got, "vehicle_cmds ") || strings.HasSuffix(got, " vehicle_cmds") {
		t.Fatal("history scopes", got)
	}
	if RequestedScopes(Config{}) != ReadScopes || RequestedScopes(Config{Enabled: true, HistoryEnabled: true}) != ReadScopes+" "+CommandScopes {
		t.Fatal("scope selection changed")
	}
	f := newHistoryFixture(t, func(w http.ResponseWriter, r *http.Request) { t.Error("unexpected upstream", r.URL.Path) })
	_ = f.store.saveTokens(nil)
	link, _, err := f.s.oauth.Start("7")
	if err != nil {
		t.Fatal(err)
	}
	if u, _ := url.Parse(link); u.Query().Get("scope") != ReadScopes+" "+HistoryScopes {
		t.Fatal("history link scope", u.Query().Get("scope"))
	}
	authorize(t, f.store, f.up.URL)
	assertCode(t, call(f.s, "set_charge_limit", `{"percent":80}`, "history-commands-off"), 501, "commands_unavailable")
	assertCode(t, call(f.s, "charge_start", `{}`, "history-commands-off-2"), 501, "commands_unavailable")

	t.Setenv("COMMANDER_MODE", "live")
	t.Setenv("COMMANDER_INTERNAL_SECRET", strings.Repeat("s", 32))
	t.Setenv("COMMANDER_ENCRYPTION_KEY", base64.StdEncoding.EncodeToString(testKey))
	t.Setenv("TESLA_CLIENT_ID", "STUB_ONLY")
	t.Setenv("TESLA_CLIENT_SECRET", "STUB_ONLY")
	t.Setenv("TESLA_REDIRECT_URI", "https://example.com/volta/oauth/callback")
	t.Setenv("TESLA_PROXY_CA_FILE", "")
	t.Setenv("COMMANDER_CHARGING_HISTORY_ENABLED", "true")
	if _, err := ConfigFromEnv(); err == nil {
		t.Fatal("history accepted without OAuth")
	}
	t.Setenv("COMMANDER_OAUTH_ENABLED", "true")
	c, cerr := ConfigFromEnv()
	if cerr != nil || !c.HistoryEnabled || c.Enabled || RequestedScopes(c) != ReadScopes+" "+HistoryScopes {
		t.Fatal("live history config must not need the proxy or enable commands", cerr)
	}
	t.Setenv("COMMANDER_CHARGING_HISTORY_ENABLED", "")
	if c, err := ConfigFromEnv(); err != nil || c.HistoryEnabled || RequestedScopes(c) != ReadScopes {
		t.Fatal("history must be off by default", err)
	}
}

func TestHistoryOffAndInvalidQueriesNeverCallTesla(t *testing.T) {
	f := newHistoryFixture(t, func(w http.ResponseWriter, r *http.Request) { t.Error("unexpected upstream", r.URL.Path) })
	f.s.c.HistoryEnabled = false
	assertCode(t, f.get(historyQS), 501, "history_unavailable")
	f.s.c.HistoryEnabled = true
	for _, q := range []string{
		"", "?pageNo=0", "?pageSize=10&startTime=2026-01-01T00:00:00Z",
		"?pageNo=-1&pageSize=10&startTime=2026-01-01T00:00:00Z", "?pageNo=201&pageSize=10&startTime=2026-01-01T00:00:00Z",
		"?pageNo=01&pageSize=10&startTime=2026-01-01T00:00:00Z", "?pageNo=0&pageSize=0&startTime=2026-01-01T00:00:00Z",
		"?pageNo=0&pageSize=51&startTime=2026-01-01T00:00:00Z", "?pageNo=0&pageSize=10&startTime=2026-01-01",
		"?pageNo=0&pageSize=10&startTime=2030-01-01T00:00:00Z", "?pageNo=0&pageSize=10&startTime=2026-01-01T00:00:00Z&endTime=2025-01-01T00:00:00Z",
		"?pageNo=0&pageSize=10&startTime=2026-01-01T00:00:00Z&sortOrder=asc", "?pageNo=0&pageSize=10&startTime=2026-01-01T00:00:00Z&sortBy=x",
		"?pageNo=0&pageSize=10&startTime=2026-01-01T00:00:00Z&vin=" + testVIN, "?pageNo=0&pageNo=1&pageSize=10&startTime=2026-01-01T00:00:00Z",
		"?pageNo=0&pageSize=10&startTime=2026-01-01T00:00:00Z&" + strings.Repeat("x", 600),
	} {
		assertCode(t, f.get("/v1/history/charging"+q), 400, "invalid_query")
	}
	assertCode(t, privateCall(f.s, "GET", historyQS, "{}"), 400, "invalid_query")
	if w := privateCall(f.s, "POST", historyQS, ""); w.Code != 405 {
		t.Fatal("history accepted POST", w.Code)
	}
	r := httptest.NewRequest("GET", historyQS, nil)
	w := httptest.NewRecorder()
	f.s.PrivateHandler().ServeHTTP(w, r)
	assertCode(t, w, 401, "unauthorized")
	_ = f.store.saveTokens(nil)
	assertCode(t, f.get(historyQS), 409, "authorization_required")
	if u := f.store.snapshot().Usage; u != nil || f.calls.Load() != 0 {
		t.Fatal("refused requests were billed", u)
	}
	// The collector never exposes history to TeslaMate.
	f.s.c.CollectorEnabled, f.s.c.CollectorSecret = true, strings.Repeat("collector-", 4)
	authorize(t, f.store, f.up.URL)
	if w := collect(f.s, "GET", "/api/1/dx/charging/history?pageNo=0", f.s.c.CollectorSecret); w.Code != 404 {
		t.Fatal("collector served history", w.Code)
	}
}

func TestHistoryWhitelistsAndReportsTotals(t *testing.T) {
	var body atomic.Value
	var query atomic.Value
	f := newHistoryFixture(t, func(w http.ResponseWriter, r *http.Request) {
		query.Store(r.URL.Query())
		reply(w, 200, body.Load().(string))
	})
	body.Store(`{"response":{"data":[` + historySessionJSON(11) + `,` + historySessionJSON(11) + `,{"sessionId":"x"},{"sessionId":0},{"sessionId":12,"vin":"bad","fees":null,"invoices":null,"countryCode":"usa","chargeStartDateTime":"yesterday"}]},"totalResults":386}`)
	p := decodePage(t, f.get(historyQS+"&endTime=2026-10-01T00:00:00-07:00&sortOrder=ASC"))
	q := query.Load().(url.Values)
	if len(q) != 5 || q.Get("pageNo") != "0" || q.Get("pageSize") != "10" || q.Get("startTime") != "2026-01-01T00:00:00Z" || q.Get("endTime") != "2026-10-01T07:00:00Z" || q.Get("sortOrder") != "ASC" {
		t.Fatal("upstream query", q)
	}
	if p.TotalResults == nil || *p.TotalResults != 386 || p.TotalResultsLocation != "top" || p.Rejected != 3 || len(p.Sessions) != 2 || p.Account == "" || p.EndTime != "2026-10-01T07:00:00Z" {
		t.Fatal("page", p)
	}
	s := p.Sessions[0]
	fee := s.Fees[0]
	if s.SessionID != "11" || *s.VIN != testVIN || *s.ChargeStart != "2026-09-01T11:43:45-07:00" || fee.Amounts["usageBase"] != "40" || fee.Amounts["rateTier3"] != "" || *s.Invoices[0].ContentID != historyInvoiceID {
		t.Fatal("session", s)
	}
	if _, has := fee.Amounts["rateTier3"]; has {
		t.Fatal("null tier became a number")
	}
	bad := p.Sessions[1]
	if bad.VIN != nil || bad.CountryCode != nil || bad.ChargeStart != nil || len(bad.Fees) != 0 || len(bad.Invoices) != 0 {
		t.Fatal("invalid values must stay null", bad)
	}
	body.Store(`{"response":{"data":[{"sessionId":7,"fees":[{"totalDue":1e2,"netDue":12345678901,"usageBase":-0.5,"rateBase":"0.4"}]}]}}`)
	if a := decodePage(t, f.get(historyQS)).Sessions[0].Fees[0].Amounts; len(a) != 1 || a["usageBase"] != "-0.5" {
		t.Fatal("non-decimal amounts must be dropped, not rounded", a)
	}
	body.Store(`{"response":{"data":[` + historySessionJSON(11) + `]}}`)
	raw := f.get(historyQS).Body.String()
	for _, secret := range []string{"SECRET-RAW", "SECRET-UNKNOWN", "fixture-access"} {
		if strings.Contains(raw, secret) {
			t.Fatal("unlisted field forwarded", secret)
		}
	}
	for _, leaked := range []string{testVIN, historyInvoiceID, "fixture-access", "18.4"} {
		if strings.Contains(f.logs.String(), leaked) {
			t.Fatal("history logged", leaked)
		}
	}
	for body2, want := range map[string]string{
		`{"response":{"data":[],"totalResults":5}}`:                  "response",
		`{"response":{"data":[],"totalResults":5},"totalResults":5}`: "both",
		`{"response":{"data":[],"totalResults":5},"totalResults":6}`: "conflict",
		`{"response":{"data":null}}`:                                 "none",
		`{"response":{"data":[]},"totalResults":-1}`:                 "none",
	} {
		body.Store(body2)
		if p := decodePage(t, f.get(historyQS)); p.TotalResultsLocation != want || len(p.Sessions) != 0 || (want == "conflict" && p.TotalResults != nil) {
			t.Fatal(body2, p.TotalResultsLocation)
		}
	}
}

func TestHistoryRejectsMalformedAndOversizedReplies(t *testing.T) {
	var body atomic.Value
	f := newHistoryFixture(t, func(w http.ResponseWriter, r *http.Request) { reply(w, 200, body.Load().(string)) })
	many := []int{}
	for i := 1; i <= 11; i++ {
		many = append(many, i)
	}
	for _, b := range []string{
		``, `[]`, `{}`, `{"response":[]}`, `{"response":{}}`, `{"response":{"data":{}}}`,
		`{"response":{"data":[1]}}`, `{"response":{"data":[]}} {"x":1}`, `{"response":{"data":[`,
		historyBody(many...), // more than the requested pageSize
		`{"response":{"data":[]},"pad":"` + strings.Repeat("x", historyMaxBody) + `"}`,
	} {
		body.Store(b)
		w := f.get(historyQS)
		if w.Code != 502 || strings.Contains(w.Body.String(), "sessions") {
			t.Fatal("accepted malformed reply", len(b), w.Code, w.Body.String())
		}
	}
	if u := f.store.snapshot().Usage; u == nil || u.Calls != 11 {
		t.Fatal("every billed call must be recorded", u)
	}
	// One unbounded session is rejected and counted; the page stays usable.
	body.Store(`{"response":{"data":[{"sessionId":1,"fees":[` + strings.Repeat(`{},`, historyMaxFees) + `{}]},` + historySessionJSON(2) + `]}}`)
	if p := decodePage(t, f.get(historyQS)); p.Rejected != 1 || len(p.Sessions) != 1 || p.Sessions[0].SessionID != "2" {
		t.Fatal("bounded rejection", p)
	}
}

func TestHistoryBudgetCapsAndConcurrentReservation(t *testing.T) {
	var release = make(chan struct{})
	f := newHistoryFixture(t, func(w http.ResponseWriter, r *http.Request) {
		<-release
		reply(w, 200, historyBody(1))
	})
	f.s.c.MonthlyBudgetUSD = 5 * f.s.c.CallCostUSD
	var wg sync.WaitGroup
	results := make(chan int, 9)
	for range 9 {
		wg.Go(func() { results <- f.get(historyQS).Code })
	}
	close(release)
	wg.Wait()
	close(results)
	ok, refused := 0, 0
	for code := range results {
		switch code {
		case 200:
			ok++
		case 429:
			refused++
		default:
			t.Fatal("unexpected", code)
		}
	}
	u := f.store.snapshot().Usage
	if ok != 5 || refused != 4 || f.calls.Load() != 5 || u.Calls != 5 || u.USD > f.s.c.MonthlyBudgetUSD+1e-9 {
		t.Fatal("budget overrun", ok, refused, f.calls.Load(), u)
	}
	assertCode(t, f.get(historyQS), 429, "budget_exhausted")

	// Daily and monthly history caps hold even with budget left.
	f.s.c.MonthlyBudgetUSD = 10
	_ = f.store.update(func(d *diskState) { d.History, d.Usage = nil, nil })
	for range historyDailyCalls {
		decodePage(t, f.get(historyQS))
	}
	w := f.get(historyQS)
	assertCode(t, w, 429, "history_daily_limit")
	if w.Header().Get("Retry-After") == "" {
		t.Fatal("daily limit without Retry-After")
	}
	f.now.Add(int64(24 * time.Hour))
	if p := decodePage(t, f.get(historyQS)); p.Calls.Today != 1 || p.Calls.Month != historyDailyCalls+1 {
		t.Fatal("day rollover", p.Calls)
	}
	_ = f.store.update(func(d *diskState) { d.History.Month = historyMonthlyCalls })
	assertCode(t, f.get(historyQS), 429, "history_monthly_limit")
	f.now.Store(time.Date(2026, 11, 1, 0, 1, 0, 0, time.UTC).UnixNano())
	if p := decodePage(t, f.get("/v1/history/charging?pageNo=0&pageSize=10&startTime=2026-10-01T00:00:00Z")); p.Calls.Month != 1 || p.Calls.Today != 1 {
		t.Fatal("month rollover", p.Calls)
	}
	// History reads share the collector's ledger and never touch its cycle.
	if f.s.collector.cycleCalls != 0 || !f.s.collector.last.IsZero() {
		t.Fatal("history moved collector pacing state")
	}
}

func TestHistorySpacingAndUpstreamErrors(t *testing.T) {
	var status atomic.Int32
	var refreshes atomic.Int32
	f := newHistoryFixture(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/token" {
			refreshes.Add(1)
			reply(w, 200, `{"access_token":"fresh","refresh_token":"fresh-refresh","expires_in":3600}`)
			return
		}
		if s := int(status.Load()); s != 200 {
			if s == 429 {
				w.Header().Set("Retry-After", "120")
			}
			reply(w, s, `{"error":"fixture"}`)
			return
		}
		reply(w, 200, historyBody(1))
	})
	status.Store(200)
	// Spacing: two reads within a second are refused locally.
	f.s.collector.clock = func() time.Time { return time.Unix(0, f.now.Load()) }
	decodePage(t, f.get(historyQS))
	assertCode(t, f.get(historyQS), 429, "history_paced")
	f.s.collector.clock = func() time.Time { return time.Unix(0, f.now.Add(int64(2*time.Second))) }

	status.Store(429)
	w := f.get(historyQS)
	assertCode(t, w, 429, "tesla_rate_limited")
	if w.Header().Get("Retry-After") != "120" {
		t.Fatal("Retry-After", w.Header())
	}
	before := f.calls.Load()
	status.Store(200)
	assertCode(t, f.get(historyQS), 429, "tesla_rate_limited")
	if f.calls.Load() != before {
		t.Fatal("called Tesla during Retry-After")
	}
	f.now.Add(int64(2 * time.Minute))
	decodePage(t, f.get(historyQS))

	status.Store(401)
	assertCode(t, f.get(historyQS), 503, "history_auth_refreshing")
	status.Store(200)
	decodePage(t, f.get(historyQS))
	if refreshes.Load() != 1 {
		t.Fatal("401 did not force exactly one refresh", refreshes.Load())
	}

	for code, want := range map[int32]string{500: "tesla_unavailable", 503: "tesla_unavailable", 404: "history_rejected", 400: "history_rejected", 421: "history_rejected"} {
		status.Store(code)
		assertCode(t, f.get(historyQS), 502, want)
	}
	status.Store(402)
	assertCode(t, f.get(historyQS), 503, "tesla_payment_required")
	before = f.calls.Load()
	assertCode(t, f.get(historyQS), 429, "tesla_rate_limited")
	if f.calls.Load() != before {
		t.Fatal("called Tesla after a billing refusal")
	}
	f.now.Add(int64(2 * time.Hour))
	_ = f.store.update(func(d *diskState) { d.History.Calls = 0 })

	status.Store(403)
	assertCode(t, f.get(historyQS), 403, "history_scope_missing")
	before = f.calls.Load()
	assertCode(t, f.get(historyQS), 403, "history_scope_missing")
	if f.calls.Load() != before {
		t.Fatal("repeated a refused scope call")
	}
	// Relinking (a new consent) clears the local refusal.
	status.Store(200)
	_ = f.store.saveTokens(&Tokens{Access: "relinked", Refresh: "r", Expires: time.Now().Add(time.Hour), FleetBase: f.up.URL, LinkID: "second-link"})
	decodePage(t, f.get(historyQS))
}

func TestHistoryNamespaceFencesAccounts(t *testing.T) {
	inFlight, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	var issued atomic.Int32
	var f *historyFixture
	f = newHistoryFixture(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/token":
			n := issued.Add(1)
			reply(w, 200, fmt.Sprintf(`{"access_token":"SYNTHETIC-ACCESS-%d","refresh_token":"SYNTHETIC-REFRESH","expires_in":3600}`, n))
		case "/api/1/users/region":
			reply(w, 200, fmt.Sprintf(`{"response":{"fleet_api_base_url":%q}}`, f.up.URL))
		default:
			if r.Header.Get("Authorization") == "Bearer SYNTHETIC-ACCESS-1" {
				once.Do(func() { close(inFlight); <-release })
			}
			reply(w, 200, historyBody(1))
		}
	})
	// A link made before LinkID existed gets a stable namespace on first use.
	legacy := decodePage(t, f.get(historyQS)).Account
	if f.store.tokens().LinkID == "" || decodePage(t, f.get(historyQS)).Account != legacy {
		t.Fatal("legacy namespace not persisted")
	}
	var status statusView
	_ = json.Unmarshal(privateCall(f.s, "GET", "/oauth/status", "").Body.Bytes(), &status)
	if status.History.Account != legacy || !status.History.Enabled || strings.Contains(legacy, f.store.tokens().LinkID) {
		t.Fatal("status namespace", status.History)
	}
	_ = f.s.oauth.Disconnect()
	status = statusView{}
	_ = json.Unmarshal(privateCall(f.s, "GET", "/oauth/status", "").Body.Bytes(), &status)
	if status.History.Account != "" || !status.History.Enabled {
		t.Fatal("disconnected status kept a namespace")
	}
	assertCode(t, f.get(historyQS), 409, "authorization_required")

	linkAccount(t, f.s)
	done := make(chan *httptest.ResponseRecorder)
	go func() { done <- f.get(historyQS) }()
	<-inFlight
	_ = f.s.oauth.Disconnect()
	linkAccount(t, f.s)
	close(release)
	if w := <-done; w.Code != 503 || strings.Contains(w.Body.String(), "sessions") {
		t.Fatal("in-flight reply from the replaced link returned", w.Code, w.Body.String())
	}
	second := decodePage(t, f.get(historyQS)).Account
	if second == legacy {
		t.Fatal("relink reused the old namespace")
	}
	// Refresh rotates tokens but keeps the link namespace.
	f.s.oauth.Invalidate()
	if p := decodePage(t, f.get(historyQS)); p.Account != second || f.store.tokens().Access == "SYNTHETIC-ACCESS-2" {
		t.Fatal("refresh changed the namespace or did not rotate", p.Account)
	}
	tok := f.store.tokens()
	tok.ReauthRequired = true
	_ = f.store.saveTokens(tok)
	assertCode(t, f.get(historyQS), 409, "reauthorization_required")
}

func TestHistoryRetryAfterDeadline(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	for header, want := range map[string]time.Time{
		"7200":                             now.Add(2 * time.Hour),
		" 90 ":                             now.Add(90 * time.Second),
		"86400000":                         now.Add(1000 * 24 * time.Hour),
		"Thu, 08 Oct 2026 15:30:00 GMT":    time.Date(2026, 10, 8, 15, 30, 0, 0, time.UTC),
		"Thursday, 08-Oct-26 15:30:00 GMT": time.Date(2026, 10, 8, 15, 30, 0, 0, time.UTC),
		"Thu Oct  8 15:30:00 2026":         time.Date(2026, 10, 8, 15, 30, 0, 0, time.UTC),
		// Too short or already past: the one-minute floor applies.
		"0":                             now.Add(historyMinBackoff),
		"Thu, 08 Oct 2026 11:00:00 GMT": now.Add(historyMinBackoff),
		// Malformed or missing: the conservative hour, never "call now".
		"":        now.Add(time.Hour),
		"-5":      now.Add(time.Hour),
		"1.5":     now.Add(time.Hour),
		"+60":     now.Add(time.Hour),
		"soon":    now.Add(time.Hour),
		"0x10":    now.Add(time.Hour),
		"60, 120": now.Add(time.Hour),
		// Larger than the ledger can hold saturates at its last representable day.
		"99999999999999999999": historyMaxDeadline,
		"9999999999999":        historyMaxDeadline,
	} {
		if got := retryDeadline(header, now); !got.Equal(want) || got.Location() != time.UTC {
			t.Errorf("Retry-After %q: got %s, want %s", header, got, want)
		}
	}
}

// Tesla's full Retry-After is persisted: it survives a restart and is not
// shortened, so no billable call happens before the deadline.
func TestHistoryHonoursLongRetryAfterAcrossRestart(t *testing.T) {
	var retry atomic.Value
	retry.Store("7200")
	var limited atomic.Bool
	limited.Store(true)
	f := newHistoryFixture(t, func(w http.ResponseWriter, r *http.Request) {
		if limited.Load() {
			w.Header().Set("Retry-After", retry.Load().(string))
			reply(w, 429, `{"error":"fixture"}`)
			return
		}
		reply(w, 200, historyBody(1))
	})
	start := time.Unix(0, f.now.Load())
	clock := func() time.Time { return time.Unix(0, f.now.Load()) }
	f.s.collector.clock = clock
	w := f.get(historyQS)
	assertCode(t, w, 429, "tesla_rate_limited")
	if w.Header().Get("Retry-After") != "7200" {
		t.Fatal("Retry-After", w.Header())
	}
	limited.Store(false)

	// Restart: a fresh store and service over the same state directory.
	dir := filepath.Dir(f.store.path)
	_ = f.store.Close()
	store, err := OpenStore(dir, testKey)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	s, err := NewService(f.s.c, store, f.up.Client(), slog.New(slog.NewJSONHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	s.collector.clock = clock
	before := f.calls.Load()
	// The old one-hour cap would have allowed this call.
	f.now.Store(start.Add(time.Hour + time.Minute).UnixNano())
	w = privateCall(s, "GET", historyQS, "")
	assertCode(t, w, 429, "tesla_rate_limited")
	if got := w.Header().Get("Retry-After"); got != "3540" {
		t.Fatal("remaining Retry-After", got)
	}
	f.now.Store(start.Add(2*time.Hour - time.Second).UnixNano())
	assertCode(t, privateCall(s, "GET", historyQS, ""), 429, "tesla_rate_limited")
	if f.calls.Load() != before {
		t.Fatal("called Tesla before its Retry-After deadline")
	}
	f.now.Store(start.Add(2 * time.Hour).UnixNano())
	decodePage(t, privateCall(s, "GET", historyQS, ""))

	// An HTTP-date is honoured the same way, measured from the refused call.
	retry.Store(start.Add(5 * time.Hour).UTC().Format(http.TimeFormat))
	limited.Store(true)
	f.now.Store(start.Add(3 * time.Hour).UnixNano())
	assertCode(t, privateCall(s, "GET", historyQS, ""), 429, "tesla_rate_limited")
	limited.Store(false)
	f.now.Store(start.Add(5*time.Hour - time.Second).UnixNano())
	before = f.calls.Load()
	assertCode(t, privateCall(s, "GET", historyQS, ""), 429, "tesla_rate_limited")
	if f.calls.Load() != before || !s.store.snapshot().History.BlockedUntil.Equal(start.Add(5*time.Hour)) {
		t.Fatal("HTTP-date deadline not persisted in full", s.store.snapshot().History.BlockedUntil)
	}

	// A recorded two-day Retry-After is honoured to the second, then released.
	f.now.Store(start.Add(5 * time.Hour).UnixNano())
	decodePage(t, privateCall(s, "GET", historyQS, ""))
	_ = s.store.update(func(d *diskState) { d.History.Calls = 0 })
	retry.Store("172800")
	limited.Store(true)
	f.now.Store(start.Add(6 * time.Hour).UnixNano())
	assertCode(t, privateCall(s, "GET", historyQS, ""), 429, "tesla_rate_limited")
	limited.Store(false)
	before = f.calls.Load()
	f.now.Store(start.Add(54*time.Hour - time.Second).UnixNano())
	assertCode(t, privateCall(s, "GET", historyQS, ""), 429, "tesla_rate_limited")
	if f.calls.Load() != before {
		t.Fatal("called Tesla inside a recorded two-day Retry-After")
	}
	f.now.Store(start.Add(54 * time.Hour).UnixNano())
	decodePage(t, privateCall(s, "GET", historyQS, ""))
}

// Delay-seconds count from when the response arrives, not from the request;
// an HTTP-date stays absolute.
func TestHistoryRetryAfterCountsFromReceipt(t *testing.T) {
	var retry atomic.Value
	var limited atomic.Bool
	var f *historyFixture
	f = newHistoryFixture(t, func(w http.ResponseWriter, r *http.Request) {
		if limited.Load() {
			// Tesla takes ten seconds to answer.
			f.now.Add(int64(10 * time.Second))
			w.Header().Set("Retry-After", retry.Load().(string))
			reply(w, 429, `{"error":"fixture"}`)
			return
		}
		reply(w, 200, historyBody(1))
	})
	f.s.collector.clock = func() time.Time { return time.Unix(0, f.now.Load()) }
	start := time.Unix(0, f.now.Load())
	retry.Store("120")
	limited.Store(true)
	w := f.get(historyQS)
	assertCode(t, w, 429, "tesla_rate_limited")
	if got := f.store.snapshot().History.BlockedUntil; !got.Equal(start.Add(130*time.Second)) || w.Header().Get("Retry-After") != "120" {
		t.Fatal("deadline not measured from receipt", got.Sub(start), w.Header().Get("Retry-After"))
	}
	limited.Store(false)
	before := f.calls.Load()
	f.now.Store(start.Add(129 * time.Second).UnixNano())
	assertCode(t, f.get(historyQS), 429, "tesla_rate_limited")
	if f.calls.Load() != before {
		t.Fatal("called Tesla before receipt + Retry-After")
	}
	f.now.Store(start.Add(130 * time.Second).UnixNano())
	decodePage(t, f.get(historyQS))

	f.now.Store(start.Add(time.Hour).UnixNano())
	retry.Store(start.Add(3 * time.Hour).UTC().Format(http.TimeFormat))
	limited.Store(true)
	assertCode(t, f.get(historyQS), 429, "tesla_rate_limited")
	if got := f.store.snapshot().History.BlockedUntil; !got.Equal(start.Add(3*time.Hour)) || got.Location() != time.UTC {
		t.Fatal("HTTP-date deadline moved", got)
	}
}

// A Retry-After the ledger failed to record still holds: in memory until it
// is written, and across a restart through the call's durable pending marker.
func TestHistoryUnrecordedBackoffFailsClosed(t *testing.T) {
	var limited, breakStore atomic.Bool
	var f *historyFixture
	f = newHistoryFixture(t, func(w http.ResponseWriter, r *http.Request) {
		if limited.Load() {
			if breakStore.Load() {
				// The ledger becomes unwritable after the reservation.
				if err := os.Chmod(filepath.Dir(f.store.path), 0500); err != nil {
					t.Error(err)
				}
			}
			w.Header().Set("Retry-After", "7200")
			reply(w, 429, `{"error":"fixture"}`)
			return
		}
		reply(w, 200, historyBody(1))
	})
	dir := filepath.Dir(f.store.path)
	t.Cleanup(func() { _ = os.Chmod(dir, 0700) })
	clock := func() time.Time { return time.Unix(0, f.now.Load()) }
	f.s.collector.clock = clock
	start := time.Unix(0, f.now.Load())
	at := func(d time.Duration) { f.now.Store(start.Add(d).UnixNano()) }

	limited.Store(true)
	breakStore.Store(true)
	assertCode(t, f.get(historyQS), 429, "tesla_rate_limited")
	limited.Store(false)
	breakStore.Store(false)
	if h := f.store.snapshot().History; !h.BlockedUntil.IsZero() || !h.Pending.Equal(start.UTC()) {
		t.Fatal("fixture: the backoff write should have failed", h)
	}
	before := f.calls.Load()
	// Storage still unwritable: refused without calling.
	at(2 * time.Minute)
	assertCode(t, f.get(historyQS), 503, "storage_unavailable")
	// Storage back: the remembered deadline is written first and holds.
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	at(time.Hour)
	assertCode(t, f.get(historyQS), 429, "tesla_rate_limited")
	if h := f.store.snapshot().History; !h.BlockedUntil.Equal(start.Add(2*time.Hour)) || !h.Pending.IsZero() {
		t.Fatal("remembered deadline not recorded", h)
	}
	if f.calls.Load() != before {
		t.Fatal("called Tesla inside an unrecorded Retry-After")
	}
	at(2 * time.Hour)
	decodePage(t, f.get(historyQS))

}

// A reply whose outcome was never recorded before a restart may have carried
// any Retry-After, so elapsed time never re-opens history: the durable
// pending marker holds through days, a month change and a relink, until an
// operator resolves it.
func TestHistoryUnknownOutcomeHoldsUntilResolved(t *testing.T) {
	start := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	for _, retry := range []string{"172800", start.Add(48 * time.Hour).Format(http.TimeFormat)} {
		t.Run(retry, func(t *testing.T) {
			var limited, breakStore atomic.Bool
			var f *historyFixture
			f = newHistoryFixture(t, func(w http.ResponseWriter, r *http.Request) {
				if limited.Load() {
					if breakStore.Load() {
						if err := os.Chmod(filepath.Dir(f.store.path), 0500); err != nil {
							t.Error(err)
						}
					}
					w.Header().Set("Retry-After", retry)
					reply(w, 429, `{"error":"fixture"}`)
					return
				}
				reply(w, 200, historyBody(1))
			})
			dir := filepath.Dir(f.store.path)
			t.Cleanup(func() { _ = os.Chmod(dir, 0700) })
			clock := func() time.Time { return time.Unix(0, f.now.Load()) }
			at := func(d time.Duration) { f.now.Store(start.Add(d).UnixNano()) }
			at(0)
			f.s.collector.clock = clock

			// Tesla asks for 48 hours; the write recording it fails, and
			// commander restarts before retrying it.
			limited.Store(true)
			breakStore.Store(true)
			assertCode(t, f.get(historyQS), 429, "tesla_rate_limited")
			limited.Store(false)
			breakStore.Store(false)
			if err := os.Chmod(dir, 0700); err != nil {
				t.Fatal(err)
			}
			if h := f.store.snapshot().History; !h.BlockedUntil.IsZero() || h.Pending.IsZero() {
				t.Fatal("fixture: the backoff write should have failed", h)
			}
			_ = f.store.Close()
			store, err := OpenStore(dir, testKey)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { store.Close() })
			s, err := NewService(f.s.c, store, f.up.Client(), slog.New(slog.NewJSONHandler(io.Discard, nil)))
			if err != nil {
				t.Fatal(err)
			}
			s.collector.clock = clock
			before := f.calls.Load()
			held := func(when string) {
				t.Helper()
				w := privateCall(s, "GET", historyQS, "")
				assertCode(t, w, 503, "history_outcome_unknown")
				if w.Header().Get("Retry-After") != "" {
					t.Fatal(when, "an unknown outcome must not suggest a retry time", w.Header())
				}
			}
			// The old one-day hold allowed this call inside Tesla's 48 hours.
			at(24 * time.Hour)
			held("T+24h")
			at(48*time.Hour - time.Second)
			held("T+48h-1s")
			// Past the lost deadline, nothing proves it was 48 hours: still held,
			// across a month change and a disconnect and relink.
			at(48 * time.Hour)
			held("T+48h")
			at(40 * 24 * time.Hour)
			held("T+40d")
			if res := s.oauth.Disconnect(); !res.OK {
				t.Fatal("disconnect", res)
			}
			authorize(t, store, f.up.URL)
			held("after relink")
			if f.calls.Load() != before {
				t.Fatal("called Tesla while a call's outcome was unknown")
			}

			// Only an explicit operator resolution, recording what is known,
			// clears the hold.
			_ = store.update(func(d *diskState) { d.History.Pending, d.History.Calls = time.Time{}, 0 })
			decodePage(t, privateCall(s, "GET", historyQS, ""))
			if !store.snapshot().History.Pending.IsZero() {
				t.Fatal("a recorded call left its pending marker")
			}
		})
	}
}
