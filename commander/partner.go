package commander

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

var domainPattern = regexp.MustCompile(`^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$`)

// RegisterPartner performs Tesla's one-time partner registration for the
// domain that hosts the public key, then confirms Tesla read that key. It
// prints nothing: tokens and responses stay in memory.
func RegisterPartner(ctx context.Context, c Config, client *http.Client, domain string) error {
	if !domainPattern.MatchString(domain) {
		return errors.New("TESLA_PARTNER_DOMAIN must be a bare lowercase domain")
	}
	if c.ClientID == "" || c.ClientSecret == "" {
		return errors.New("partner registration requires client credentials")
	}
	form := url.Values{"grant_type": {"client_credentials"}, "client_id": {c.ClientID}, "client_secret": {c.ClientSecret}, "scope": {ReadScopes}, "audience": {c.Audience}}
	req, _ := http.NewRequestWithContext(ctx, "POST", c.TokenURL, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	var token struct {
		Access string `json:"access_token"`
	}
	if status, err := doJSON(client, req, &token); err != nil || status != 200 || token.Access == "" {
		return errors.New("partner token request failed; check client credentials")
	}
	body, _ := json.Marshal(map[string]string{"domain": domain})
	req, _ = http.NewRequestWithContext(ctx, "POST", c.Audience+"/api/1/partner_accounts", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token.Access)
	req.Header.Set("Content-Type", "application/json")
	if status, err := doJSON(client, req, nil); err != nil || status != 200 {
		return errors.New("partner registration failed; check the domain and its public key")
	}
	req, _ = http.NewRequestWithContext(ctx, "GET", c.Audience+"/api/1/partner_accounts/public_key?"+url.Values{"domain": {domain}}.Encode(), nil)
	req.Header.Set("Authorization", "Bearer "+token.Access)
	var key struct {
		Response struct {
			PublicKey string `json:"public_key"`
		} `json:"response"`
	}
	if status, err := doJSON(client, req, &key); err != nil || status != 200 || key.Response.PublicKey == "" {
		return errors.New("registered, but Tesla did not return the domain's public key")
	}
	return nil
}

func doJSON(client *http.Client, req *http.Request, out any) (int, error) {
	res, err := client.Do(req)
	if err != nil {
		return 0, err
	}
	defer res.Body.Close()
	if out == nil {
		_, _ = io.Copy(io.Discard, io.LimitReader(res.Body, 1<<20))
		return res.StatusCode, nil
	}
	return res.StatusCode, json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(out)
}
