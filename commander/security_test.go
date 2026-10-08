package commander

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestRegionalRedirectFormats(t *testing.T) {
	for _, alts := range [][]string{{"h2=" + Europe}, {`h2="fleet-api.prd.eu.vn.cloud.tesla.com:443"; ma=3600`}, {"h2=" + Europe + "; ma=3600"}, {"h2=https://evil.invalid", "h2=" + Europe}} {
		t.Run(strings.Join(alts, "|"), func(t *testing.T) {
			var hits atomic.Int32
			s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
				hits.Add(1)
				if r.Host == strings.TrimPrefix(NorthAmerica, "https://") {
					for _, alt := range alts {
						w.Header().Add("Alt-Svc", alt)
					}
					reply(w, 421, `{"error":"misdirected request"}`)
					return
				}
				if r.Host != strings.TrimPrefix(Europe, "https://") {
					t.Error("unexpected regional host", r.Host)
				}
				reply(w, 200, fmt.Sprintf(`{"response":{"region":"eu","fleet_api_base_url":%q}}`, Europe))
			})
			// Every request is rewritten to the httptest fixture. No Tesla hostname
			// is resolved or contacted; original authority is the fixture Host.
			fixtureURL, _ := url.Parse(up.URL)
			s.oauth.c.Mode = "live"
			s.oauth.c.Audience = NorthAmerica
			s.oauth.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				copy := r.Clone(r.Context())
				copy.Host = r.URL.Host
				copy.URL.Scheme = fixtureURL.Scheme
				copy.URL.Host = fixtureURL.Host
				return up.Client().Do(copy)
			})}
			authorize(t, store, "")
			tok, err := s.oauth.Token(context.Background())
			if err != nil || tok.FleetBase != Europe || hits.Load() != 2 {
				t.Fatal("regional redirect failed", err, hits.Load())
			}
		})
	}
}

func TestRegionalRedirectRejectsUntrustedTargets(t *testing.T) {
	for _, values := range [][]string{{"h2=https://evil.invalid"}, {"h2=" + Europe + ".evil.invalid"}, {`h2="fleet-api.prd.eu.vn.cloud.tesla.com:443.evil"`}, {"h2=" + Europe + "/private"}} {
		if _, ok := regionalAltSvc(values); ok {
			t.Fatal("untrusted redirect accepted", values)
		}
	}
}

func TestStorageFailurePreventsCommandAndRefreshReuse(t *testing.T) {
	var hits atomic.Int32
	s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		if r.URL.Path != "/token" {
			t.Error("physical command sent during storage failure")
		}
		reply(w, 200, `{"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":3600}`)
	})
	authorize(t, store, up.URL)
	// Fail before sending with an impossible state path; retain valid disk state.
	oldPath := store.path
	store.path = filepath.Join(oldPath, "impossible-child")
	assertCode(t, call(s, "lock", "{}", "storage-fixture-01"), 503, "storage_unavailable")
	if hits.Load() != 0 {
		t.Fatal("reservation did not fail closed")
	}
	store.path = oldPath
	tokens := store.tokens()
	tokens.Expires = time.Now()
	if err := store.saveTokens(tokens); err != nil {
		t.Fatal(err)
	}
	store.path = filepath.Join(oldPath, "impossible-child")
	_, err := s.oauth.Token(context.Background())
	if err == nil || err.Error.Code != "storage_unavailable" {
		t.Fatal("rotation storage failure not surfaced")
	}
	_, err = s.oauth.Token(context.Background())
	if err == nil || hits.Load() != 1 {
		t.Fatal("consumed refresh token reused")
	}
	store.path = oldPath
	token, err := s.oauth.Token(context.Background())
	if err != nil || token.Access != "rotated-access" || store.tokens().Refresh != "rotated-refresh" || hits.Load() != 1 {
		t.Fatal("in-memory rotation not recovered safely", err)
	}
}

func TestPublicKeyRejectsPrivateAndServesOnlyPublic(t *testing.T) {
	s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) { t.Error("public-key hosting contacted Fleet") })
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	private, _ := x509.MarshalECPrivateKey(key)
	path := filepath.Join(dir, "key.pem")
	if err = os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: private}), 0600); err != nil {
		t.Fatal(err)
	}
	c := s.c
	c.PublicKeyFile = path
	if _, err = NewService(c, store, up.Client(), slog.New(slog.NewJSONHandler(io.Discard, nil))); err == nil {
		t.Fatal("private key allowed on public route")
	}
	pub, _ := x509.MarshalPKIXPublicKey(&key.PublicKey)
	public := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pub})
	_ = os.WriteFile(path, public, 0600)
	svc, err := NewService(c, store, up.Client(), slog.New(slog.NewJSONHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("GET", "/.well-known/appspecific/com.tesla.3p.public-key.pem", nil)
	w := httptest.NewRecorder()
	svc.PublicHandler().ServeHTTP(w, r)
	if w.Code != 200 || !bytes.Equal(w.Body.Bytes(), public) {
		t.Fatal("wrong public export")
	}
	for _, route := range []string{"/v1/health", "/oauth/start", "/oauth/account", "/api/1/vehicles/" + testVIN + "/command/door_unlock"} {
		r = httptest.NewRequest("GET", route, nil)
		w = httptest.NewRecorder()
		svc.PublicHandler().ServeHTTP(w, r)
		if w.Code != 404 {
			t.Fatal("unexpected public route", route)
		}
	}
}

func TestHTTPClientTrustAndNoRedirect(t *testing.T) {
	var leaked atomic.Int32
	evil := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { leaked.Add(1) }))
	defer evil.Close()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, evil.URL, http.StatusTemporaryRedirect)
	}))
	defer server.Close()
	dir := t.TempDir()
	certPath := filepath.Join(dir, "cert.pem")
	_ = os.WriteFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw}), 0600)
	client, err := HTTPClient(Config{ProxyCAFile: certPath})
	if err != nil {
		t.Fatal(err)
	}
	r, _ := http.NewRequest("POST", server.URL, strings.NewReader("{}"))
	r.Header.Set("Authorization", "Bearer FIXTURE_MUST_NOT_LEAK")
	res, err := client.Do(r)
	if err != nil {
		t.Fatal("pinned TLS trust failed", err)
	}
	res.Body.Close()
	if res.StatusCode != 307 || leaked.Load() != 0 {
		t.Fatal("redirect leaked credentials")
	}
	untrusted, _ := HTTPClient(Config{})
	if res, err := untrusted.Get(server.URL); err == nil {
		res.Body.Close()
		t.Fatal("untrusted TLS accepted")
	}
}

func TestExpiredLoginAndDisconnectPreserveReceipts(t *testing.T) {
	s, store, up, _ := fixture(t, func(w http.ResponseWriter, r *http.Request) { reply(w, 200, `{"response":{"result":true}}`) })
	link, _, err := s.oauth.Start("7")
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(link)
	state := u.Query().Get("state")
	_ = store.update(func(d *diskState) { d.Link.Expires = time.Now().Add(-time.Second) })
	if res := s.oauth.Complete(context.Background(), "7", state, "fixture-code", ""); res.Error == nil || res.Error.Code != "oauth_state_invalid" {
		t.Fatal("expired state accepted")
	}
	authorize(t, store, up.URL)
	if call(s, "honk", "{}", "disconnect-fixture-01").Code != 200 {
		t.Fatal("initial command failed")
	}
	if res := s.oauth.Disconnect(); !res.OK {
		t.Fatal(res)
	}
	if store.tokens() != nil || len(store.snapshot().Receipts) != 1 || len(store.snapshot().Rate["1"]) != 1 {
		t.Fatal("disconnect erased safety state")
	}
	w := call(s, "honk", "{}", "disconnect-fixture-01")
	if w.Code != 200 || w.Header().Get("Idempotency-Replayed") != "true" {
		t.Fatal("disconnect lost replay")
	}
}
