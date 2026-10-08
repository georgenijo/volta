package commander

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"slices"
	"strconv"
	"time"
)

var keyPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{16,128}$`)

type Service struct {
	c         Config
	store     *Store
	oauth     *OAuth
	fleet     *Fleet
	audit     *slog.Logger
	commands  chan struct{}
	publicKey []byte
	collector collector
	// Data reads never use the command proxy or its CA.
	collectorClient *http.Client
}

func NewService(c Config, store *Store, client *http.Client, audit *slog.Logger) (*Service, error) {
	s := &Service{c: c, store: store, oauth: NewOAuth(c, store, client), fleet: &Fleet{c: c, client: client}, audit: audit, commands: make(chan struct{}, 1), collector: collector{cache: map[string]cached{}, served: map[string]time.Time{}, refused: map[string]time.Time{}}, collectorClient: client}
	if c.PublicKeyFile != "" {
		b, err := os.ReadFile(c.PublicKeyFile)
		if err != nil {
			return nil, errors.New("cannot read public key")
		}
		block, rest := pem.Decode(b)
		if block == nil || block.Type != "PUBLIC KEY" || len(rest) != 0 {
			return nil, errors.New("expected a single public-key PEM, never a private key")
		}
		key, err := x509.ParsePKIXPublicKey(block.Bytes)
		if err != nil {
			return nil, errors.New("invalid public key")
		}
		ec, ok := key.(*ecdsa.PublicKey)
		if !ok || ec.Curve != elliptic.P256() {
			return nil, errors.New("public key must be P-256")
		}
		s.publicKey = b
	}
	return s, nil
}

func (s *Service) PrivateHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"ok": true, "mode": s.c.Mode, "commandsEnabled": s.c.Enabled, "historyEnabled": s.c.HistoryEnabled, "oauthEnabled": s.c.OAuthEnabled, "authorized": s.store.tokens() != nil})
	})
	mux.HandleFunc("GET /oauth/status", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, s.linkStatus())
	})
	mux.HandleFunc("POST /oauth/start", func(w http.ResponseWriter, r *http.Request) {
		p, ok := linkParams(w, r, "deviceId")
		if !ok {
			return
		}
		u, expires, err := s.oauth.Start(p["deviceId"])
		s.audit.Info("oauth_start", "device", p["deviceId"], "code", resultCodePtr(err))
		if err != nil {
			writeResult(w, *err)
			return
		}
		writeJSON(w, 200, map[string]any{"authorizationUrl": u, "callbackScheme": "volta", "expiresAt": expires.UTC().Format(time.RFC3339)})
	})
	mux.HandleFunc("POST /oauth/complete", func(w http.ResponseWriter, r *http.Request) {
		p, ok := linkParams(w, r, "deviceId", "state", "code", "error")
		if !ok {
			return
		}
		ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 30*time.Second)
		defer cancel()
		result := s.oauth.Complete(ctx, p["deviceId"], p["state"], p["code"], p["error"])
		s.audit.Info("oauth_complete", "device", p["deviceId"], "code", resultCode(result))
		if result.OK {
			s.markLinked()
		}
		if !result.OK {
			writeResult(w, result)
			return
		}
		writeJSON(w, 200, s.linkStatus())
	})
	mux.HandleFunc("POST /oauth/cancel", func(w http.ResponseWriter, r *http.Request) {
		p, ok := linkParams(w, r, "deviceId")
		if !ok {
			return
		}
		writeResult(w, s.oauth.Cancel(p["deviceId"]))
	})
	mux.HandleFunc("DELETE /oauth/account", func(w http.ResponseWriter, r *http.Request) {
		if err := s.acquireCommand(r.Context()); err != nil {
			writeResult(w, *err)
			return
		}
		defer s.releaseCommand()
		result := s.oauth.Disconnect()
		s.audit.Info("oauth_disconnected", "code", resultCode(result))
		writeResult(w, result)
	})
	mux.HandleFunc("POST /v1/vehicles/{id}/commands/{name}", s.handleCommand)
	mux.HandleFunc("GET /v1/history/charging", s.handleChargingHistory)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+s.c.Secret)) != 1 {
			s.audit.Warn("internal_auth_rejected")
			writeResult(w, failure(401, "unauthorized", "Internal authentication required."))
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func (s *Service) acquireCommand(ctx context.Context) *Result {
	if ctx.Err() != nil {
		r := failure(408, "request_cancelled", "Request was cancelled before command acceptance.")
		return &r
	}
	timer := time.NewTimer(2 * time.Second)
	defer timer.Stop()
	select {
	case s.commands <- struct{}{}:
		if ctx.Err() != nil {
			s.releaseCommand()
			r := failure(408, "request_cancelled", "Request was cancelled before command acceptance.")
			return &r
		}
		return nil
	case <-ctx.Done():
		r := failure(408, "request_cancelled", "Request was cancelled before command acceptance.")
		return &r
	case <-timer.C:
		r := failure(409, "command_in_progress", "Another command is running; retry this intent shortly.")
		r.RetryAfter = 2
		return &r
	}
}
func (s *Service) releaseCommand() { <-s.commands }

// Separate public surface: the stateless sign-in redirect and the public key.
// It holds no credentials and cannot exchange codes; the command listener is
// never attached to it.
func (s *Service) PublicHandler() http.Handler {
	mux := http.NewServeMux()
	if u, err := url.Parse(s.c.RedirectURI); err == nil && u.Path != "" {
		mux.Handle("GET "+u.Path, CallbackBounce())
	}
	mux.HandleFunc("GET /.well-known/appspecific/com.tesla.3p.public-key.pem", func(w http.ResponseWriter, r *http.Request) {
		if len(s.publicKey) == 0 {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/x-pem-file")
		w.Write(s.publicKey)
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		mux.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func writeResult(w http.ResponseWriter, r Result) {
	if r.RetryAfter > 0 {
		w.Header().Set("Retry-After", strconv.Itoa(r.RetryAfter))
	}
	writeJSON(w, r.Status, r)
}
func resultCodePtr(r *Result) string {
	if r == nil {
		return "ok"
	}
	return resultCode(*r)
}
func resultCode(r Result) string {
	if r.Error != nil {
		return r.Error.Code
	}
	return "ok"
}

// Sign-in relay fields are optional strings from a flat, bounded object.
func linkParams(w http.ResponseWriter, r *http.Request, allowed ...string) (map[string]string, bool) {
	p, err := decodeParams(w, r)
	out := map[string]string{}
	if err == nil {
		for k, v := range p {
			text, isString := v.(string)
			if !isString || !slices.Contains(allowed, k) {
				err = errors.New("unexpected field")
				break
			}
			out[k] = text
		}
	}
	if err != nil {
		writeResult(w, failure(400, "invalid_params", "Expected a flat JSON object of known string fields."))
		return nil, false
	}
	return out, true
}

type statusView struct {
	Available bool `json:"available"`
	LinkStatus
	Collector struct {
		Enabled bool `json:"enabled"`
	} `json:"collector"`
	// Account is the opaque link namespace stored history belongs to; the
	// API keeps it server-side and never forwards it to devices.
	History struct {
		Enabled bool   `json:"enabled"`
		Account string `json:"account,omitempty"`
	} `json:"history"`
	Budget BudgetStatus `json:"budget"`
}

func (s *Service) linkStatus() statusView {
	v := statusView{Available: s.c.OAuthEnabled, LinkStatus: s.oauth.Status(), Budget: s.budget()}
	v.Collector.Enabled = s.c.CollectorEnabled
	v.History.Enabled = s.c.HistoryEnabled
	if v.Connected {
		v.History.Account, _, _ = s.oauth.Namespace()
	}
	return v
}

func hash(s string) string { sum := sha256.Sum256([]byte(s)); return hex.EncodeToString(sum[:]) }

// Flat JSON only, bounded input, no duplicate fields or trailing JSON. This
// keeps both validation and the idempotency fingerprint unambiguous.
func decodeParams(w http.ResponseWriter, r *http.Request) (map[string]any, error) {
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	d.UseNumber()
	t, err := d.Token()
	if err != nil || t != json.Delim('{') {
		return nil, errors.New("expected a JSON object")
	}
	p := map[string]any{}
	for d.More() {
		k, err := d.Token()
		if err != nil {
			return nil, err
		}
		key := k.(string)
		if _, exists := p[key]; exists {
			return nil, errors.New("duplicate parameter")
		}
		var v any
		if err = d.Decode(&v); err != nil {
			return nil, err
		}
		p[key] = v
	}
	if _, err = d.Token(); err != nil {
		return nil, err
	}
	if _, err = d.Token(); err != io.EOF {
		return nil, errors.New("trailing data")
	}
	return p, nil
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func (s *Service) handleCommand(out http.ResponseWriter, r *http.Request) {
	w := &statusWriter{ResponseWriter: out, status: 200}
	defer func() { s.audit.Info("command_request", "httpStatus", w.status) }()
	if !s.c.Enabled {
		writeResult(w, unavailable())
		return
	}
	id, name := r.PathValue("id"), r.PathValue("name")
	vin, ok := s.c.Vehicles[id]
	if !ok {
		writeResult(w, failure(404, "vehicle_not_found", "Vehicle is not configured for commands."))
		return
	}
	key := r.Header.Get("Idempotency-Key")
	if !keyPattern.MatchString(key) {
		writeResult(w, failure(400, "idempotency_key_required", "Idempotency-Key must be 16-128 URL-safe characters."))
		return
	}
	p, err := decodeParams(w, r)
	if err != nil {
		writeResult(w, failure(400, "invalid_params", "Expected a JSON object with unique parameters (maximum 4096 bytes)."))
		return
	}
	c, err := ParseCommand(name, p)
	if err != nil {
		writeResult(w, failure(400, "invalid_command", err.Error()))
		return
	}
	canonical, _ := json.Marshal(c.Params)
	fingerprint := hash(id + "\n" + name + "\n" + string(canonical))
	receiptKey := hash(key)
	requestID := receiptKey[:16]
	// One account, one process, one command at a time. Waiting retries either
	// replay the persisted result or get outcome_unknown after a crash.
	if err := s.acquireCommand(r.Context()); err != nil {
		writeResult(w, *err)
		return
	}
	defer s.releaseCommand()
	d := s.store.snapshot()
	now := time.Now()
	if old, exists := d.Receipts[receiptKey]; exists && now.Sub(old.Created) < 24*time.Hour {
		if old.Fingerprint != fingerprint {
			writeResult(w, failure(409, "idempotency_conflict", "This key was already used for a different command."))
			return
		}
		result := failure(409, "command_outcome_unknown", "Previous command may have run; check the vehicle before trying again.")
		if old.Result != nil {
			result = *old.Result
			result.Status = old.HTTPStatus
			result.RetryAfter = old.RetryAfter
		}
		result.RequestID = requestID
		w.Header().Set("Idempotency-Replayed", "true")
		s.audit.Info("command_replayed", "requestId", requestID, "vehicleId", id, "command", name, "code", resultCode(result))
		writeResult(w, result)
		return
	}
	// Local sliding window survives restarts. Replays don't consume budget.
	rate := []time.Time{}
	for _, t := range d.Rate[id] {
		if now.Sub(t) < time.Minute {
			rate = append(rate, t)
		}
	}
	if len(rate) >= s.c.RateLimit {
		res := failure(429, "rate_limited", "Too many vehicle commands; wait before trying again.")
		res.RetryAfter = int(time.Until(rate[0].Add(time.Minute)).Seconds()) + 1
		writeResult(w, res)
		return
	}
	// After a durable reservation, a network disconnect must not abandon the
	// receipt while the independent upstream proxy keeps executing the command.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), s.c.CommandTimeout)
	defer cancel()
	t, authError := s.oauth.Token(ctx)
	if authError != nil {
		writeResult(w, *authError)
		return
	}
	if r.Context().Err() != nil {
		writeResult(w, failure(408, "request_cancelled", "Request was cancelled before command acceptance."))
		return
	}
	if err = s.store.update(func(d *diskState) {
		for k, v := range d.Receipts {
			if now.Sub(v.Created) >= 24*time.Hour {
				delete(d.Receipts, k)
			}
		}
		d.Receipts[receiptKey] = Receipt{Fingerprint: fingerprint, Created: now}
		d.Rate[id] = append(rate, now)
	}); err != nil {
		writeResult(w, failure(503, "storage_unavailable", "Cannot safely reserve the command."))
		return
	}
	s.audit.Info("command_started", "requestId", requestID, "vehicleId", id, "command", name)
	result := s.fleet.send(ctx, t, vin, c)
	result.Command = name
	result.RequestID = requestID
	if err = s.store.update(func(d *diskState) {
		if result.Error != nil && result.Error.Code == "tesla_rate_limited" {
			delete(d.Receipts, receiptKey)
			return
		}
		receipt := d.Receipts[receiptKey]
		receipt.Result = &result
		receipt.HTTPStatus = result.Status
		receipt.RetryAfter = result.RetryAfter
		d.Receipts[receiptKey] = receipt
	}); err != nil {
		result = failure(503, "command_outcome_unknown", "Command may have run but its result could not be saved; check the vehicle.")
		result.RequestID = requestID
	}
	s.audit.Info("command_completed", "requestId", requestID, "vehicleId", id, "command", name, "code", resultCode(result), "httpStatus", result.Status)
	writeResult(w, result)
}
