// Loopback-only fixture. It does not contact Tesla or sign commands.
package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
)

func main() {
	const base = "http://127.0.0.1:19090"
	var mu sync.Mutex
	challenges := map[string]string{}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /authorize", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		u, err := url.Parse(q.Get("redirect_uri"))
		if err != nil || u.Scheme != "http" || u.Host != "127.0.0.1:8091" || u.Path != "/volta/oauth/callback" || q.Get("code_challenge_method") != "S256" {
			http.Error(w, "invalid fixture authorize", 400)
			return
		}
		code := q.Get("state")
		mu.Lock()
		challenges[code] = q.Get("code_challenge")
		mu.Unlock()
		v := url.Values{"state": {q.Get("state")}, "code": {code}}
		u.RawQuery = v.Encode()
		http.Redirect(w, r, u.String(), 302)
	})
	mux.HandleFunc("POST /token", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		if r.Form.Get("grant_type") == "authorization_code" {
			mu.Lock()
			challenge, ok := challenges[r.Form.Get("code")]
			delete(challenges, r.Form.Get("code"))
			mu.Unlock()
			sum := sha256.Sum256([]byte(r.Form.Get("code_verifier")))
			if !ok || challenge != base64.RawURLEncoding.EncodeToString(sum[:]) {
				http.Error(w, "invalid fixture verifier", 400)
				return
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"access_token": "STUB_ACCESS_ONLY", "refresh_token": "STUB_REFRESH_ONLY", "expires_in": 3600})
	})
	mux.HandleFunc("GET /api/1/users/region", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"response": map[string]string{"region": "stub", "fleet_api_base_url": base}})
	})
	mux.HandleFunc("GET /api/1/products", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer STUB_ACCESS_ONLY" {
			http.Error(w, "fixture token required", 401)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"response": []map[string]any{{"id": 1, "vehicle_id": 2, "vin": "5YJ3E1EA7KF000001", "display_name": "Fixture", "state": "online"}}, "count": 1})
	})
	mux.HandleFunc("/api/1/vehicles/", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer STUB_ACCESS_ONLY" {
			http.Error(w, "fixture token required", 401)
			return
		}
		if strings.HasSuffix(r.URL.Path, "/wake_up") || r.Method == "GET" {
			_ = json.NewEncoder(w).Encode(map[string]any{"response": map[string]string{"state": "online"}})
			return
		}
		if r.Method != "POST" {
			http.Error(w, "method", 405)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"response": map[string]any{"result": true, "reason": ""}})
	})
	log.Print("fake Fleet fixture listening on loopback :19090; no real commands")
	log.Fatal(http.ListenAndServe("127.0.0.1:19090", mux))
}
