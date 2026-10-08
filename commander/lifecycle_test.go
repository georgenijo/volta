package commander

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func TestOfflineThenOnlineWake(t *testing.T) {
	var commands, polls atomic.Int32
	s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "/command/"):
			if commands.Add(1) == 1 {
				reply(w, 408, `{"error":"vehicle is offline or asleep"}`)
			} else {
				reply(w, 200, `{"response":{"result":true}}`)
			}
		case strings.HasSuffix(r.URL.Path, "/wake_up"):
			reply(w, 200, `{"response":{"state":"offline"}}`)
		default:
			if polls.Add(1) == 1 {
				reply(w, 200, `{"response":{"state":"offline"}}`)
			} else {
				reply(w, 200, `{"response":{"state":"online"}}`)
			}
		}
	})
	authorize(t, store, up.URL)
	w := call(s, "lock", "{}", "offline-online-fixture")
	if w.Code != 200 || commands.Load() != 2 || polls.Load() != 2 {
		t.Fatal("offline wake failed", w.Code, w.Body.String())
	}
}

func commandRequest(s *Service, ctx context.Context, key string) *http.Request {
	r := httptest.NewRequest("POST", "/v1/vehicles/1/commands/honk", strings.NewReader("{}")).WithContext(ctx)
	r.Header.Set("Authorization", "Bearer "+s.c.Secret)
	r.Header.Set("Idempotency-Key", key)
	return r
}

func TestCancelledBeforeReservation(t *testing.T) {
	for _, when := range []string{"before-lock", "during-auth"} {
		t.Run(when, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var hits atomic.Int32
			s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
				hits.Add(1)
				if r.URL.Path != "/token" {
					t.Error("cancelled command was sent")
				}
				cancel()
				reply(w, 200, `{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}`)
			})
			authorize(t, store, up.URL)
			if when == "before-lock" {
				cancel()
			} else {
				tok := store.tokens()
				tok.Expires = time.Now()
				_ = store.saveTokens(tok)
			}
			w := httptest.NewRecorder()
			s.PrivateHandler().ServeHTTP(w, commandRequest(s, ctx, "cancelled-fixture-01"))
			assertCode(t, w, 408, "request_cancelled")
			d := store.snapshot()
			if len(d.Receipts) != 0 || len(d.Rate) != 0 {
				t.Fatal("cancelled request reserved or rate charged")
			}
			if when == "before-lock" && hits.Load() != 0 {
				t.Fatal("cancelled request contacted Tesla")
			}
		})
	}
}

func TestDisconnectMidSendPersistsFinalResult(t *testing.T) {
	started, finish := make(chan struct{}), make(chan struct{})
	var hits atomic.Int32
	s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		close(started)
		<-finish
		reply(w, 200, `{"response":{"result":true}}`)
	})
	authorize(t, store, up.URL)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	w := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		defer close(done)
		s.PrivateHandler().ServeHTTP(w, commandRequest(s, ctx, "disconnect-mid-send-01"))
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		close(finish)
		t.Fatal("send did not start")
	}
	cancel()
	close(finish)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("detached send did not finish")
	}
	if w.Code != 200 {
		t.Fatal("client disconnect abandoned result", w.Code, w.Body.String())
	}
	replay := call(s, "honk", "{}", "disconnect-mid-send-01")
	if replay.Code != 200 || replay.Header().Get("Idempotency-Replayed") != "true" || hits.Load() != 1 {
		t.Fatal("true outcome not replayed")
	}
}

func TestCommandQueueIsBounded(t *testing.T) {
	s, store, _, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) { t.Error("busy queue contacted Fleet") })
	s.commands <- struct{}{}
	defer s.releaseCommand()
	start := time.Now()
	w := call(s, "honk", "{}", "busy-fixture-0001")
	assertCode(t, w, 409, "command_in_progress")
	if time.Since(start) > 4*time.Second || w.Header().Get("Retry-After") != "2" || len(store.snapshot().Receipts) != 0 {
		t.Fatal("unbounded or reserved queue")
	}
}

func TestDialFailureIsDefinitive(t *testing.T) {
	s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) { t.Error("test unexpectedly contacted Fleet") })
	authorize(t, store, up.URL)
	s.fleet.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return nil, &net.OpError{Op: "dial", Err: syscall.ECONNREFUSED}
	})}
	w := call(s, "honk", "{}", "dial-failure-fixture")
	assertCode(t, w, 503, "upstream_unavailable")
	replay := call(s, "honk", "{}", "dial-failure-fixture")
	assertCode(t, replay, 503, "upstream_unavailable")
	if replay.Header().Get("Idempotency-Replayed") != "true" {
		t.Fatal("definitive dial failure receipt missing")
	}
}

func TestTesla429CanRetrySameIntent(t *testing.T) {
	var hits atomic.Int32
	s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		if hits.Add(1) == 1 {
			reply(w, 429, "rate limited")
		} else {
			reply(w, 200, `{"response":{"result":true}}`)
		}
	})
	authorize(t, store, up.URL)
	w := call(s, "honk", "{}", "tesla-limit-fixture")
	assertCode(t, w, 429, "tesla_rate_limited")
	if len(store.snapshot().Receipts) != 0 {
		t.Fatal("429 stuck for 24h")
	}
	// The caller is responsible for Retry-After; exercise re-entry once allowed.
	w = call(s, "honk", "{}", "tesla-limit-fixture")
	if w.Code != 200 || hits.Load() != 2 {
		t.Fatal("definitive rejection blocked retry")
	}
	if call(s, "honk", "{}", "tesla-limit-fixture").Code != 200 || hits.Load() != 2 {
		t.Fatal("successful retry did not deduplicate")
	}
}

func TestTokenRefreshCoversCommandDeadline(t *testing.T) {
	var hits atomic.Int32
	s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		reply(w, 200, `{"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":3600}`)
	})
	authorize(t, store, up.URL)
	s.oauth.c.CommandTimeout = 65 * time.Second
	tok := store.tokens()
	tok.Expires = time.Now().Add(61 * time.Second)
	_ = store.saveTokens(tok)
	token, err := s.oauth.Token(context.Background())
	if err != nil || token.Access != "fresh-access" || hits.Load() != 1 {
		t.Fatal("token may expire mid-command", err)
	}
}

func TestStoreOwnsTokenCopy(t *testing.T) {
	_, store, _, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) { t.Error("copy test contacted Fleet") })
	tok := &Tokens{Access: "original", Refresh: "refresh", FleetBase: NorthAmerica}
	_ = store.saveTokens(tok)
	tok.FleetBase = Europe
	tok.Access = "modified"
	got := store.tokens()
	if got.FleetBase != NorthAmerica || got.Access != "original" {
		t.Fatal("caller aliases store state")
	}
}

func TestAccountLinkingWithCommandsDisabled(t *testing.T) {
	s, _, _, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		t.Error("authorization link or disabled command contacted Fleet")
	})
	s.c.Enabled = false
	s.oauth.c.Enabled = false
	link, _, err := s.oauth.Start("7")
	if err != nil || link == "" {
		t.Fatal("setup linking blocked", err)
	}
	if u, _ := url.Parse(link); u.Query().Get("scope") != ReadScopes {
		t.Fatal("read-only linking requested command scopes")
	}
	assertCode(t, call(s, "lock", "{}", "disabled-link-fixture"), 501, "commands_unavailable")
	s.oauth.c.OAuthEnabled = false
	if _, _, err := s.oauth.Start("7"); err == nil || err.Error.Code != "oauth_disabled" {
		t.Fatal("disabled account linking allowed")
	}
}
