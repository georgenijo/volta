package commander

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
)

// Tesla-billed charging history (GET /api/1/dx/charging/history). Operator
// triggered through the private API only: never wired into the TeslaMate
// collector, never fetching invoices, and never sending any POST upstream.
const (
	historyDailyCalls   = 12
	historyMonthlyCalls = 60
	historyMaxPageSize  = 50
	historyMaxPageNo    = 200
	historyMaxBody      = 2 << 20
	historyMinSpacing   = time.Second
	historyMaxFees      = 20
	historyMaxInvoices  = 10
	// Tesla 429 handling: a missing or malformed Retry-After waits an hour; a
	// valid one is honoured in full but never shorter than a minute.
	historyDefaultBackoff = time.Hour
	historyMinBackoff     = time.Minute
)

// The ledger is JSON, which cannot hold years past 9999; later deadlines
// saturate there rather than overflow into the past.
var historyMaxDeadline = time.Date(9999, 12, 31, 23, 59, 59, 0, time.UTC)

var (
	pageNoPattern   = regexp.MustCompile(`^(0|[1-9][0-9]{0,2})$`)
	pageSizePattern = regexp.MustCompile(`^[1-9][0-9]?$`)
	tokenPattern    = regexp.MustCompile(`^[A-Za-z0-9_ -]{1,32}$`)
	countryPattern  = regexp.MustCompile(`^[A-Z]{2}$`)
	currencyPattern = regexp.MustCompile(`^[A-Z]{3}$`)
	contentPattern  = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
	integerPattern  = regexp.MustCompile(`^-?[0-9]{1,19}$`)
	// Plain decimals only: exponents or huge values are dropped, never rounded.
	decimalPattern = regexp.MustCompile(`^-?[0-9]{1,9}(\.[0-9]{1,9})?$`)
	// RFC 9110 delay-seconds: digits only, no sign or fraction.
	delaySecondsPattern = regexp.MustCompile(`^[0-9]{1,64}$`)
)

type historyQuery struct {
	pageNo, pageSize int
	start, end       time.Time
	order            string
}

func parseHistoryQuery(r *http.Request, now time.Time) (historyQuery, error) {
	var q historyQuery
	if len(r.URL.RawQuery) > 512 {
		return q, errors.New("query too long")
	}
	values, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		return q, err
	}
	one := map[string]string{}
	for k, v := range values {
		switch k {
		case "pageNo", "pageSize", "startTime", "endTime", "sortOrder":
		default:
			return q, errors.New("unexpected parameter")
		}
		if len(v) != 1 {
			return q, errors.New("duplicate parameter")
		}
		one[k] = v[0]
	}
	if !pageNoPattern.MatchString(one["pageNo"]) || !pageSizePattern.MatchString(one["pageSize"]) {
		return q, errors.New("pageNo and pageSize are required")
	}
	q.pageNo, _ = strconv.Atoi(one["pageNo"])
	q.pageSize, _ = strconv.Atoi(one["pageSize"])
	if q.pageNo > historyMaxPageNo || q.pageSize > historyMaxPageSize {
		return q, errors.New("page out of range")
	}
	if q.start, err = time.Parse(time.RFC3339, one["startTime"]); err != nil || q.start.Year() < 2012 || q.start.After(now) {
		return q, errors.New("startTime must be a past RFC 3339 time")
	}
	q.end = now
	if v, ok := one["endTime"]; ok {
		if q.end, err = time.Parse(time.RFC3339, v); err != nil || !q.end.After(q.start) || q.end.After(now.Add(time.Minute)) {
			return q, errors.New("endTime must follow startTime and not be in the future")
		}
	}
	if q.order = one["sortOrder"]; q.order != "" && q.order != "ASC" && q.order != "DESC" {
		return q, errors.New("sortOrder must be ASC or DESC")
	}
	return q, nil
}

func (q historyQuery) upstream() string {
	v := url.Values{"pageNo": {strconv.Itoa(q.pageNo)}, "pageSize": {strconv.Itoa(q.pageSize)}, "startTime": {q.start.UTC().Format(time.RFC3339)}, "endTime": {q.end.UTC().Format(time.RFC3339)}}
	if q.order != "" {
		v.Set("sortOrder", q.order)
	}
	return "/api/1/dx/charging/history?" + v.Encode()
}

type historyFee struct {
	SessionFeeID *string `json:"sessionFeeId"`
	FeeType      *string `json:"feeType"`
	CurrencyCode *string `json:"currencyCode"`
	PricingType  *string `json:"pricingType"`
	UOM          *string `json:"uom"`
	IsPaid       *bool   `json:"isPaid"`
	Status       *string `json:"status"`
	// Exact decimal strings, so no consumer rounds money through a float.
	Amounts map[string]string `json:"amounts"`
}

type historyInvoice struct {
	FileName    *string `json:"fileName"`
	ContentID   *string `json:"contentId"`
	InvoiceType *string `json:"invoiceType"`
}

type historySession struct {
	SessionID        string           `json:"sessionId"`
	VIN              *string          `json:"vin"`
	SiteLocationName *string          `json:"siteLocationName"`
	ChargeStart      *string          `json:"chargeStartDateTime"`
	ChargeStop       *string          `json:"chargeStopDateTime"`
	Unlatch          *string          `json:"unlatchDateTime"`
	CountryCode      *string          `json:"countryCode"`
	BillingType      *string          `json:"billingType"`
	VehicleMakeType  *string          `json:"vehicleMakeType"`
	Fees             []historyFee     `json:"fees"`
	Invoices         []historyInvoice `json:"invoices"`
}

type historyCalls struct {
	Today        int `json:"today"`
	DailyLimit   int `json:"dailyLimit"`
	Month        int `json:"month"`
	MonthlyLimit int `json:"monthlyLimit"`
}

type historyPage struct {
	OK      bool   `json:"ok"`
	Account string `json:"account"`
	// The exact window and page sent upstream, so a caller can verify paging.
	PageNo    int    `json:"pageNo"`
	PageSize  int    `json:"pageSize"`
	StartTime string `json:"startTime"`
	EndTime   string `json:"endTime"`
	// Tesla's spec places totalResults inconsistently; report where it was.
	TotalResults         *int64           `json:"totalResults"`
	TotalResultsLocation string           `json:"totalResultsLocation"`
	Sessions             []historySession `json:"sessions"`
	Rejected             int              `json:"rejected"`
	Budget               BudgetStatus     `json:"budget"`
	Calls                historyCalls     `json:"historyCalls"`
}

var feeAmounts = []string{"rateBase", "rateTier1", "rateTier2", "rateTier3", "rateTier4", "usageBase", "usageTier1", "usageTier2", "usageTier3", "usageTier4", "totalBase", "totalTier1", "totalTier2", "totalTier3", "totalTier4", "totalDue", "netDue"}

func text(v any, pattern *regexp.Regexp) *string {
	s, ok := v.(string)
	if !ok || !pattern.MatchString(s) {
		return nil
	}
	return &s
}

// Free text from Tesla: bounded, printable, single line.
func label(v any, limit int) *string {
	s, ok := v.(string)
	if !ok || s == "" || len(s) > limit*4 || len([]rune(s)) > limit || strings.IndexFunc(s, func(r rune) bool { return !unicode.IsPrint(r) }) >= 0 {
		return nil
	}
	return &s
}

func timestamp(v any) *string {
	s, ok := v.(string)
	if !ok || len(s) > 40 {
		return nil
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil || t.Year() < 2012 || t.Year() > 2100 {
		return nil
	}
	out := t.Format(time.RFC3339)
	return &out
}

func amount(v any) (string, bool) {
	n, ok := v.(json.Number)
	return string(n), ok && decimalPattern.MatchString(string(n))
}

func identifier(v any) (string, bool) {
	n, ok := v.(json.Number)
	if !ok || !integerPattern.MatchString(string(n)) {
		return "", false
	}
	i, err := n.Int64()
	return strconv.FormatInt(i, 10), err == nil && i > 0
}

func historyObjects(v any, limit int) ([]map[string]any, bool) {
	if v == nil {
		return nil, true
	}
	list, ok := v.([]any)
	if !ok || len(list) > limit {
		return nil, false
	}
	out := make([]map[string]any, 0, len(list))
	for _, item := range list {
		m, ok := item.(map[string]any)
		if !ok {
			return nil, false
		}
		out = append(out, m)
	}
	return out, true
}

// parseSession keeps only documented fields, re-validated; anything unknown,
// including raw charge details, is dropped. Missing values stay null.
func parseSession(m map[string]any) (historySession, bool) {
	id, ok := identifier(m["sessionId"])
	if !ok {
		return historySession{}, false
	}
	s := historySession{SessionID: id, SiteLocationName: label(m["siteLocationName"], 200), ChargeStart: timestamp(m["chargeStartDateTime"]), ChargeStop: timestamp(m["chargeStopDateTime"]), Unlatch: timestamp(m["unlatchDateTime"]), CountryCode: text(m["countryCode"], countryPattern), BillingType: text(m["billingType"], tokenPattern), VehicleMakeType: text(m["vehicleMakeType"], tokenPattern), VIN: text(m["vin"], vinPattern), Fees: []historyFee{}, Invoices: []historyInvoice{}}
	fees, ok := historyObjects(m["fees"], historyMaxFees)
	if !ok {
		return historySession{}, false
	}
	for _, f := range fees {
		fee := historyFee{FeeType: text(f["feeType"], tokenPattern), CurrencyCode: text(f["currencyCode"], currencyPattern), PricingType: text(f["pricingType"], tokenPattern), UOM: text(f["uom"], tokenPattern), Status: text(f["status"], tokenPattern), Amounts: map[string]string{}}
		if n, ok := identifier(f["sessionFeeId"]); ok {
			fee.SessionFeeID = &n
		}
		if b, ok := f["isPaid"].(bool); ok {
			fee.IsPaid = &b
		}
		for _, k := range feeAmounts {
			if n, ok := amount(f[k]); ok {
				fee.Amounts[k] = n
			}
		}
		s.Fees = append(s.Fees, fee)
	}
	invoices, ok := historyObjects(m["invoices"], historyMaxInvoices)
	if !ok {
		return historySession{}, false
	}
	for _, i := range invoices {
		inv := historyInvoice{ContentID: text(i["contentId"], contentPattern), InvoiceType: text(i["invoiceType"], tokenPattern)}
		if name := label(i["fileName"], 200); name != nil && !strings.ContainsAny(*name, `/\`) {
			inv.FileName = name
		}
		s.Invoices = append(s.Invoices, inv)
	}
	return s, true
}

func totalResults(v any) (*int64, bool) {
	n, ok := v.(json.Number)
	if !ok || !integerPattern.MatchString(string(n)) {
		return nil, false
	}
	i, err := n.Int64()
	if err != nil || i < 0 || i > 1_000_000 {
		return nil, false
	}
	return &i, true
}

// parseHistory accepts response.data as the list, and totalResults at the top
// level, inside response, both (if equal), or neither.
func parseHistory(body []byte, pageSize int) (historyPage, error) {
	var p historyPage
	d := json.NewDecoder(bytes.NewReader(body))
	d.UseNumber()
	var root map[string]any
	if err := d.Decode(&root); err != nil || root == nil {
		return p, errors.New("not a JSON object")
	}
	if _, err := d.Token(); err != io.EOF {
		return p, errors.New("trailing data")
	}
	response, ok := root["response"].(map[string]any)
	if !ok {
		return p, errors.New("missing response")
	}
	raw, present := response["data"]
	if !present {
		return p, errors.New("missing response.data")
	}
	items, ok := historyObjects(raw, pageSize)
	if !ok {
		return p, errors.New("response.data is not a bounded list")
	}
	top, topOK := totalResults(root["totalResults"])
	inner, innerOK := totalResults(response["totalResults"])
	switch {
	case topOK && innerOK && *top != *inner:
		p.TotalResultsLocation = "conflict"
	case topOK && innerOK:
		p.TotalResults, p.TotalResultsLocation = top, "both"
	case topOK:
		p.TotalResults, p.TotalResultsLocation = top, "top"
	case innerOK:
		p.TotalResults, p.TotalResultsLocation = inner, "response"
	default:
		p.TotalResultsLocation = "none"
	}
	p.Sessions = []historySession{}
	seen := map[string]bool{}
	for _, item := range items {
		s, ok := parseSession(item)
		if !ok || seen[s.SessionID] {
			p.Rejected++
			continue
		}
		seen[s.SessionID] = true
		p.Sessions = append(p.Sessions, s)
	}
	return p, nil
}

func historyFailure(status int, code, message string, retryAfter int) Result {
	r := failure(status, code, message)
	r.RetryAfter = retryAfter
	return r
}

func historyUsage(d *diskState, now time.Time) HistoryUsage {
	h := HistoryUsage{}
	if d.History != nil {
		h = *d.History
	}
	if day := now.UTC().Format("2006-01-02"); h.Day != day {
		if h.Day[:min(len(h.Day), 7)] != month(now) {
			h.Month = 0
		}
		h.Day, h.Calls = day, 0
	}
	return h
}

// recordHistory stores what one call learned and clears its pending marker
// (only if the marker is still that call's). Idempotent, so a write that
// failed can be retried as is.
func recordHistory(stamp time.Time, learn func(*HistoryUsage)) func(*diskState) {
	return func(d *diskState) {
		h := HistoryUsage{}
		if d.History != nil {
			h = *d.History
		}
		if h.Pending.Equal(stamp) {
			h.Pending = time.Time{}
		}
		if learn != nil {
			learn(&h)
		}
		d.History = &h
	}
}

func blockHistory(until time.Time) func(*HistoryUsage) {
	return func(h *HistoryUsage) {
		if until.After(h.BlockedUntil) {
			h.BlockedUntil = until
		}
	}
}

// retryDeadline returns the UTC time Tesla's Retry-After (delay-seconds or an
// HTTP-date) allows the next call, never earlier than historyMinBackoff. now
// is when the response arrived: delay-seconds count from there.
func retryDeadline(header string, now time.Time) time.Time {
	floor := now.Add(historyMinBackoff).UTC()
	v := strings.TrimSpace(header)
	var at time.Time
	switch t, err := http.ParseTime(v); {
	case delaySecondsPattern.MatchString(v):
		n, err := strconv.ParseInt(v, 10, 64)
		if left := historyMaxDeadline.Sub(now) / time.Second; err != nil || n > int64(left) {
			return historyMaxDeadline
		}
		at = now.Add(time.Duration(n) * time.Second).UTC()
	case err == nil:
		at = t.UTC()
	default:
		return now.Add(historyDefaultBackoff).UTC()
	}
	if at.After(historyMaxDeadline) {
		return historyMaxDeadline
	}
	if at.Before(floor) {
		return floor
	}
	return at
}

func secondsUntil(t, now time.Time) int {
	return max(1, int(math.Ceil(t.Sub(now).Seconds())))
}

func untilTomorrow(now time.Time) int {
	y, m, d := now.UTC().Date()
	return int(math.Ceil(time.Date(y, m, d+1, 0, 0, 0, 0, time.UTC).Sub(now).Seconds()))
}

func (s *Service) handleChargingHistory(out http.ResponseWriter, r *http.Request) {
	w := &statusWriter{ResponseWriter: out, status: 200}
	code, sessions := "ok", 0
	// Counts and codes only: never the VIN, invoice IDs, fees or tokens.
	defer func() { s.audit.Info("history_request", "httpStatus", w.status, "code", code, "sessions", sessions) }()
	fail := func(res Result) {
		code = resultCode(res)
		writeResult(w, res)
	}
	if !s.c.HistoryEnabled {
		fail(failure(501, "history_unavailable", "Charging history is not enabled."))
		return
	}
	if n, _ := io.ReadFull(r.Body, make([]byte, 1)); n != 0 {
		fail(failure(400, "invalid_query", "Charging history takes no request body."))
		return
	}
	c := &s.collector
	// Shared with the collector: one upstream data call and ledger write at a time.
	c.mu.Lock()
	defer c.mu.Unlock()
	clock := func() time.Time {
		if c.clock != nil {
			return c.clock()
		}
		return time.Now()
	}
	now := clock()
	// An earlier reply's outcome the ledger failed to record goes first;
	// until it is stored, nothing else is called.
	if c.historyUnsaved != nil {
		if err := s.store.update(c.historyUnsaved); err != nil {
			fail(failure(503, "storage_unavailable", "Cannot record an earlier history reply; nothing was called."))
			return
		}
		c.historyUnsaved = nil
	}
	q, err := parseHistoryQuery(r, now)
	if err != nil {
		fail(failure(400, "invalid_query", "Expected pageNo 0-200, pageSize 1-50, a past RFC 3339 startTime, optional endTime and sortOrder ASC|DESC."))
		return
	}
	namespace, account, authErr := s.oauth.Namespace()
	if authErr != nil {
		fail(*authErr)
		return
	}
	if h := s.store.snapshot().History; h != nil {
		if h.ScopeMissing == namespace {
			fail(failure(403, "history_scope_missing", "Tesla refused charging history; reconnect with charging consent."))
			return
		}
		if now.Before(h.BlockedUntil) {
			fail(historyFailure(429, "tesla_rate_limited", "Tesla asked Volta to wait before reading history again.", secondsUntil(h.BlockedUntil, now)))
			return
		}
		// Calls are serialised and this process holds the store, so a marker
		// here is from a call that crashed or whose outcome was never stored.
		// Its reply may have carried any Retry-After, and no amount of elapsed
		// time proves that deadline passed: history stays held until an
		// operator resolves it. A relink, a new day or month and a restart
		// all leave the marker in place.
		if !h.Pending.IsZero() {
			fail(failure(503, "history_outcome_unknown", "An earlier history call's reply was never recorded; history is held until an operator resolves it."))
			return
		}
	}
	if !c.historyLast.IsZero() && now.Sub(c.historyLast) < historyMinSpacing {
		fail(historyFailure(429, "history_paced", "Read one history page at a time.", 1))
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 20*time.Second)
	defer cancel()
	t, authErr := s.oauth.Token(ctx)
	if authErr != nil {
		fail(*authErr)
		return
	}
	if s.oauth.Account() != account || r.Context().Err() != nil {
		fail(failure(503, "account_changed", "The Tesla account changed; nothing was read."))
		return
	}
	// Reserve before calling, reading the ledger inside the write: an
	// unrecorded call must never happen and no reservation is lost.
	var refused *Result
	var calls historyCalls
	stamp := now.UTC()
	if err := s.store.update(func(d *diskState) {
		u := Usage{Month: month(now)}
		if d.Usage != nil && d.Usage.Month == month(now) {
			u = *d.Usage
		}
		h := historyUsage(d, now)
		switch {
		case u.USD+s.c.CallCostUSD > s.c.MonthlyBudgetUSD:
			r := historyFailure(429, "budget_exhausted", "The monthly Tesla API budget is spent.", 3600)
			refused = &r
		case h.Calls >= historyDailyCalls:
			r := historyFailure(429, "history_daily_limit", "Today's charging-history calls are used up.", untilTomorrow(now))
			refused = &r
		case h.Month >= historyMonthlyCalls:
			r := historyFailure(429, "history_monthly_limit", "This month's charging-history calls are used up.", 3600)
			refused = &r
		default:
			u.Calls++
			u.USD += s.c.CallCostUSD
			h.Calls++
			h.Month++
			h.Pending = stamp
			d.Usage, d.History = &u, &h
		}
		calls = historyCalls{Today: h.Calls, DailyLimit: historyDailyCalls, Month: h.Month, MonthlyLimit: historyMonthlyCalls}
	}); err != nil {
		// The write may have landed anyway; clear its marker before the next
		// call, since nothing was sent.
		c.historyUnsaved = recordHistory(stamp, nil)
		fail(failure(503, "storage_unavailable", "Cannot safely reserve the history call."))
		return
	}
	if refused != nil {
		fail(*refused)
		return
	}
	// Whatever the reply, its outcome is recorded before the lock is released;
	// if that write fails it is kept in memory and retried before any call.
	var learn func(*HistoryUsage)
	defer func() {
		if record := recordHistory(stamp, learn); s.store.update(record) != nil {
			c.historyUnsaved = record
		}
	}()
	c.historyLast = now
	req, _ := http.NewRequestWithContext(ctx, "GET", t.FleetBase+q.upstream(), nil)
	req.Header.Set("Authorization", "Bearer "+t.Access)
	req.Header.Set("Accept", "application/json")
	res, err := s.collectorClient.Do(req)
	if err != nil {
		fail(failure(504, "tesla_unavailable", "Tesla did not answer; no history was read."))
		return
	}
	// Retry-After delay-seconds count from receipt, not from the request.
	received := clock()
	defer res.Body.Close()
	var until time.Time
	switch res.StatusCode {
	case 429:
		until = retryDeadline(res.Header.Get("Retry-After"), received)
		learn = blockHistory(until)
	case 402:
		until = received.Add(time.Hour).UTC()
		learn = blockHistory(until)
	case 403:
		learn = func(h *HistoryUsage) { h.ScopeMissing = namespace }
	}
	body, err := io.ReadAll(io.LimitReader(res.Body, historyMaxBody+1))
	if s.oauth.Account() != account {
		// The account changed while this read was in flight; drop its reply
		// (a backoff it carried is still recorded above).
		fail(failure(503, "account_changed", "The Tesla account changed; the reply was discarded."))
		return
	}
	switch {
	case res.StatusCode == 401:
		s.oauth.Invalidate()
		fail(failure(503, "history_auth_refreshing", "Tesla authorization is refreshing; retry shortly."))
		return
	case res.StatusCode == 403:
		fail(failure(403, "history_scope_missing", "Tesla refused charging history; reconnect with charging consent."))
		return
	case res.StatusCode == 429:
		fail(historyFailure(429, "tesla_rate_limited", "Tesla asked Volta to wait before reading history again.", secondsUntil(until, received)))
		return
	case res.StatusCode == 402:
		fail(historyFailure(503, "tesla_payment_required", "Tesla refused the call for billing; check the developer account.", 3600))
		return
	case res.StatusCode >= 500:
		fail(failure(502, "tesla_unavailable", "Tesla could not serve history; no rows were read."))
		return
	case res.StatusCode != 200:
		fail(failure(502, "history_rejected", "Tesla rejected the history request ("+strconv.Itoa(res.StatusCode)+")."))
		return
	case err != nil:
		fail(failure(502, "history_invalid_response", "Tesla's history reply could not be read."))
		return
	case len(body) > historyMaxBody:
		fail(failure(502, "history_response_too_large", "Tesla's history reply exceeded 2 MiB."))
		return
	}
	page, err := parseHistory(body, q.pageSize)
	if err != nil {
		fail(failure(502, "history_invalid_response", "Tesla's history reply did not match the documented shape."))
		return
	}
	page.OK, page.Account, page.PageNo, page.PageSize = true, namespace, q.pageNo, q.pageSize
	page.StartTime, page.EndTime = q.start.UTC().Format(time.RFC3339), q.end.UTC().Format(time.RFC3339)
	page.Budget, page.Calls = s.budget(), calls
	sessions = len(page.Sessions)
	writeJSON(w, 200, page)
}
