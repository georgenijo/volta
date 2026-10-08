package commander

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	NorthAmerica = "https://fleet-api.prd.na.vn.cloud.tesla.com"
	Europe       = "https://fleet-api.prd.eu.vn.cloud.tesla.com"
	// Read-only by default: vehicle data and location. Command scopes are only
	// requested when commands are explicitly enabled, and need a separate
	// virtual-key pairing by the owner.
	ReadScopes    = "openid offline_access vehicle_device_data vehicle_location"
	CommandScopes = "vehicle_cmds vehicle_charging_cmds"
	// Tesla offers no history-only scope: charging history and billing need
	// vehicle_charging_cmds, which also authorizes charging commands at Tesla.
	// Volta never sends those unless COMMANDER_COMMANDS_ENABLED is set.
	HistoryScopes = "vehicle_charging_cmds"
	AppCallback   = "volta://tesla-callback"
)

func RequestedScopes(c Config) string {
	switch {
	case c.Enabled:
		return ReadScopes + " " + CommandScopes
	case c.HistoryEnabled:
		return ReadScopes + " " + HistoryScopes
	}
	return ReadScopes
}

var vinPattern = regexp.MustCompile(`^[A-HJ-NPR-Z0-9]{17}$`)
var idPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
var redirectPath = regexp.MustCompile(`^(/[A-Za-z0-9_-]+)+$`)

type Config struct {
	Mode, Listen, CallbackListen, Secret, DataDir                          string
	EncryptionKey                                                          []byte
	ClientID, ClientSecret, RedirectURI                                    string
	AuthorizeURL, TokenURL, Audience, ProxyURL, ProxyCAFile, PublicKeyFile string
	Vehicles                                                               map[string]string
	Enabled                                                                bool
	// HistoryEnabled allows operator-triggered charging-history reads. It is
	// independent of Enabled and never enables commands or the signing proxy.
	HistoryEnabled                            bool
	OAuthEnabled                              bool
	RateLimit                                 int
	WakeTimeout, WakeInterval, CommandTimeout time.Duration
	CollectorEnabled                          bool
	CollectorListen, CollectorSecret          string
	MonthlyBudgetUSD, CallCostUSD             float64
	CacheTTL                                  time.Duration
	TelemetryEnabled                          bool
	TelemetryMeterURL, TelemetryMeterSecret   string
	TelemetryHostname, TelemetryCAFile        string
	TelemetryPort                             int
	TelemetryWarnUSD, TelemetryStopUSD        float64
	TelemetryCapUSD, TotalMonthlyCapUSD       float64
	TelemetryDeleteReserveUSD                 float64
	TelemetryRefresh, TelemetryMaxAge         time.Duration
}

// Production endpoint overrides are deliberately unavailable. Only the explicit
// stub mode can direct tokens to loopback test servers.
func ConfigFromEnv() (Config, error) {
	c := Config{Mode: env("COMMANDER_MODE", "stub"), Listen: env("COMMANDER_LISTEN", "127.0.0.1:8090"), CallbackListen: env("COMMANDER_CALLBACK_LISTEN", "127.0.0.1:8091"), Secret: os.Getenv("COMMANDER_INTERNAL_SECRET"), DataDir: env("COMMANDER_DATA_DIR", "./data"), ClientID: os.Getenv("TESLA_CLIENT_ID"), ClientSecret: os.Getenv("TESLA_CLIENT_SECRET"), RedirectURI: os.Getenv("TESLA_REDIRECT_URI"), Audience: env("TESLA_AUDIENCE", NorthAmerica), ProxyURL: env("TESLA_PROXY_URL", "https://localhost:4443"), ProxyCAFile: os.Getenv("TESLA_PROXY_CA_FILE"), PublicKeyFile: os.Getenv("TESLA_PUBLIC_KEY_FILE"), Enabled: os.Getenv("COMMANDER_COMMANDS_ENABLED") == "true", RateLimit: 6, WakeTimeout: 30 * time.Second, WakeInterval: 2 * time.Second, CommandTimeout: 65 * time.Second}
	c.OAuthEnabled = c.Enabled || os.Getenv("COMMANDER_OAUTH_ENABLED") == "true"
	c.HistoryEnabled = os.Getenv("COMMANDER_CHARGING_HISTORY_ENABLED") == "true"
	c.CollectorEnabled = os.Getenv("COMMANDER_COLLECTOR_ENABLED") == "true"
	c.TelemetryEnabled = os.Getenv("COMMANDER_TELEMETRY_ENABLED") == "true"
	c.CollectorListen = env("COMMANDER_COLLECTOR_LISTEN", "127.0.0.1:8092")
	c.CollectorSecret = os.Getenv("COMMANDER_COLLECTOR_SECRET")
	// Fleet API bills data requests at 500 per US dollar. The cap is an estimate
	// kept locally; Tesla's account billing limit remains the hard backstop.
	c.CallCostUSD = 1.0 / 500
	var err error
	pollingDefault := "20"
	if c.TelemetryEnabled {
		pollingDefault = "5"
	}
	if c.MonthlyBudgetUSD, err = strconv.ParseFloat(env("COMMANDER_MONTHLY_BUDGET_USD", pollingDefault), 64); err != nil || c.MonthlyBudgetUSD < 0 || c.MonthlyBudgetUSD > 1000 {
		return c, errors.New("COMMANDER_MONTHLY_BUDGET_USD must be between 0 and 1000")
	}
	seconds, err := strconv.Atoi(env("COMMANDER_CACHE_SECONDS", "60"))
	if err != nil || seconds < 15 || seconds > 3600 {
		return c, errors.New("COMMANDER_CACHE_SECONDS must be between 15 and 3600")
	}
	c.CacheTTL = time.Duration(seconds) * time.Second
	c.TelemetryMeterURL = env("COMMANDER_TELEMETRY_METER_URL", "http://consumer:8449/v1/usage")
	c.TelemetryMeterSecret = os.Getenv("COMMANDER_TELEMETRY_METER_SECRET")
	c.TelemetryHostname = os.Getenv("COMMANDER_TELEMETRY_HOSTNAME")
	c.TelemetryCAFile = os.Getenv("COMMANDER_TELEMETRY_CA_FILE")
	c.TelemetryPort = 10000
	if v := os.Getenv("COMMANDER_TELEMETRY_PORT"); v != "" {
		c.TelemetryPort, err = strconv.Atoi(v)
		if err != nil || c.TelemetryPort < 1 || c.TelemetryPort > 65535 {
			return c, errors.New("COMMANDER_TELEMETRY_PORT must be between 1 and 65535")
		}
	}
	parseMoney := func(key, fallback string) (float64, error) {
		v, e := strconv.ParseFloat(env(key, fallback), 64)
		if e != nil || v < 0 || v > 1000 {
			return 0, errors.New(key + " must be between 0 and 1000")
		}
		return v, nil
	}
	if c.TelemetryWarnUSD, err = parseMoney("COMMANDER_TELEMETRY_WARN_USD", "20"); err != nil {
		return c, err
	}
	if c.TelemetryStopUSD, err = parseMoney("COMMANDER_TELEMETRY_STOP_USD", "23"); err != nil {
		return c, err
	}
	if c.TelemetryCapUSD, err = parseMoney("COMMANDER_TELEMETRY_CAP_USD", "25"); err != nil {
		return c, err
	}
	if c.TotalMonthlyCapUSD, err = parseMoney("COMMANDER_TOTAL_MONTHLY_CAP_USD", "30"); err != nil {
		return c, err
	}
	if c.TelemetryDeleteReserveUSD, err = parseMoney("COMMANDER_TELEMETRY_DELETE_RESERVE_USD", "2"); err != nil {
		return c, err
	}
	c.TelemetryRefresh = 15 * time.Second
	c.TelemetryMaxAge = 2 * time.Minute
	if file := os.Getenv("COMMANDER_TELEMETRY_METER_SECRET_FILE"); c.TelemetryEnabled && file != "" {
		if c.TelemetryMeterSecret != "" {
			return c, errors.New("set COMMANDER_TELEMETRY_METER_SECRET or COMMANDER_TELEMETRY_METER_SECRET_FILE, not both")
		}
		b, readErr := os.ReadFile(file)
		if readErr != nil {
			return c, errors.New("cannot read COMMANDER_TELEMETRY_METER_SECRET_FILE")
		}
		c.TelemetryMeterSecret = strings.TrimRight(string(b), "\r\n")
		if c.TelemetryMeterSecret == "" || strings.ContainsAny(c.TelemetryMeterSecret, "\r\n") {
			return c, errors.New("COMMANDER_TELEMETRY_METER_SECRET_FILE must contain exactly one value")
		}
	}
	if file := os.Getenv("TESLA_CLIENT_SECRET_FILE"); file != "" {
		if c.ClientSecret != "" {
			return c, errors.New("set TESLA_CLIENT_SECRET or TESLA_CLIENT_SECRET_FILE, not both")
		}
		b, err := os.ReadFile(file)
		if err != nil {
			return c, errors.New("cannot read TESLA_CLIENT_SECRET_FILE")
		}
		c.ClientSecret = strings.TrimRight(string(b), "\r\n")
		if c.ClientSecret == "" || strings.ContainsAny(c.ClientSecret, "\r\n") {
			return c, errors.New("TESLA_CLIENT_SECRET_FILE must contain exactly one value")
		}
	}
	if c.Mode != "live" && c.Mode != "stub" {
		return c, errors.New("COMMANDER_MODE must be live or stub")
	}
	if len(c.Secret) < 32 {
		return c, errors.New("COMMANDER_INTERNAL_SECRET must contain at least 32 characters")
	}
	if c.CollectorEnabled && (len(c.CollectorSecret) < 32 || c.CollectorSecret == c.Secret) {
		return c, errors.New("COMMANDER_COLLECTOR_SECRET must contain at least 32 characters and differ from the internal secret")
	}
	if c.TelemetryEnabled {
		c.OAuthEnabled = true
	}
	if c.CollectorEnabled && !c.OAuthEnabled {
		return c, errors.New("the collector requires COMMANDER_OAUTH_ENABLED=true")
	}
	if c.HistoryEnabled && !c.OAuthEnabled {
		return c, errors.New("charging history requires COMMANDER_OAUTH_ENABLED=true")
	}
	c.EncryptionKey, err = base64.StdEncoding.DecodeString(os.Getenv("COMMANDER_ENCRYPTION_KEY"))
	if err != nil || len(c.EncryptionKey) != 32 {
		return c, errors.New("COMMANDER_ENCRYPTION_KEY must be base64 of 32 random bytes")
	}
	if err = json.Unmarshal([]byte(env("COMMANDER_VEHICLES", "{}")), &c.Vehicles); err != nil || c.Vehicles == nil {
		return c, errors.New("COMMANDER_VEHICLES must be a JSON object mapping Volta IDs to VINs")
	}
	for id, vin := range c.Vehicles {
		if !idPattern.MatchString(id) || !vinPattern.MatchString(vin) {
			return c, errors.New("invalid vehicle ID or VIN in COMMANDER_VEHICLES")
		}
	}
	c.AuthorizeURL = "https://auth.tesla.com/oauth2/v3/authorize"
	c.TokenURL = "https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token"
	c.ProxyURL = strings.TrimSuffix(c.ProxyURL, "/")
	if c.Mode == "stub" {
		base := strings.TrimSuffix(env("COMMANDER_STUB_URL", "http://127.0.0.1:19090"), "/")
		if !loopbackURL(base, false) {
			return c, errors.New("stub URL must be loopback HTTP(S)")
		}
		c.AuthorizeURL, c.TokenURL, c.Audience, c.ProxyURL = base+"/authorize", base+"/token", base, base
	} else {
		if !validFleetBase(c.Audience) {
			return c, errors.New("TESLA_AUDIENCE must be the documented NA or EU Fleet URL")
		}
		// Read-only collection never signs commands, so it needs no proxy.
		if (c.Enabled || c.TelemetryEnabled) && (!internalProxyURL(c.ProxyURL) || c.ProxyCAFile == "") {
			return c, errors.New("live proxy must use HTTPS on loopback or tesla-command-proxy:4443 and TESLA_PROXY_CA_FILE")
		}
	}
	if c.OAuthEnabled && (c.ClientID == "" || c.ClientSecret == "") {
		return c, errors.New("enabled OAuth requires client credentials")
	}
	if c.Enabled && len(c.Vehicles) == 0 {
		return c, errors.New("enabled commands require at least one vehicle mapping")
	}
	if c.TelemetryEnabled {
		if len(c.Vehicles) == 0 {
			return c, errors.New("telemetry requires at least one vehicle mapping")
		}
		if len(c.TelemetryMeterSecret) < 32 || c.TelemetryMeterSecret == c.Secret || c.TelemetryMeterSecret == c.CollectorSecret {
			return c, errors.New("COMMANDER_TELEMETRY_METER_SECRET must contain at least 32 characters and differ from other secrets")
		}
		if !internalMeterURL(c.TelemetryMeterURL) {
			return c, errors.New("COMMANDER_TELEMETRY_METER_URL must be the internal consumer usage endpoint or loopback")
		}
		if c.TelemetryCAFile == "" || !regexp.MustCompile(`^[A-Za-z0-9.-]+$`).MatchString(c.TelemetryHostname) {
			return c, errors.New("COMMANDER_TELEMETRY_HOSTNAME (the node's full ts.net name) and COMMANDER_TELEMETRY_CA_FILE are required")
		}
		if !(c.TelemetryWarnUSD < c.TelemetryStopUSD && c.TelemetryStopUSD < c.TelemetryCapUSD && c.TelemetryCapUSD+c.MonthlyBudgetUSD <= c.TotalMonthlyCapUSD && c.TelemetryDeleteReserveUSD > 0 && c.TelemetryStopUSD+c.MonthlyBudgetUSD <= c.TotalMonthlyCapUSD-c.TelemetryDeleteReserveUSD) {
			return c, errors.New("telemetry budgets must preserve warning, stop, cap, polling, total, and delete-reserve ordering")
		}
	}
	if c.RedirectURI != "" {
		u, err := url.Parse(c.RedirectURI)
		if err != nil || !redirectPath.MatchString(u.Path) || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || u.User != nil || u.Host == "" || (u.Scheme != "https" && !(c.Mode == "stub" && loopbackURL(u.Scheme+"://"+u.Host, false))) {
			return c, errors.New("redirect URI must be an HTTPS URL with a plain path and no query (stub permits loopback HTTP)")
		}
	}
	if c.OAuthEnabled && c.RedirectURI == "" {
		return c, errors.New("TESLA_REDIRECT_URI required")
	}
	return c, nil
}

func internalMeterURL(s string) bool {
	u, err := url.Parse(s)
	if err != nil || u.Scheme != "http" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Path != "/v1/usage" {
		return false
	}
	if u.Host == "consumer:8449" {
		return true
	}
	ip := net.ParseIP(u.Hostname())
	return ip != nil && ip.IsLoopback()
}

func internalProxyURL(s string) bool {
	if loopbackURL(s, true) {
		return true
	}
	return s == "https://tesla-command-proxy:4443"
}

func env(k, fallback string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return fallback
}
func validFleetBase(s string) bool { return s == NorthAmerica || s == Europe }
func loopbackURL(s string, tlsOnly bool) bool {
	u, err := url.Parse(s)
	if err != nil || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return false
	}
	if u.Scheme != "https" && (tlsOnly || u.Scheme != "http") {
		return false
	}
	if u.Hostname() == "localhost" {
		return true
	}
	ip := net.ParseIP(u.Hostname())
	return ip != nil && ip.IsLoopback()
}

func HTTPClient(c Config) (*http.Client, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	// Never forward Tesla credentials through an ambient HTTP proxy.
	transport.Proxy = nil
	if c.ProxyCAFile != "" {
		pem, err := os.ReadFile(c.ProxyCAFile)
		if err != nil {
			return nil, errors.New("cannot read proxy CA")
		}
		roots, err := x509.SystemCertPool()
		if err != nil {
			roots = x509.NewCertPool()
		}
		if !roots.AppendCertsFromPEM(pem) {
			return nil, errors.New("invalid proxy CA")
		}
		transport.TLSClientConfig = &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}
	}
	return &http.Client{Transport: transport, Timeout: 15 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}, nil
}

func fleetBase(c Config, s string) bool {
	if c.Mode == "stub" {
		return s == c.Audience && strings.HasPrefix(s, "http")
	}
	return validFleetBase(s)
}
