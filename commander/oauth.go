package commander

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type OAuth struct {
	mu     sync.Mutex
	c      Config
	store  *Store
	client *http.Client
	// Keep a rotated token in memory if its disk write fails; no commands may
	// proceed until persistence succeeds, and the consumed token is not reused.
	unsaved *Tokens
	// Set after Tesla rejects the current access token; forces one refresh.
	stale bool
	// account changes whenever the linked Tesla account may differ (disconnect
	// or a new link), so account-specific caches can be fenced.
	account atomic.Uint64
}

const linkLifetime = 10 * time.Minute

var devicePattern = regexp.MustCompile(`^[0-9]{1,19}$`)

func NewOAuth(c Config, s *Store, client *http.Client) *OAuth {
	return &OAuth{c: c, store: s, client: client}
}

// Local disconnect preserves all command receipts and rate counters. Revoking
// the application's consent and vehicle key remains an owner action in Tesla.
func (o *OAuth) Disconnect() Result {
	o.mu.Lock()
	defer o.mu.Unlock()
	if err := o.store.update(func(d *diskState) { d.Tokens, d.Link, d.Outcome = nil, nil, nil }); err != nil {
		return failure(503, "storage_unavailable", "Cannot safely clear authorization state.")
	}
	o.unsaved = nil
	o.account.Add(1)
	return Result{Status: 200, OK: true}
}

// Account identifies the currently linked account for cache fencing.
func (o *OAuth) Account() uint64 { return o.account.Load() }

// Namespace returns an opaque, persistent key for the current link and the
// in-memory fence it belongs to. It never reveals the token or link ID. Links
// made before LinkID existed get one on first use.
func (o *OAuth) Namespace() (string, uint64, *Result) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if err := o.persist(); err != nil {
		return "", 0, err
	}
	t := o.store.tokens()
	if t == nil {
		r := failure(409, "authorization_required", "Connect your Tesla account first.")
		return "", 0, &r
	}
	if t.ReauthRequired {
		r := failure(409, "reauthorization_required", "Tesla authorization expired or was revoked; reconnect the account.")
		return "", 0, &r
	}
	if t.LinkID == "" {
		t.LinkID = randomString()
		if err := o.store.saveTokens(t); err != nil {
			r := failure(503, "storage_unavailable", "Cannot safely save authorization state.")
			return "", 0, &r
		}
	}
	return hash("volta-tesla-link-namespace-v1\n" + t.LinkID), o.account.Load(), nil
}
func randomString() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic("crypto random unavailable")
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

type LinkStatus struct {
	Connected   bool `json:"connected"`
	NeedsReauth bool `json:"needsReauth"`
	LinkPending bool `json:"linkPending"`
}

func (o *OAuth) Status() LinkStatus {
	o.mu.Lock()
	defer o.mu.Unlock()
	d := o.store.snapshot()
	t := d.Tokens
	if o.unsaved != nil {
		t = o.unsaved
	}
	return LinkStatus{Connected: t != nil && !t.ReauthRequired, NeedsReauth: t != nil && t.ReauthRequired, LinkPending: d.Link != nil && time.Now().Before(d.Link.Expires)}
}

// Start begins a sign-in bound to one paired device. A newer start replaces
// any pending one, so an abandoned browser sheet never blocks a retry.
func (o *OAuth) Start(device string) (string, time.Time, *Result) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if !o.c.OAuthEnabled {
		r := failure(501, "oauth_disabled", "Tesla account linking is not enabled.")
		return "", time.Time{}, &r
	}
	if !devicePattern.MatchString(device) {
		r := failure(400, "invalid_device", "A paired device is required.")
		return "", time.Time{}, &r
	}
	if t := o.store.tokens(); (o.unsaved != nil && !o.unsaved.ReauthRequired) || (t != nil && !t.ReauthRequired) {
		r := failure(409, "already_authorized", "A Tesla account is already connected; disconnect it before changing accounts.")
		return "", time.Time{}, &r
	}
	state, verifier, expires := randomString(), randomString(), time.Now().Add(linkLifetime)
	if err := o.store.update(func(d *diskState) {
		d.Link = &PendingLink{StateHash: hash(state), Verifier: verifier, Device: device, Expires: expires}
		d.Outcome = nil
	}); err != nil {
		r := failure(503, "storage_unavailable", "Cannot safely start sign-in.")
		return "", time.Time{}, &r
	}
	digest := sha256.Sum256([]byte(verifier))
	u, _ := url.Parse(o.c.AuthorizeURL)
	q := u.Query()
	q.Set("client_id", o.c.ClientID)
	q.Set("redirect_uri", o.c.RedirectURI)
	q.Set("response_type", "code")
	q.Set("scope", RequestedScopes(o.c))
	q.Set("state", state)
	q.Set("code_challenge", base64.RawURLEncoding.EncodeToString(digest[:]))
	q.Set("code_challenge_method", "S256")
	q.Set("prompt_missing_scopes", "true")
	u.RawQuery = q.Encode()
	return u.String(), expires, nil
}

// Cancel drops the device's own pending sign-in. Other devices are a no-op.
func (o *OAuth) Cancel(device string) Result {
	o.mu.Lock()
	defer o.mu.Unlock()
	d := o.store.snapshot()
	if d.Link == nil || d.Link.Device != device {
		return Result{Status: 200, OK: true}
	}
	if err := o.store.update(func(d *diskState) { d.Link = nil }); err != nil {
		return failure(503, "storage_unavailable", "Cannot safely cancel sign-in.")
	}
	return Result{Status: 200, OK: true}
}

// Complete finishes the sign-in with the redirect's parameters, relayed by the
// same device that started it. The state is consumed durably before the code
// is exchanged; never log code or state.
func (o *OAuth) Complete(ctx context.Context, device, state, code, providerError string) Result {
	o.mu.Lock()
	defer o.mu.Unlock()
	invalid := failure(400, "oauth_state_invalid", "Sign-in expired or was already used; start again.")
	if !o.c.OAuthEnabled || state == "" || len(state) > 512 || !devicePattern.MatchString(device) {
		return invalid
	}
	stateHash, now := hash(state), time.Now()
	d := o.store.snapshot()
	if out := d.Outcome; out != nil && now.Before(out.Expires) && subtle.ConstantTimeCompare([]byte(stateHash), []byte(out.StateHash)) == 1 {
		if out.Device != device {
			return invalid
		}
		r := out.Result
		r.Status = out.Status
		return r
	}
	l := d.Link
	if l == nil || now.After(l.Expires) || subtle.ConstantTimeCompare([]byte(stateHash), []byte(l.StateHash)) != 1 {
		return invalid
	}
	if l.Device != device {
		return failure(409, "oauth_device_mismatch", "Finish sign-in on the device that started it.")
	}
	if err := o.store.update(func(d *diskState) { d.Link = nil }); err != nil {
		return failure(503, "storage_unavailable", "Cannot safely complete sign-in; try again.")
	}
	result := o.finish(ctx, l, code, providerError)
	if !result.OK && result.Status >= 500 {
		// The link and possibly Tesla's single-use code are spent, so a retry
		// can never succeed. Make the failure terminal: the app starts again.
		result = failure(400, "oauth_link_failed", "Tesla sign-in could not finish; start again.")
	}
	// A failed outcome write only loses replay; the state stays consumed.
	_ = o.store.update(func(d *diskState) {
		d.Outcome = &LinkOutcome{StateHash: stateHash, Device: device, Status: result.Status, Result: result, Expires: now.Add(linkLifetime)}
	})
	return result
}

func (o *OAuth) finish(ctx context.Context, l *PendingLink, code, providerError string) Result {
	if providerError != "" || code == "" || len(code) > 4096 {
		return failure(400, "oauth_denied", "Tesla sign-in was not completed; start again.")
	}
	form := url.Values{"grant_type": {"authorization_code"}, "client_id": {o.c.ClientID}, "client_secret": {o.c.ClientSecret}, "code": {code}, "redirect_uri": {o.c.RedirectURI}, "audience": {o.c.Audience}, "code_verifier": {l.Verifier}}
	t, errResult := o.exchange(ctx, form)
	if errResult != nil {
		if errResult.Error.Code == "reauthorization_required" {
			return failure(400, "oauth_code_rejected", "Tesla rejected the sign-in; start again.")
		}
		return *errResult
	}
	t.LinkID = randomString()
	o.unsaved = t
	if err := o.persist(); err != nil {
		// Never keep an unsaved new account; the earlier state stays on disk.
		o.unsaved = nil
		return *err
	}
	o.account.Add(1)
	// The refresh token is saved first; a failed region lookup is retried on
	// first use and never needs another authorization-code exchange.
	_ = o.discover(ctx, t)
	return Result{Status: 200, OK: true}
}

func (o *OAuth) persist() *Result {
	if o.unsaved == nil {
		return nil
	}
	if err := o.store.saveTokens(o.unsaved); err != nil {
		r := failure(503, "storage_unavailable", "Cannot safely save authorization state.")
		return &r
	}
	o.unsaved = nil
	return nil
}

// Invalidate forces a refresh before the next use, after Tesla returns 401.
func (o *OAuth) Invalidate() { o.mu.Lock(); o.stale = true; o.mu.Unlock() }

// Refresh is on demand and serialized, including token rotation and discovery.
// It never resends a physical command in response to a 401 or timeout.
func (o *OAuth) Token(ctx context.Context) (*Tokens, *Result) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if err := o.persist(); err != nil {
		return nil, err
	}
	t := o.store.tokens()
	if t == nil {
		r := failure(409, "authorization_required", "Connect your Tesla account first.")
		return nil, &r
	}
	if t.ReauthRequired {
		r := failure(409, "reauthorization_required", "Tesla authorization expired or was revoked; reconnect the account.")
		return nil, &r
	}
	if o.stale || time.Until(t.Expires) < o.c.CommandTimeout+time.Minute {
		form := url.Values{"grant_type": {"refresh_token"}, "client_id": {o.c.ClientID}, "refresh_token": {t.Refresh}}
		fresh, err := o.exchange(ctx, form)
		if err != nil {
			if err.Error.Code == "reauthorization_required" {
				t.ReauthRequired = true
				if o.store.saveTokens(t) != nil {
					o.unsaved = t
				}
			}
			return nil, err
		}
		o.stale = false
		fresh.FleetBase, fresh.LinkID = t.FleetBase, t.LinkID
		o.unsaved = fresh
		if err := o.persist(); err != nil {
			return nil, err
		}
		t = fresh
	}
	if t.FleetBase == "" {
		if err := o.discover(ctx, t); err != nil {
			return nil, err
		}
	}
	return t, nil
}

func (o *OAuth) exchange(ctx context.Context, form url.Values) (*Tokens, *Result) {
	req, _ := http.NewRequestWithContext(ctx, "POST", o.c.TokenURL, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := o.client.Do(req)
	if err != nil {
		r := failure(503, "oauth_unavailable", "Tesla authorization is temporarily unavailable.")
		return nil, &r
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		code, status, msg := "oauth_unavailable", 503, "Tesla authorization is temporarily unavailable."
		if res.StatusCode == 400 || res.StatusCode == 401 {
			code, status, msg = "reauthorization_required", 409, "Tesla authorization expired or was revoked; reconnect the account."
		}
		r := failure(status, code, msg)
		return nil, &r
	}
	var body struct {
		Access  string `json:"access_token"`
		Refresh string `json:"refresh_token"`
		Expires int    `json:"expires_in"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&body); err != nil || body.Access == "" || body.Refresh == "" || body.Expires < 1 || body.Expires > 86400 {
		r := failure(502, "oauth_invalid_response", "Tesla returned an invalid authorization response.")
		return nil, &r
	}
	return &Tokens{Access: body.Access, Refresh: body.Refresh, Expires: time.Now().Add(time.Duration(body.Expires) * time.Second)}, nil
}

func (o *OAuth) discover(ctx context.Context, t *Tokens) *Result {
	base := o.c.Audience
	for attempt := 0; attempt < 2; attempt++ {
		req, _ := http.NewRequestWithContext(ctx, "GET", base+"/api/1/users/region", nil)
		req.Header.Set("Authorization", "Bearer "+t.Access)
		res, err := o.client.Do(req)
		if err != nil {
			r := failure(503, "region_unavailable", "Cannot discover the Tesla account region.")
			return &r
		}
		if res.StatusCode == 421 && attempt == 0 {
			// Fleet documents Alt-Svc regional redirection. Only two exact Tesla
			// hosts are accepted; no token can follow arbitrary upstream URLs.
			altValues := res.Header.Values("Alt-Svc")
			res.Body.Close()
			var found bool
			base, found = regionalAltSvc(altValues)
			if !found {
				r := failure(502, "region_unavailable", "Tesla returned an unsupported regional redirect.")
				return &r
			}
			continue
		}
		var body struct {
			Response struct {
				Base string `json:"fleet_api_base_url"`
			} `json:"response"`
		}
		err = json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&body)
		res.Body.Close()
		if res.StatusCode != 200 || err != nil || !fleetBase(o.c, body.Response.Base) {
			r := failure(502, "region_unavailable", "Tesla returned an unsupported account region.")
			return &r
		}
		t.FleetBase = body.Response.Base
		o.unsaved = t
		return o.persist()
	}
	r := failure(502, "region_unavailable", "Tesla region discovery failed.")
	return &r
}

func regionalAltSvc(values []string) (string, bool) {
	for _, value := range values {
		for _, entry := range strings.Split(value, ",") {
			entry = strings.TrimSpace(strings.SplitN(entry, ";", 2)[0])
			for _, candidate := range []string{NorthAmerica, Europe} {
				host := strings.TrimPrefix(candidate, "https://")
				if entry == "h2="+candidate || entry == "h2="+candidate+"/" || entry == `h2="`+host+`:443"` || entry == `h2="`+host+`"` {
					return candidate, true
				}
			}
		}
	}
	return "", false
}
