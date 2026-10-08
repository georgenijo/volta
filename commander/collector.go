package commander

import (
	"context"
	"crypto/subtle"
	"io"
	"math"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// CallbackBounce is the public sign-in redirect target. It is stateless: it
// forwards only a validated state plus code or error into the app, which
// relays them to the private API. It never logs, stores, or exchanges them.
func CallbackBounce() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q, err := url.ParseQuery(r.URL.RawQuery)
		state, code, providerError := q["state"], q["code"], q["error"]
		if err != nil || len(r.URL.RawQuery) > 4096 || len(state) != 1 || state[0] == "" || len(code) > 1 || len(providerError) > 1 || (len(code) == 1) == (len(providerError) == 1) || (len(code) == 1 && code[0] == "") || (len(providerError) == 1 && providerError[0] == "") {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			w.WriteHeader(400)
			_, _ = io.WriteString(w, "Return to Volta and sign in again.\n")
			return
		}
		out := url.Values{"state": state}
		if len(code) == 1 {
			out["code"] = code
		} else {
			out["error"] = providerError
		}
		w.Header().Set("Location", AppCallback+"?"+out.Encode())
		w.WriteHeader(http.StatusFound)
	})
}

type BudgetStatus struct {
	MonthlyLimitUSD float64 `json:"monthlyLimitUsd"`
	SpentUSD        float64 `json:"spentUsd"`
	Paused          bool    `json:"paused"`
}

func month(t time.Time) string { return t.UTC().Format("2006-01") }

func (s *Service) usage(now time.Time) Usage {
	u := s.store.snapshot().Usage
	if u == nil || u.Month != month(now) {
		return Usage{Month: month(now)}
	}
	return *u
}

func (s *Service) budget() BudgetStatus {
	u := s.usage(time.Now())
	return BudgetStatus{MonthlyLimitUSD: s.c.MonthlyBudgetUSD, SpentUSD: math.Round(u.USD*100) / 100, Paused: u.USD+s.c.CallCostUSD > s.c.MonthlyBudgetUSD}
}

// Spread the remaining monthly budget evenly: never call upstream more often
// than the remaining calls allow until the month ends.
func (s *Service) pacing(now time.Time, u Usage) time.Duration {
	remaining := int((s.c.MonthlyBudgetUSD - u.USD) / s.c.CallCostUSD)
	y, m, _ := now.UTC().Date()
	left := time.Date(y, m+1, 1, 0, 0, 0, 0, time.UTC).Sub(now)
	if remaining < 1 {
		return left
	}
	return max(s.c.CacheTTL, left/time.Duration(remaining))
}

type cached struct {
	status int
	body   []byte
	at     time.Time
}

type collector struct {
	mu    sync.Mutex // one upstream call at a time; never double-bill a poll
	cache map[string]cached
	// account is the OAuth account the cache and pacing belong to.
	account uint64
	// The current polling cycle: when it started, which vehicle and read
	// opened it, how many upstream calls it billed, and whether one dependent
	// read may still join it.
	last         time.Time
	cycleVehicle string
	cycleKey     string
	cycleCalls   int
	followUp     bool
	// served is when each vehicle last opened a cycle; refused, when it was
	// last turned away. Products count as vehicle "".
	served, refused map[string]time.Time
	clock           func() time.Time // tests only; nil means time.Now
	// historyLast is the last charging-history call; it shares mu but never
	// touches the polling cycle or cache above.
	historyLast time.Time
	// historyUnsaved is a history reply's outcome (its Retry-After, refusal or
	// cleared pending marker) that the ledger failed to record. No further
	// history call is made until it is written.
	historyUnsaved func(*diskState)
}

const (
	// TeslaMate reads the summary and then vehicle_data (or vehicle_data and
	// then the summary when the car is asleep) within one fetch.
	followUpWindow = time.Minute
	// How long an opened slot is held for a vehicle that has waited longer.
	priorityWindow = time.Minute
)

var (
	vehiclePath = regexp.MustCompile(`^/api/1/vehicles/([0-9]{1,20}|[A-HJ-NPR-Z0-9]{17})(/vehicle_data)?$`)
	dataGroups  = []string{"charge_state", "climate_state", "closures_state", "drive_state", "gui_settings", "location_data", "vehicle_config", "vehicle_state", "vehicle_data_combo"}
)

// Placeholder session for TeslaMate's token mode. Real Tesla tokens never
// leave commander; TeslaMate authenticates with COMMANDER_COLLECTOR_SECRET.
const collectorSession = `{"access_token":"volta-collector-session","refresh_token":"volta-collector-session","token_type":"Bearer","expires_in":28800}`

// CollectorHandler is a read-only Fleet API facade for TeslaMate on a private
// network: a fixed allowlist of GET reads, no wake, no commands, cached and
// paced under the monthly budget.
func (s *Service) CollectorHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if !s.c.CollectorEnabled || subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+s.c.CollectorSecret)) != 1 {
			s.audit.Warn("collector_auth_rejected")
			writeJSON(w, 401, map[string]string{"error": "unauthorized"})
			return
		}
		if r.Method == "POST" && r.URL.Path == "/oauth2/v3/token" {
			_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, 8192))
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, collectorSession)
			return
		}
		key, vehicle, ok := collectorKey(r)
		if !ok {
			writeJSON(w, 404, map[string]string{"error": "not_found"})
			return
		}
		st := s.oauth.Status()
		if !st.Connected {
			if r.URL.Path == "/api/1/products" {
				writeJSON(w, 200, map[string]any{"response": []any{}, "count": 0})
				return
			}
			writeJSON(w, 503, map[string]string{"error": "account_not_linked"})
			return
		}
		status, body, retryAfter := s.collect(r.Context(), key, vehicle)
		if retryAfter > 0 {
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write(body)
	})
}

// collectorKey canonicalizes an allowed read into its upstream path and query
// and names the vehicle it reads ("" for products).
func collectorKey(r *http.Request) (string, string, bool) {
	if r.Method != "GET" {
		return "", "", false
	}
	q := r.URL.Query()
	if r.URL.Path == "/api/1/products" && len(q) == 0 {
		return r.URL.Path, "", true
	}
	m := vehiclePath.FindStringSubmatch(r.URL.Path)
	if m == nil {
		return "", "", false
	}
	if m[2] == "" {
		return r.URL.Path, m[1], len(q) == 0
	}
	if len(q) == 0 {
		return r.URL.Path, m[1], true
	}
	if len(q) != 1 || len(q["endpoints"]) != 1 {
		return "", "", false
	}
	groups := strings.Split(q.Get("endpoints"), ";")
	for _, g := range groups {
		if !slices.Contains(dataGroups, g) {
			return "", "", false
		}
	}
	return r.URL.Path + "?" + url.Values{"endpoints": {strings.Join(groups, ";")}}.Encode(), m[1], true
}

func (s *Service) collect(ctx context.Context, key, vehicle string) (int, []byte, int) {
	c := &s.collector
	c.mu.Lock()
	defer c.mu.Unlock()
	account := s.oauth.Account()
	if account != c.account {
		// Another Tesla account (or none) is linked: nothing cached or paced
		// for the previous one may be served.
		c.cache, c.served, c.refused, c.account = map[string]cached{}, map[string]time.Time{}, map[string]time.Time{}, account
		c.last, c.cycleVehicle, c.cycleKey, c.cycleCalls, c.followUp = time.Time{}, "", "", 0, false
	}
	now := time.Now()
	if c.clock != nil {
		now = c.clock()
	}
	u := s.usage(now)
	hit, found := c.cache[key]
	if found && now.Sub(hit.at) < s.c.CacheTTL {
		return hit.status, hit.body, 0
	}
	// A dependent read joins the cycle it follows instead of waiting for the
	// next one, which the first read of the same fetch would take again.
	followUp := c.followUp && vehicle != "" && vehicle == c.cycleVehicle && key != c.cycleKey && now.Sub(c.last) < followUpWindow
	if !followUp {
		// Pacing holds for every upstream call, failed or not, so no reply
		// can make TeslaMate poll faster than the budget allows. Each call
		// in a cycle extends it by one paced interval.
		wait := s.pacing(now, u)*time.Duration(max(c.cycleCalls, 1)) - now.Sub(c.last)
		if c.last.IsZero() {
			wait = 0
		}
		if held := priorityWindow + wait; wait <= 0 && held > 0 {
			// For a while after it opens, a slot goes first to a vehicle
			// turned away this cycle and served longer ago than this one.
			for other, at := range c.refused {
				if other != vehicle && at.After(c.last) && c.served[other].Before(c.served[vehicle]) {
					wait = held
				}
			}
		}
		if wait > 0 {
			c.refused[vehicle] = now
			if found {
				return hit.status, hit.body, 0
			}
			return 429, []byte(`{"error":"paced to monthly budget"}`), min(int(math.Ceil(wait.Seconds())), 3600)
		}
	}
	if u.USD+s.c.CallCostUSD > s.c.MonthlyBudgetUSD {
		if found {
			return hit.status, hit.body, 0
		}
		s.audit.Warn("collector_budget_exhausted")
		return 429, []byte(`{"error":"monthly budget reached"}`), 3600
	}
	t, authErr := s.oauth.Token(ctx)
	if authErr != nil {
		return 503, []byte(`{"error":"authorization unavailable"}`), 0
	}
	// Reserve before calling: an unrecorded call must never happen, and 5xx
	// replies (unbilled by Tesla) only make the estimate conservative.
	if err := s.store.update(func(d *diskState) {
		u.Calls++
		u.USD += s.c.CallCostUSD
		d.Usage = &u
	}); err != nil {
		return 503, []byte(`{"error":"budget ledger unavailable"}`), 0
	}
	if followUp {
		c.cycleCalls, c.followUp = c.cycleCalls+1, false
	} else {
		for other, at := range c.refused {
			if !at.After(c.last) {
				delete(c.refused, other) // stopped asking; holds no claim
			}
		}
		c.last, c.cycleVehicle, c.cycleKey, c.cycleCalls, c.followUp = now, vehicle, key, 1, false
		c.served[vehicle] = now
		delete(c.refused, vehicle)
	}
	req, _ := http.NewRequestWithContext(ctx, "GET", t.FleetBase+key, nil)
	req.Header.Set("Authorization", "Bearer "+t.Access)
	res, err := s.collectorClient.Do(req)
	if err != nil {
		return 504, []byte(`{"error":"upstream unavailable"}`), 0
	}
	defer res.Body.Close()
	body, err := io.ReadAll(io.LimitReader(res.Body, 2<<20))
	if err != nil {
		return 502, []byte(`{"error":"upstream read failed"}`), 0
	}
	if s.oauth.Account() != account {
		// The account changed while this read was in flight; drop its reply.
		return 503, []byte(`{"error":"account changed"}`), 0
	}
	// Only a read Tesla answered can lead TeslaMate to a dependent read.
	c.followUp = !followUp && res.StatusCode < 500 && res.StatusCode != 401 && res.StatusCode != 429
	switch {
	case res.StatusCode == 401:
		// Avoid tripping TeslaMate's sign-out fuse; refresh before the next poll.
		s.oauth.Invalidate()
		return 503, []byte(`{"error":"authorization refreshing"}`), 0
	case res.StatusCode == 429:
		retry, _ := strconv.Atoi(res.Header.Get("Retry-After"))
		return 429, body, min(max(retry, 1), 3600)
	case res.StatusCode < 500:
		// Billed replies (data, asleep, forbidden, missing) are reused until
		// the next paced call instead of being re-requested.
		c.cache[key] = cached{status: res.StatusCode, body: body, at: now}
	}
	return res.StatusCode, body, 0
}

// The marker tells an optional host unit to let TeslaMate rediscover vehicles
// once after a successful link. It contains only a timestamp.
func (s *Service) markLinked() {
	if s.c.DataDir == "" {
		return
	}
	path := filepath.Join(s.c.DataDir, "linked")
	tmp := path + ".tmp"
	if os.WriteFile(tmp, []byte(time.Now().UTC().Format(time.RFC3339)+"\n"), 0644) == nil {
		_ = os.Rename(tmp, path)
	}
}
