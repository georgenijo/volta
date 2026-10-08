//go:build acceptance

// Package acceptance runs the real pipeline offline: the pinned official
// receiver run by volta-receiver-guard (the production receiver image,
// with the production config plus an appended test CA), the
// pinned Redpanda with the production flags and topic init, Postgres 17
// with the production schema, and the consumer image. Synthetic vehicles
// use fake VINs and a test CA; nothing contacts Tesla or the network.
//
// Run through deploy/telemetry/test/run-acceptance.sh on a Docker host.
// Every container, network and volume is named volta-telemetry-test-*.
package acceptance

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/georgenijo/volta/ingestion/contract"
	"github.com/georgenijo/volta/ingestion/internal/sim"
	"github.com/georgenijo/volta/ingestion/internal/testvin"
	"github.com/georgenijo/volta/ingestion/normalize"
	"github.com/georgenijo/volta/ingestion/store"
	"github.com/georgenijo/volta/ingestion/vehicles"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/teslamotors/fleet-telemetry/protos"
	"gopkg.in/yaml.v3"
)

const (
	prefix   = "volta-telemetry-test-"
	netName  = prefix + "net"
	ns       = "tesla_telemetry"
	clientV  = "1.3.0"
	sentinel = 12.345678 // latitude marker searched for in logs
	// vehicle B's and the poison record's markers, also searched for.
	vehicleBLat = 40.517317
	poisonValue = 98.765432
)

var (
	deployDir     = envOr("VT_DEPLOY_DIR", filepath.Join("..", "..", "deploy", "telemetry"))
	consumerImage = envOr("VT_CONSUMER_IMAGE", prefix+"consumer:local")
	receiverImage = envOr("VT_RECEIVER_IMAGE", prefix+"receiver:local")
)

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

// ---- docker helpers ----

func docker(t *testing.T, args ...string) string {
	t.Helper()
	out, err := dockerErr(args...)
	if err != nil {
		t.Fatalf("docker %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return out
}

func dockerErr(args ...string) (string, error) {
	cmd := exec.Command("docker", args...)
	var b bytes.Buffer
	cmd.Stdout, cmd.Stderr = &b, &b
	err := cmd.Run()
	return strings.TrimSpace(b.String()), err
}

func waitFor(t *testing.T, what string, timeout time.Duration, f func() (bool, error)) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	var last error
	for time.Now().Before(deadline) {
		ok, err := f()
		if ok {
			return
		}
		last = err
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s (last error: %v)", what, last)
}

func hostPort(t *testing.T, container, port string) string {
	out := docker(t, "port", container, port)
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, "127.0.0.1:") {
			return l
		}
	}
	t.Fatalf("%s:%s not published on loopback: %q", container, port, out)
	return ""
}

func randHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// ---- compose (the deployed definitions are the source for flags/env) ----

type composeService struct {
	Image       string            `yaml:"image"`
	Command     []string          `yaml:"command"`
	Environment map[string]string `yaml:"environment"`
}

func loadCompose(t *testing.T) map[string]composeService {
	b, err := os.ReadFile(filepath.Join(deployDir, "compose.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var c struct {
		Services map[string]composeService `yaml:"services"`
	}
	if err := yaml.Unmarshal(b, &c); err != nil {
		t.Fatal(err)
	}
	return c.Services
}

var interp = regexp.MustCompile(`^\$\{[A-Z_]+:-(.*)\}$`)

func resolve(v string) string {
	if m := interp.FindStringSubmatch(v); m != nil {
		return m[1]
	}
	return v
}

// ---- environment ----

type env struct {
	dir        string
	ca         *sim.CA
	rogueCA    *sim.CA
	serverCA   []byte
	recvAddr   string
	prodAddr   string
	usageToken string
	ingestPass string
	admin      *pgxpool.Pool
	api        *store.Store // volta_readonly member: the server's view
	images     map[string]composeService
}

func hardening() []string {
	return []string{"--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true", "--log-driver", "local"}
}

func setup(t *testing.T) *env {
	if _, err := exec.LookPath("docker"); err != nil {
		t.Skip("docker not available")
	}
	e := &env{images: loadCompose(t)}
	t.Cleanup(func() { cleanup() })
	cleanup()

	dir, err := os.MkdirTemp("", prefix)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	e.dir = dir

	// PKI: a test "vehicle CA" appended to the receiver pool via ca_file,
	// a rogue CA nobody trusts, and a server certificate for localhost.
	e.ca, err = sim.NewCA("TeslaMotors")
	must(t, err)
	e.rogueCA, err = sim.NewCA("TeslaMotors")
	must(t, err)
	srvCA, err := sim.NewCA("volta test server CA")
	must(t, err)
	srv, err := srvCA.IssueServer([]string{"localhost"}, []net.IP{net.ParseIP("127.0.0.1")})
	must(t, err)
	e.serverCA = srvCA.PEM
	writeFile(t, filepath.Join(dir, "server", "tls.crt"), srv.CertPEM)
	writeFile(t, filepath.Join(dir, "server", "tls.key"), srv.KeyPEM)
	writeFile(t, filepath.Join(dir, "testca", "ca.pem"), e.ca.PEM)

	// Receiver test config = production config + appended test CA. Nothing
	// else differs, so every other production setting is exercised.
	prodCfg, err := os.ReadFile(filepath.Join(deployDir, "receiver", "config.prod.json"))
	must(t, err)
	var cfg map[string]any
	must(t, json.Unmarshal(prodCfg, &cfg))
	cfg["tls"].(map[string]any)["ca_file"] = "/etc/certs/test/ca.pem"
	testCfg, _ := json.MarshalIndent(cfg, "", "  ")
	writeFile(t, filepath.Join(dir, "receiver-test", "config.json"), testCfg)
	writeFile(t, filepath.Join(dir, "receiver-prod", "config.json"), prodCfg)

	docker(t, "network", "create", netName)

	// Redpanda with the deployed command line.
	rp := e.images["redpanda"]
	args := append([]string{"run", "-d", "--name", prefix + "redpanda", "--network", netName, "--network-alias", "redpanda",
		"--cap-drop", "ALL", "--security-opt", "no-new-privileges:true", "--log-driver", "local", "--memory", "1g",
		"-v", prefix + "redpanda-data:/var/lib/redpanda/data", rp.Image}, rp.Command...)
	docker(t, args...)
	e.waitRedpanda(t)
	initImg := e.images["redpanda-init"]
	initArgs := []string{"run", "--rm", "--name", prefix + "redpanda-init", "--network", netName}
	initArgs = append(initArgs, hardening()...)
	initArgs = append(initArgs, "--tmpfs", "/tmp", "-e", "HOME=/tmp", "-e", "RPK_BROKERS=redpanda:9092", "-e", "RPK_ADMIN_HOSTS=redpanda:9644",
		"-e", "TELEMETRY_NAMESPACE="+ns, "-v", absPath(t, filepath.Join(deployDir, "redpanda"))+":/init:ro",
		"--entrypoint", "/bin/bash", initImg.Image, "/init/init-topics.sh")
	docker(t, initArgs...)
	docker(t, initArgs...) // idempotent

	// Postgres 17 with a stand-in TeslaMate table that must stay untouched.
	pgPass := randHex(12)
	docker(t, "run", "-d", "--name", prefix+"postgres", "--network", netName, "--network-alias", "database",
		"--log-driver", "local", "-e", "POSTGRES_USER=teslamate", "-e", "POSTGRES_DB=teslamate", "-e", "POSTGRES_PASSWORD="+pgPass,
		"-p", "127.0.0.1::5432", pgImage())
	waitFor(t, "postgres", 90*time.Second, func() (bool, error) {
		_, err := dockerErr("exec", prefix+"postgres", "psql", "-U", "teslamate", "-d", "teslamate", "-c", "SELECT 1")
		return err == nil, err
	})
	e.psql(t, `CREATE TABLE public.positions (id serial PRIMARY KEY, date timestamp, latitude numeric, longitude numeric);
		INSERT INTO public.positions (date, latitude, longitude) VALUES (now(), 1, 2);
		CREATE ROLE volta_readonly NOLOGIN;`)
	schema, err := os.ReadFile(filepath.Join(deployDir, "sql", "001_volta_telemetry.sql"))
	must(t, err)
	e.psqlStdin(t, schema)
	e.psqlStdin(t, schema) // idempotent
	ingestPass, apiPass := randHex(12), randHex(12)
	e.ingestPass = ingestPass
	e.psql(t, fmt.Sprintf(`ALTER ROLE volta_telemetry_ingest PASSWORD '%s';
		CREATE ROLE volta_api_test LOGIN PASSWORD '%s' IN ROLE volta_readonly;`, ingestPass, apiPass))
	pgAddr := hostPort(t, prefix+"postgres", "5432")
	e.admin = pool(t, fmt.Sprintf("postgres://teslamate:%s@%s/teslamate?sslmode=disable", pgPass, pgAddr))
	e.api = store.New(pool(t, fmt.Sprintf("postgres://volta_api_test:%s@%s/teslamate?sslmode=disable", apiPass, pgAddr)))

	// Receivers: test-CA-trusting (production config + ca_file) and the
	// unmodified production config. Only the first answers to the
	// "receiver" alias the consumer polls for liveness.
	e.recvAddr = e.startReceiver(t, "receiver", "receiver-test", true, "receiver")
	e.prodAddr = e.startReceiver(t, "receiver-prod", "receiver-prod", false, "")

	// Consumer, configured exactly like the compose service.
	e.usageToken = randHex(16)
	sec := filepath.Join(dir, "secrets")
	writeFile(t, filepath.Join(sec, "vehicles.json"), []byte(testvin.MappingFour))
	writeFile(t, filepath.Join(sec, "database-url"), []byte(fmt.Sprintf("postgres://volta_telemetry_ingest:%s@database:5432/teslamate?sslmode=disable", ingestPass)))
	writeFile(t, filepath.Join(sec, "status-secret"), []byte(e.usageToken))
	e.startConsumer(t)
	// From its first answer the meter is never "ok" without a proven,
	// complete count (checkUsage); it may be "unknown" first.
	waitFor(t, "usage endpoint", 60*time.Second, func() (bool, error) {
		code, m := e.usage(t, e.usageToken)
		return code == 200 && m != nil, nil
	})
	return e
}

func pgImage() string { return envOr("VT_POSTGRES_IMAGE", "postgres:17") }

func (e *env) waitRedpanda(t *testing.T) {
	waitFor(t, "redpanda healthy", 120*time.Second, func() (bool, error) {
		out, err := dockerErr("exec", prefix+"redpanda", "rpk", "cluster", "health")
		return err == nil && regexp.MustCompile(`Healthy:\s+true`).MatchString(out), err
	})
}

func (e *env) startReceiver(t *testing.T, name, cfgDir string, testCA bool, alias string) string {
	args := []string{"run", "-d", "--name", prefix + name, "--network", netName}
	if alias != "" {
		args = append(args, "--network-alias", alias)
	}
	args = append(args, hardening()...)
	args = append(args, "--memory", "256m", "--pids-limit", "256",
		"-e", "SUPPRESS_TLS_HANDSHAKE_ERROR_LOGGING=true",
		"-v", filepath.Join(e.dir, cfgDir, "config.json")+":/etc/fleet-telemetry/config.json:ro",
		"-v", filepath.Join(e.dir, "server")+":/etc/certs/server:ro",
		"-p", "127.0.0.1::8448")
	if testCA {
		args = append(args, "-v", filepath.Join(e.dir, "testca")+":/etc/certs/test:ro")
	}
	// The production receiver image (guard + pinned official binary) with
	// the compose command (receiver flags only).
	args = append(args, receiverImage)
	args = append(args, e.images["receiver"].Command...)
	docker(t, args...)
	return e.waitListening(t, name)
}

// waitListening returns the receiver's loopback address once it answers TLS.
func (e *env) waitListening(t *testing.T, name string) string {
	addr := hostPort(t, prefix+name, "8448")
	waitFor(t, name+" listening", 60*time.Second, func() (bool, error) {
		// Any TLS answer proves the receiver is up: a handshake (TLS 1.3
		// defers the client-certificate verdict) or a certificate alert.
		// docker-proxy accepting and closing (EOF) does not count.
		c, err := tls.Dial("tcp", addr, &tls.Config{InsecureSkipVerify: true}) //nolint:gosec // liveness probe only
		if err == nil {
			_ = c.Close()
			return true, nil
		}
		return strings.Contains(err.Error(), "certificate") || strings.Contains(err.Error(), "remote error"), err
	})
	return addr
}

func (e *env) startConsumer(t *testing.T) {
	c := e.images["consumer"]
	args := []string{"run", "-d", "--name", prefix + "consumer", "--network", netName, "--restart", "on-failure"}
	args = append(args, hardening()...)
	args = append(args, "--user", "65532:65532", "--memory", "128m",
		"-v", filepath.Join(e.dir, "secrets")+":/run/volta-telemetry:ro", "-p", "127.0.0.1::8449")
	for k, v := range c.Environment {
		args = append(args, "-e", k+"="+resolve(v))
	}
	args = append(args, consumerImage)
	docker(t, args...)
}

func (e *env) psql(t *testing.T, sql string) string {
	return docker(t, "exec", prefix+"postgres", "psql", "-v", "ON_ERROR_STOP=1", "-XAt", "-U", "teslamate", "-d", "teslamate", "-c", sql)
}

func (e *env) psqlStdin(t *testing.T, sql []byte) {
	cmd := exec.Command("docker", "exec", "-i", prefix+"postgres", "psql", "-v", "ON_ERROR_STOP=1", "-q", "-U", "teslamate", "-d", "teslamate")
	cmd.Stdin = bytes.NewReader(sql)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("apply sql: %v\n%s", err, out)
	}
}

func (e *env) count(t *testing.T, q string, args ...any) int64 {
	var n int64
	if err := e.admin.QueryRow(context.Background(), q, args...).Scan(&n); err != nil {
		t.Fatalf("query %q: %v", q, err)
	}
	return n
}

func (e *env) waitCount(t *testing.T, want int64, q string, args ...any) {
	t.Helper()
	waitFor(t, fmt.Sprintf("%q = %d", q, want), 90*time.Second, func() (bool, error) {
		var n int64
		err := e.admin.QueryRow(context.Background(), q, args...).Scan(&n)
		if err == nil && n > want {
			t.Fatalf("%q = %d, exceeded %d (duplicate?)", q, n, want)
		}
		return err == nil && n == want, err
	})
}

func (e *env) usage(t *testing.T, token string) (int, map[string]any) {
	// The published host port changes whenever the container restarts.
	addr, err := dockerErr("port", prefix+"consumer", "8449")
	if err != nil {
		t.Fatalf("consumer port: %v %s", err, addr)
	}
	req, _ := http.NewRequest(http.MethodGet, "http://"+strings.Split(addr, "\n")[0]+"/v1/usage", nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, nil // not listening yet
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	if resp.StatusCode == 200 {
		checkUsage(t, m)
	}
	return resp.StatusCode, m
}

// checkUsage enforces the commander contract on every status read: "ok" and
// "warn" (the only states that permit streaming) require a complete count
// with a recent AccountedThrough and no reasons.
func checkUsage(t *testing.T, m map[string]any) {
	t.Helper()
	state, _ := m["state"].(string)
	switch state {
	case "ok", "warn":
		reasons, _ := m["reasons"].([]any)
		at, _ := m["accountedThrough"].(string)
		checked, _ := m["checkedAt"].(string)
		ta, err1 := time.Parse(time.RFC3339Nano, at)
		tc, err2 := time.Parse(time.RFC3339Nano, checked)
		if m["confidence"] != "complete" || len(reasons) != 0 || err1 != nil || err2 != nil || tc.Sub(ta) > 2*time.Minute {
			t.Fatalf("usage %s without a proven complete count: %v", state, m)
		}
	case "stop", "unknown":
	default:
		t.Fatalf("usage state %q", state)
	}
}

func (e *env) waitUsage(t *testing.T, what string, f func(m map[string]any) bool) map[string]any {
	t.Helper()
	var last map[string]any
	waitFor(t, what, 120*time.Second, func() (bool, error) {
		code, m := e.usage(t, e.usageToken)
		last = m
		return code == 200 && f(m), fmt.Errorf("usage %v", m)
	})
	return last
}

func hasReason(m map[string]any, r string) bool {
	rs, _ := m["reasons"].([]any)
	for _, v := range rs {
		if v == r {
			return true
		}
	}
	return false
}

// billedSignals is the month's billable receipt total, as the meter counts.
func (e *env) billedSignals(t *testing.T) int64 {
	return e.count(t, `SELECT COALESCE(sum(signal_count), 0) FROM volta_telemetry.receipts
		WHERE billable AND received_at >= date_trunc('month', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'`)
}

// guardLogs asserts that every line in a receiver container's log is a guard
// event (fixed keys, no free text) and returns the event names seen.
func guardLogs(t *testing.T, name string) map[string]int {
	t.Helper()
	seen := map[string]int{}
	allowedKeys := map[string]bool{"time": true, "level": true, "source": true, "event": true, "count": true, "exitCode": true}
	for _, line := range strings.Split(logsOf(t, name), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Errorf("%s: a log line is not a guard event (%d bytes)", name, len(line))
			continue
		}
		for k := range m {
			if !allowedKeys[k] {
				t.Errorf("%s: log line has key %q", name, k)
			}
		}
		ev, _ := m["event"].(string)
		seen[ev]++
	}
	return seen
}

func (e *env) dial(t *testing.T, addr string, ca *sim.CA, vin string) *sim.Client {
	t.Helper()
	leaf, err := ca.IssueClient(vin)
	must(t, err)
	c, _, err := sim.Dial(addr, e.serverCA, &leaf.TLS, clientV)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	return c
}

func send(t *testing.T, c *sim.Client, sender, txid string, payload []byte, created time.Time) {
	t.Helper()
	if err := c.Send(sim.Frame(sender, txid, payload, created)); err != nil {
		t.Fatalf("send: %v", err)
	}
}

func expectAck(t *testing.T, c *sim.Client, txid string, timeout time.Duration) {
	t.Helper()
	for {
		got, err := c.ReadAck(timeout)
		if err != nil {
			t.Fatalf("waiting for ack %s: %v", txid, err)
		}
		if got == txid {
			return
		}
	}
}

func logsOf(t *testing.T, name string) string {
	out, _ := dockerErr("logs", prefix+name)
	return out
}

func cleanup() {
	out, _ := dockerErr("ps", "-aq", "--filter", "name=^/"+prefix)
	if ids := strings.Fields(out); len(ids) > 0 {
		_, _ = dockerErr(append([]string{"rm", "-f", "-v"}, ids...)...)
	}
	_, _ = dockerErr("network", "rm", netName)
	_, _ = dockerErr("volume", "rm", prefix+"redpanda-data")
}

func pool(t *testing.T, url string) *pgxpool.Pool {
	p, err := pgxpool.New(context.Background(), url)
	must(t, err)
	t.Cleanup(p.Close)
	return p
}

func writeFile(t *testing.T, p string, b []byte) {
	must(t, os.MkdirAll(filepath.Dir(p), 0o755))
	// World-readable: containers run as uid 65532. Test material only.
	must(t, os.WriteFile(p, b, 0o444))
}

func absPath(t *testing.T, p string) string {
	a, err := filepath.Abs(p)
	must(t, err)
	return a
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// drivePayload is one dense 10 s fixture sample with co-timed power inputs.
func drivePayload(vin string, at time.Time, lat, lon, mph float64, gear *protos.ShiftState, soc float64) []byte {
	d := []*protos.Datum{
		sim.Loc(lat, lon),
		sim.Num(protos.Field_VehicleSpeed, mph),
		sim.Num(protos.Field_GpsHeading, 90),
		sim.Num(protos.Field_PackVoltage, 400),
		sim.Num(protos.Field_PackCurrent, 50),
		sim.Num(protos.Field_Soc, soc),
		sim.Num(protos.Field_BatteryLevel, soc),
	}
	if gear != nil {
		d = append(d, sim.Gear(*gear))
	}
	return sim.Payload(vin, at, false, d...)
}

func gearPtr(g protos.ShiftState) *protos.ShiftState { return &g }

// ---- the acceptance run ----

func TestAcceptance(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	positionsBefore := e.psql(t, `SELECT md5(string_agg(t::text, ',' ORDER BY id)) FROM public.positions t`)
	txn := 0
	tx := func() string { txn++; return fmt.Sprintf("tx-%d", txn) }
	var apiWindowStart, apiWindowEnd time.Time

	t.Run("vehicle_identity_bindings_are_permanent_digests", func(t *testing.T) {
		allow, err := vehicles.Parse(testvin.MappingFour)
		must(t, err)
		st := store.New(e.admin)
		must(t, st.EnsureVehicleBindings(ctx, allow.Bindings()))
		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.vehicle_bindings`); n != 4 {
			t.Fatalf("vehicle bindings = %d, want 4", n)
		}
		var stored string
		must(t, e.admin.QueryRow(ctx, `SELECT string_agg(vin_digest, '') FROM volta_telemetry.vehicle_bindings`).Scan(&stored))
		if strings.Contains(stored, "5YJ3E1EA0XF") {
			t.Fatal("vehicle binding table contains a VIN")
		}
		bindings := allow.Bindings()
		if err := st.EnsureVehicleBindings(ctx, map[int]string{1: bindings[2]}); !errors.Is(err, store.ErrVehicleBindingChanged) {
			t.Fatalf("vehicle id reassignment error = %v", err)
		}
		if err := st.EnsureVehicleBindings(ctx, map[int]string{99: bindings[1]}); !errors.Is(err, store.ErrVehicleBindingChanged) {
			t.Fatalf("VIN digest reassignment error = %v", err)
		}
	})

	t.Run("mtls_no_client_cert_refused", func(t *testing.T) {
		if c, _, err := sim.Dial(e.recvAddr, e.serverCA, nil, clientV); err == nil {
			c.Close()
			t.Fatal("receiver accepted a client without a certificate")
		}
	})
	t.Run("mtls_untrusted_ca_refused", func(t *testing.T) {
		leaf, _ := e.rogueCA.IssueClient(testvin.A)
		if c, _, err := sim.Dial(e.recvAddr, e.serverCA, &leaf.TLS, clientV); err == nil {
			c.Close()
			t.Fatal("receiver accepted a certificate from an untrusted CA")
		}
	})
	t.Run("prod_config_trusts_only_tesla_ca", func(t *testing.T) {
		leaf, _ := e.ca.IssueClient(testvin.A)
		if c, _, err := sim.Dial(e.prodAddr, e.serverCA, &leaf.TLS, clientV); err == nil {
			c.Close()
			t.Fatal("unmodified production config accepted a non-Tesla CA")
		}
	})

	base := time.Now().UTC().Add(-50 * time.Minute).Truncate(time.Second)

	t.Run("ack_after_durable_write_and_store", func(t *testing.T) {
		c := e.dial(t, e.recvAddr, e.ca, testvin.A)
		defer c.Close()
		for i := 0; i < 3; i++ {
			id := tx()
			send(t, c, testvin.A, id, drivePayload(testvin.A, base.Add(time.Duration(i)*10*time.Second), sentinel, -1, 10, gearPtr(protos.ShiftState_ShiftStateD), 80), base)
			expectAck(t, c, id, 30*time.Second)
		}
		e.waitCount(t, 3, `SELECT count(*) FROM volta_telemetry.records WHERE vehicle_id = 1 AND tx_type = 'V'`)
		e.waitCount(t, 1, `SELECT count(DISTINCT connection_id) FROM volta_telemetry.connectivity WHERE vehicle_id = 1 AND status = 'CONNECTED'`)
	})

	t.Run("happy_path_logs_have_no_vin_or_values", func(t *testing.T) {
		for _, n := range []string{"receiver", "consumer"} {
			l := logsOf(t, n)
			for _, s := range []string{testvin.A, testvin.B, "12.345678", "5YJ3E1EA0XF"} {
				if strings.Contains(l, s) {
					t.Errorf("%s logs contain %q", n, s)
				}
			}
		}
		seen := guardLogs(t, "receiver")
		for _, ev := range []string{"guard_child_started", "starting_server", "request_start", "socket_connected"} {
			if seen[ev] == 0 {
				t.Errorf("receiver log has no %s event: %v", ev, seen)
			}
		}
	})

	t.Run("receiver_error_paths_emit_codes_only", func(t *testing.T) {
		// Certificate A, sender B, on a topic without a dispatch rule: the
		// official receiver logs unexpected_sender_id (sender_id and
		// expected_sender_id carry both VINs) and unexpected_record (its
		// error text repeats them, plus device_id) and answers with an error.
		// Only the guard's fixed codes may reach the log driver.
		c := e.dial(t, e.recvAddr, e.ca, testvin.A)
		id := tx()
		if err := c.Send(sim.FrameTopic("alerts", testvin.B, id, sim.Payload(testvin.B, base, false, sim.Num(protos.Field_Soc, 1)), base)); err != nil {
			t.Fatal(err)
		}
		if got, err := c.ReadAck(5 * time.Second); err == nil {
			t.Fatalf("receiver acked a mismatched sender: %s", got)
		}
		c.Close()
		// A client certificate from an untrusted CA (TLS handshake error).
		leaf, _ := e.rogueCA.IssueClient(testvin.Rogue)
		if c, _, err := sim.Dial(e.recvAddr, e.serverCA, &leaf.TLS, clientV); err == nil {
			c.Close()
		}
		var seen map[string]int
		waitFor(t, "error events", 30*time.Second, func() (bool, error) {
			seen = guardLogs(t, "receiver")
			return seen["unexpected_sender_id"] > 0 && seen["unexpected_record"] > 0, fmt.Errorf("%v", seen)
		})
		l := logsOf(t, "receiver")
		for _, s := range []string{"5YJ3E1EA0XF", "vehicle_device", "remote_ip", "SenderID", "172.", "127.0.0.1"} {
			if strings.Contains(l, s) {
				t.Errorf("receiver log contains %q", s)
			}
		}
		if drv := docker(t, "inspect", "-f", "{{.HostConfig.LogConfig.Type}}", prefix+"receiver"); drv != "local" {
			t.Errorf("log driver %q", drv)
		}
	})

	t.Run("durable_ack_waits_for_queue", func(t *testing.T) {
		c := e.dial(t, e.recvAddr, e.ca, testvin.A)
		defer c.Close()
		docker(t, "pause", prefix+"redpanda")
		id := tx()
		send(t, c, testvin.A, id, drivePayload(testvin.A, base.Add(30*time.Second), sentinel, -1.0001, 12, nil, 80), base)
		if got, err := c.ReadAck(8 * time.Second); err == nil {
			docker(t, "unpause", prefix+"redpanda")
			t.Fatalf("acked %s while the queue was unavailable", got)
		} else if !errors.Is(err, sim.ErrNoAck) {
			docker(t, "unpause", prefix+"redpanda")
			t.Fatalf("connection failed instead of waiting: %v", err)
		}
		docker(t, "unpause", prefix+"redpanda")
		expectAck(t, c, id, 90*time.Second)
		e.waitCount(t, 4, `SELECT count(*) FROM volta_telemetry.records WHERE vehicle_id = 1 AND tx_type = 'V'`)
	})

	t.Run("acked_record_survives_broker_sigkill", func(t *testing.T) {
		docker(t, "stop", prefix+"consumer") // so the record can only come from the log after restart
		c := e.dial(t, e.recvAddr, e.ca, testvin.A)
		id := tx()
		send(t, c, testvin.A, id, drivePayload(testvin.A, base.Add(40*time.Second), sentinel, -1.0002, 14, nil, 79), base)
		expectAck(t, c, id, 30*time.Second)
		c.Close()
		docker(t, "kill", "--signal", "KILL", prefix+"redpanda")
		docker(t, "start", prefix+"redpanda")
		e.waitRedpanda(t)
		docker(t, "start", prefix+"consumer")
		e.waitCount(t, 5, `SELECT count(*) FROM volta_telemetry.records WHERE vehicle_id = 1 AND tx_type = 'V'`)
	})

	t.Run("consumer_sigkill_replay_is_idempotent_and_counts_restore", func(t *testing.T) {
		waitFor(t, "usage refreshed", 90*time.Second, func() (bool, error) {
			code, m := e.usage(t, e.usageToken)
			return code == 200 && m["state"] != nil && m["signals"] != nil && m["signals"].(float64) > 0, nil
		})
		samplesBefore := e.count(t, `SELECT count(*) FROM volta_telemetry.samples`)
		docker(t, "kill", "--signal", "KILL", prefix+"consumer")
		c := e.dial(t, e.recvAddr, e.ca, testvin.B)
		for i := 0; i < 5; i++ {
			id := tx()
			send(t, c, testvin.B, id, drivePayload(testvin.B, base.Add(time.Duration(i)*10*time.Second), vehicleBLat, -73.9, 20, gearPtr(protos.ShiftState_ShiftStateD), 60), base)
			expectAck(t, c, id, 30*time.Second)
		}
		c.Close()
		docker(t, "start", prefix+"consumer")
		e.waitCount(t, 5, `SELECT count(*) FROM volta_telemetry.records WHERE vehicle_id = 2 AND tx_type = 'V'`)
		// Replay the whole topic into a fresh consumer group against the same
		// store: every write must be a no-op.
		records := e.count(t, `SELECT count(*) FROM volta_telemetry.records`)
		samples := e.count(t, `SELECT count(*) FROM volta_telemetry.samples`)
		if samples <= samplesBefore {
			t.Fatalf("samples did not grow: %d -> %d", samplesBefore, samples)
		}
		docker(t, "stop", prefix+"consumer")
		docker(t, "exec", prefix+"redpanda", "rpk", "group", "seek", "volta-telemetry-consumer", "--to", "start")
		docker(t, "start", prefix+"consumer")
		waitFor(t, "replayed group caught up", 90*time.Second, func() (bool, error) {
			out, err := dockerErr("exec", prefix+"redpanda", "rpk", "group", "describe", "volta-telemetry-consumer")
			return err == nil && regexp.MustCompile(`TOTAL-LAG\s+0\b`).MatchString(out), err
		})
		time.Sleep(2 * time.Second)
		if r, s := e.count(t, `SELECT count(*) FROM volta_telemetry.records`), e.count(t, `SELECT count(*) FROM volta_telemetry.samples`); r != records || s != samples {
			t.Fatalf("replay changed counts: records %d->%d samples %d->%d", records, r, samples, s)
		}
		// The meter is derived from the stored receipts (every received
		// record, accepted or not), so a restart restores it; once the
		// handoff is proven again it is complete.
		want := e.billedSignals(t)
		if want < e.count(t, `SELECT sum(signal_count) FROM volta_telemetry.records WHERE tx_type = 'V'`) {
			t.Fatal("receipts bill less than the accepted records")
		}
		e.waitUsage(t, "usage after restart", func(m map[string]any) bool {
			return m["signals"] != nil && int64(m["signals"].(float64)) == want && m["confidence"] == "complete"
		})
		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.queue_checkpoints
			WHERE topic_id <> '' AND next_offset > 0`); n != 2 {
			t.Fatalf("durable queue checkpoints after restart = %d, want 2", n)
		}
		if code, m := e.usage(t, ""); code != 401 || len(m) != 0 {
			t.Fatalf("usage without token: %d %v", code, m)
		}
		if code, _ := e.usage(t, "wrong"); code != 401 {
			t.Fatalf("usage with wrong token: %d", code)
		}
	})

	t.Run("stalled_handoff_reports_unknown_never_ok", func(t *testing.T) {
		// The database refuses receipts (a transient permission error): the
		// consumer keeps retrying the batch and cannot commit, so the count
		// is no longer complete. No status read may be a fresh "ok".
		e.psql(t, `REVOKE INSERT ON volta_telemetry.receipts FROM volta_telemetry_ingest`)
		granted := false
		defer func() {
			if !granted {
				_, _ = dockerErr("exec", prefix+"postgres", "psql", "-U", "teslamate", "-d", "teslamate", "-c",
					`GRANT INSERT ON volta_telemetry.receipts TO volta_telemetry_ingest`)
			}
		}()
		before := e.count(t, `SELECT count(*) FROM volta_telemetry.records WHERE vehicle_id = 1 AND tx_type = 'V'`)
		c := e.dial(t, e.recvAddr, e.ca, testvin.A)
		id := tx()
		send(t, c, testvin.A, id, drivePayload(testvin.A, base.Add(50*time.Second), sentinel, -1.0003, 15, nil, 79), base)
		expectAck(t, c, id, 30*time.Second)
		c.Close()
		e.waitUsage(t, "stalled meter", func(m map[string]any) bool {
			return m["state"] == "unknown" && m["confidence"] == "lower_bound" && hasReason(m, "store_retrying")
		})
		waitFor(t, "backlog recorded", 60*time.Second, func() (bool, error) {
			return e.count(t, `SELECT COALESCE(lag_records, 0) FROM volta_telemetry.stream_health WHERE id = 1`) > 0, nil
		})
		for i := 0; i < 4; i++ {
			time.Sleep(5 * time.Second)
			if code, m := e.usage(t, e.usageToken); code == 200 && (m["state"] == "ok" || m["state"] == "warn") {
				t.Fatalf("usage %v while the handoff is stalled", m["state"])
			}
		}
		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.records WHERE vehicle_id = 1 AND tx_type = 'V'`); n != before {
			t.Fatalf("records changed while receipts were refused: %d -> %d", before, n)
		}
		e.psql(t, `GRANT INSERT ON volta_telemetry.receipts TO volta_telemetry_ingest`)
		granted = true
		e.waitCount(t, before+1, `SELECT count(*) FROM volta_telemetry.records WHERE vehicle_id = 1 AND tx_type = 'V'`)
		e.waitUsage(t, "meter recovers", func(m map[string]any) bool {
			return m["confidence"] == "complete" && int64(m["signals"].(float64)) == e.billedSignals(t)
		})
	})

	t.Run("cross_vehicle_isolation", func(t *testing.T) {
		pts, err := e.api.DrivePoints(ctx, 1, base.Add(-time.Hour), base.Add(time.Hour))
		must(t, err)
		for _, p := range pts {
			if p.Latitude != sentinel {
				t.Fatalf("vehicle 1 has a point that is not its own: %+v", p)
			}
		}
		pts, err = e.api.DrivePoints(ctx, 2, base.Add(-time.Hour), base.Add(time.Hour))
		must(t, err)
		if len(pts) != 5 {
			t.Fatalf("vehicle 2 points = %d, want 5", len(pts))
		}
		for _, p := range pts {
			if p.Latitude != vehicleBLat {
				t.Fatalf("vehicle 2 has a point that is not its own: %+v", p)
			}
		}
	})

	t.Run("unregistered_vin_rejected", func(t *testing.T) {
		before := e.count(t, `SELECT count(*) FROM volta_telemetry.records`)
		c := e.dial(t, e.recvAddr, e.ca, testvin.Rogue)
		id := tx()
		send(t, c, testvin.Rogue, id, drivePayload(testvin.Rogue, base, 1, 1, 1, nil, 50), base)
		expectAck(t, c, id, 30*time.Second) // durable in the queue, then refused
		c.Close()
		e.waitCount(t, 1, `SELECT count(*) FROM volta_telemetry.rejected_records WHERE reason = 'unregistered_vin' AND topic = $1`, ns+"_V")
		if after := e.count(t, `SELECT count(*) FROM volta_telemetry.records`); after != before {
			t.Fatalf("records changed %d -> %d", before, after)
		}
		// Still billed: Tesla bills every signal it sends, for any VIN.
		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.receipts r JOIN volta_telemetry.rejected_records j
				USING (topic, kafka_partition, kafka_offset)
			WHERE j.reason = 'unregistered_vin' AND r.billable AND NOT r.accepted AND r.vehicle_id IS NULL AND r.signal_count = 7`); n != 1 {
			t.Fatalf("rejected record receipts = %d, want 1 billed with 7 signals", n)
		}
		want := e.billedSignals(t)
		e.waitUsage(t, "meter includes rejected signals", func(m map[string]any) bool {
			return int64(m["signals"].(float64)) == want
		})
	})

	t.Run("spoofed_identity_binds_to_certificate_vin", func(t *testing.T) {
		before := e.count(t, `SELECT count(*) FROM volta_telemetry.records WHERE vehicle_id = 2`)
		c := e.dial(t, e.recvAddr, e.ca, testvin.A)
		// Certificate A; the envelope sender claims B. Upstream v0.9.5 skips
		// the sender-ID comparison for dispatched topics and keys the record
		// by the certificate VIN, so it can only land on vehicle 1.
		id := tx()
		send(t, c, testvin.B, id, drivePayload(testvin.B, base.Add(5*time.Minute), 66, 66, 1, nil, 50), base)
		expectAck(t, c, id, 30*time.Second)
		// Certificate A, envelope A, payload VIN B: re-bound to A as well.
		id2 := tx()
		send(t, c, testvin.A, id2, drivePayload(testvin.B, base.Add(6*time.Minute), 67, 67, 1, nil, 50), base)
		expectAck(t, c, id2, 30*time.Second)
		c.Close()
		e.waitCount(t, 2, `SELECT count(*) FROM volta_telemetry.samples WHERE field = 'Location' AND latitude IN (66, 67)`)
		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.samples WHERE field = 'Location' AND latitude IN (66, 67) AND vehicle_id <> 1`); n != 0 {
			t.Fatalf("spoofed data attributed to another vehicle")
		}
		if after := e.count(t, `SELECT count(*) FROM volta_telemetry.records WHERE vehicle_id = 2`); after != before {
			t.Fatalf("spoofed data reached vehicle 2: %d -> %d", before, after)
		}
	})

	t.Run("wrong_typed_datum_is_quarantined_not_blocking", func(t *testing.T) {
		// Vehicle 3: a bool where ACChargingPower is a number. That datum is
		// stored as malformed (no value); the rest of the record, and the
		// next record, are stored and the group advances.
		w := time.Now().UTC().Add(-4 * time.Hour).Truncate(time.Second)
		c := e.dial(t, e.recvAddr, e.ca, testvin.C)
		bad, good := tx(), tx()
		send(t, c, testvin.C, bad, sim.Payload(testvin.C, w, false,
			sim.Bool(protos.Field_ACChargingPower, true), sim.Num(protos.Field_PackCurrent, -7)), w)
		expectAck(t, c, bad, 30*time.Second)
		send(t, c, testvin.C, good, sim.Payload(testvin.C, w.Add(10*time.Second), false,
			sim.Num(protos.Field_ACChargingPower, 7.1), sim.Num(protos.Field_PackCurrent, -8)), w)
		expectAck(t, c, good, 30*time.Second)
		c.Close()
		e.waitCount(t, 2, `SELECT count(*) FROM volta_telemetry.records WHERE vehicle_id = 3 AND tx_type = 'V' AND source_ts IN ($1, $2)`, w, w.Add(10*time.Second))
		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.samples WHERE vehicle_id = 3 AND source_ts = $1
				AND field = 'ACChargingPower' AND invalid AND quality = 'malformed' AND value_num IS NULL AND value_bool IS NULL`, w); n != 1 {
			t.Fatalf("wrong-typed datum not stored as malformed (%d)", n)
		}
		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.samples WHERE vehicle_id = 3 AND field = 'PackCurrent' AND quality = 'ok'
				AND ((source_ts = $1 AND value_num = -7) OR (source_ts = $2 AND value_num = -8))`, w, w.Add(10*time.Second)); n != 2 {
			t.Fatalf("well-typed datums around the malformed one = %d, want 2", n)
		}
		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.samples WHERE vehicle_id = 3 AND source_ts = $1
				AND field = 'ACChargingPower' AND quality = 'ok' AND value_num = 7.1`, w.Add(10*time.Second)); n != 1 {
			t.Fatal("healthy record after the malformed one not stored")
		}
		waitFor(t, "group caught up", 60*time.Second, func() (bool, error) {
			out, err := dockerErr("exec", prefix+"redpanda", "rpk", "group", "describe", "volta-telemetry-consumer")
			return err == nil && regexp.MustCompile(`TOTAL-LAG\s+0\b`).MatchString(out), err
		})
	})

	t.Run("store_rejected_record_does_not_block_batch", func(t *testing.T) {
		// A record the database refuses permanently (here a CHECK violation)
		// is quarantined with its billed receipt; the records around it in
		// the same batch are stored. Run as the ingest role so the refusal
		// also exercises its log settings (no failing-row values logged).
		ing := store.New(pool(t, fmt.Sprintf("postgres://volta_telemetry_ingest:%s@%s/teslamate?sslmode=disable",
			e.ingestPass, hostPort(t, prefix+"postgres", "5432"))))
		const topic = "volta_test_direct"
		at := time.Now().UTC().Add(-6 * time.Hour).Truncate(time.Second)
		one := 1
		items := make([]store.Item, 3)
		for i := range items {
			v := 50 + float64(i)
			smp := normalize.Sample{Field: "Soc", Num: &v, Quality: normalize.QualityOK, SourceUnit: "%"}
			if i == 1 {
				p := poisonValue
				smp = normalize.Sample{Field: "Soc", Num: &p, Invalid: true, Quality: normalize.QualityOK, SourceUnit: "%"}
			}
			ts := at.Add(time.Duration(i) * 10 * time.Second)
			id := fmt.Sprintf("direct-%d", i)
			items[i] = store.Item{
				Message: &normalize.Message{VehicleID: 4, TxType: normalize.TxVehicleData, TxID: id, SourceTS: ts, ReceivedAt: ts,
					ClientVersion: clientV, Samples: []normalize.Sample{smp}, PayloadID: id, Topic: topic, Offset: int64(i + 1)},
				Receipt: normalize.Receipt{Billable: true, Signals: &one, ReceivedAt: ts, Dated: true},
			}
		}
		must(t, ing.Apply(ctx, items))
		if items[1].Reason != store.ReasonStoreRejected || items[1].Message != nil || items[0].Message == nil || items[2].Message == nil {
			t.Fatalf("outcomes: %q %v", items[1].Reason, items[1].Message != nil)
		}
		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.records WHERE topic = $1 AND kafka_offset IN (1, 3)`, topic); n != 2 {
			t.Fatalf("records around the refused one = %d, want 2", n)
		}
		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.rejected_records WHERE topic = $1 AND kafka_offset = 2 AND reason = 'store_rejected'`, topic); n != 1 {
			t.Fatal("refused record not quarantined")
		}
		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.receipts WHERE topic = $1 AND billable AND signal_count = 1
				AND accepted = (kafka_offset <> 2)`, topic); n != 3 {
			t.Fatalf("receipts = %d, want 3 (the refused one billed, not accepted)", n)
		}
		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.samples WHERE value_num = $1`, poisonValue); n != 0 {
			t.Fatal("refused value stored")
		}
		e.psql(t, `DELETE FROM volta_telemetry.samples WHERE vehicle_id = 4 AND payload_id LIKE 'direct-%';
			DELETE FROM volta_telemetry.latest_samples WHERE vehicle_id = 4 AND payload_id LIKE 'direct-%';
			DELETE FROM volta_telemetry.records WHERE topic = 'volta_test_direct';
			DELETE FROM volta_telemetry.rejected_records WHERE topic = 'volta_test_direct';
			DELETE FROM volta_telemetry.receipts WHERE topic = 'volta_test_direct';`)
	})

	t.Run("late_out_of_order_never_overwrites_newer", func(t *testing.T) {
		c := e.dial(t, e.recvAddr, e.ca, testvin.A)
		newer, older := tx(), tx()
		send(t, c, testvin.A, newer, sim.Payload(testvin.A, base.Add(20*time.Minute), false, sim.Num(protos.Field_Soc, 70)), base)
		expectAck(t, c, newer, 30*time.Second)
		send(t, c, testvin.A, older, sim.Payload(testvin.A, base.Add(10*time.Minute), true, sim.Num(protos.Field_Soc, 75)), base)
		expectAck(t, c, older, 30*time.Second)
		c.Close()
		e.waitCount(t, 1, `SELECT count(*) FROM volta_telemetry.samples WHERE vehicle_id = 1 AND field = 'Soc' AND value_num = 75`)
		var v float64
		var ts time.Time
		must(t, e.admin.QueryRow(ctx, `SELECT value_num, source_ts FROM volta_telemetry.latest_samples WHERE vehicle_id = 1 AND field = 'Soc'`).Scan(&v, &ts))
		if v != 70 || !ts.Equal(base.Add(20*time.Minute)) {
			t.Fatalf("latest Soc = %v @ %v, want 70 @ newer", v, ts)
		}
	})

	t.Run("dense_drive_fixture_gaps_and_contract", func(t *testing.T) {
		// Vehicle 2: a 10 s drive, a 40 min silence with no stream, then a
		// second complete drive (P -> D ... P), plus charging data (7.2 kW
		// with -18 A, and 1.4 kW with +10 A). Charger data never sets the
		// PackCurrent sign. Placed hours back, clear of this run's real-time
		// connect/disconnect events.
		d0 := time.Now().UTC().Add(-3 * time.Hour).Truncate(time.Second)
		c := e.dial(t, e.recvAddr, e.ca, testvin.B)
		defer c.Close()
		sendAck := func(p []byte) {
			id := tx()
			send(t, c, testvin.B, id, p, d0)
			expectAck(t, c, id, 30*time.Second)
		}
		for i := 0; i < 6; i++ {
			g := (*protos.ShiftState)(nil)
			if i == 5 {
				g = gearPtr(protos.ShiftState_ShiftStateP)
			}
			sendAck(drivePayload(testvin.B, d0.Add(time.Duration(i)*10*time.Second), 41+float64(i)/1000, -74, 25, g, 59))
		}
		d1 := d0.Add(41 * time.Minute)
		sendAck(drivePayload(testvin.B, d1, 42, -74, 0, gearPtr(protos.ShiftState_ShiftStateP), 58))
		for i := 1; i <= 6; i++ {
			g := (*protos.ShiftState)(nil)
			if i == 1 {
				g = gearPtr(protos.ShiftState_ShiftStateD)
			}
			if i == 6 {
				g = gearPtr(protos.ShiftState_ShiftStateP)
			}
			sendAck(drivePayload(testvin.B, d1.Add(time.Duration(i)*10*time.Second), 42+float64(i)/1000, -74, 30, g, 58))
		}
		for i := 0; i < 6; i++ {
			sendAck(sim.Payload(testvin.B, d1.Add(5*time.Minute+time.Duration(i)*10*time.Second), false,
				sim.ChargeState(protos.DetailedChargeStateValue_DetailedChargeStateCharging),
				sim.Num(protos.Field_ACChargingPower, 7.2), sim.Num(protos.Field_PackCurrent, -18), sim.Num(protos.Field_PackVoltage, 400)))
		}
		for i := 0; i < 3; i++ {
			sendAck(sim.Payload(testvin.B, d1.Add(10*time.Minute+time.Duration(i)*10*time.Second), false, sim.Loc(42.01, -74),
				sim.ChargeState(protos.DetailedChargeStateValue_DetailedChargeStateCharging),
				sim.Num(protos.Field_ACChargingPower, 1.4), sim.Num(protos.Field_PackCurrent, 10), sim.Num(protos.Field_PackVoltage, 400)))
		}
		e.waitCount(t, 5+6+7+6+3, `SELECT count(*) FROM volta_telemetry.records WHERE vehicle_id = 2 AND tx_type = 'V'`)

		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.gaps WHERE vehicle_id = 2 AND start_ts >= $1 AND end_ts <= $2`, d0, d1); n != 1 {
			t.Fatalf("gaps in the silence = %d, want 1", n)
		}
		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.power_calibration`); n != 0 {
			t.Fatalf("a power sign was inferred (%d rows)", n)
		}
		// 1.4 kW at the charger with +10 A at the pack: no sign is implied.
		pts14, err := e.api.DrivePoints(ctx, 2, d1.Add(10*time.Minute), d1.Add(11*time.Minute))
		must(t, err)
		if len(pts14) != 3 {
			t.Fatalf("charging points = %d", len(pts14))
		}
		for _, p := range pts14 {
			if p.PowerKw != nil || p.PowerSign != "unverified" {
				t.Fatalf("power %v sign %s from charger data, want null/unverified", p.PowerKw, p.PowerSign)
			}
		}
		var membership string
		must(t, e.admin.QueryRow(ctx, `SELECT membership FROM volta_telemetry.sessions WHERE vehicle_id = 2 AND kind = 'drive' AND start_ts = $1`, d1.Add(10*time.Second)).Scan(&membership))
		if membership != "complete" {
			t.Fatalf("second drive membership %q, want complete", membership)
		}

		// The API's read path, as the read-only role, through the contract.
		pts, err := e.api.DrivePoints(ctx, 2, d1, d1.Add(2*time.Minute))
		must(t, err)
		if len(pts) != 7 {
			t.Fatalf("points = %d, want 7", len(pts))
		}
		p := pts[3]
		if p.SpeedKph == nil || *p.SpeedKph < 48.27 || *p.SpeedKph > 48.29 {
			t.Fatalf("speed 30 mph -> %v kph", p.SpeedKph)
		}
		if p.PowerKw != nil || p.PowerSign != "unverified" {
			t.Fatalf("power %v sign %s before the operator live gate, want null/unverified", p.PowerKw, p.PowerSign)
		}
		if p.RouteBreakBefore || !pts[0].RouteBreakBefore {
			t.Fatalf("route breaks: first %v (after the silence) inner %v", pts[0].RouteBreakBefore, p.RouteBreakBefore)
		}
		// Only the operator records the sign; the ingest role cannot.
		if _, err := dockerErr("exec", prefix+"postgres", "psql", "-v", "ON_ERROR_STOP=1", "-XAt", "-U", "teslamate", "-d", "teslamate", "-c",
			`SET ROLE volta_telemetry_ingest; INSERT INTO volta_telemetry.power_calibration (vehicle_id, sign, source, evidence_note)
			 VALUES (2, 'discharge_positive', 'operator_live_gate', 'x')`); err == nil {
			t.Fatal("ingest role wrote the power calibration")
		}
		e.psql(t, `INSERT INTO volta_telemetry.power_calibration (vehicle_id, sign, source, evidence_note)
			VALUES (2, 'discharge_positive', 'operator_live_gate', 'acceptance fixture')`)
		pts, err = e.api.DrivePoints(ctx, 2, d1, d1.Add(2*time.Minute))
		must(t, err)
		if p := pts[3]; p.PowerKw == nil || *p.PowerKw != 20 || p.PowerSign != "discharge_positive" {
			t.Fatalf("power %v sign %s after the operator gate, want 20 kW (400 V x 50 A)", p.PowerKw, p.PowerSign)
		}
		e.psql(t, `DELETE FROM volta_telemetry.power_calibration WHERE vehicle_id = 2`)
		p = pts[3]
		if p.ElevationM != nil || p.BatteryLevel == nil || *p.BatteryLevel != 58 {
			t.Fatalf("elevation/battery: %+v", p)
		}
		js, err := json.Marshal(pts[:2])
		must(t, err)
		for _, k := range []string{`"t":"`, `"latitude":`, `"speedKph":`, `"powerKw":`, `"elevationM":null`, `"batteryLevel":58`, `"tripMembership":`, `"routeBreakBefore":`, `"source":"fleet_telemetry"`} {
			if !bytes.Contains(js, []byte(k)) {
				t.Fatalf("contract JSON missing %s: %s", k, js)
			}
		}
		snap, err := e.api.Snapshot(ctx, 2, time.Now())
		must(t, err)
		if snap.Source != contract.Source || len(snap.Values) == 0 {
			t.Fatalf("snapshot %+v", snap)
		}
		if _, err := e.api.Pool.Exec(ctx, `SELECT raw FROM volta_telemetry.records LIMIT 1`); err == nil {
			t.Fatal("read-only API role can read raw payloads")
		}
	})

	t.Run("invalid_gear_is_an_uncertainty_boundary", func(t *testing.T) {
		// Vehicle 3: P -> D -> Gear invalid -> sparse speed-only -> P. The
		// invalid gear opens an unknown span that the next valid gear
		// closes, so the drive is partial with a gear_invalid gap.
		g0 := time.Now().UTC().Add(-2 * time.Hour).Truncate(time.Second)
		at := func(i int) time.Time { return g0.Add(time.Duration(i) * 10 * time.Second) }
		ps := [][]byte{
			sim.Payload(testvin.C, at(0), false, sim.Gear(protos.ShiftState_ShiftStateP), sim.Loc(43, -75), sim.Num(protos.Field_VehicleSpeed, 0)),
			sim.Payload(testvin.C, at(1), false, sim.Gear(protos.ShiftState_ShiftStateD), sim.Loc(43.001, -75), sim.Num(protos.Field_VehicleSpeed, 10)),
			sim.Payload(testvin.C, at(2), false, sim.Invalid(protos.Field_Gear), sim.Loc(43.002, -75), sim.Num(protos.Field_VehicleSpeed, 20)),
			sim.Payload(testvin.C, at(3), false, sim.Num(protos.Field_VehicleSpeed, 25)),
			sim.Payload(testvin.C, at(4), false, sim.Num(protos.Field_VehicleSpeed, 15)),
			sim.Payload(testvin.C, at(5), false, sim.Gear(protos.ShiftState_ShiftStateP), sim.Loc(43.003, -75), sim.Num(protos.Field_VehicleSpeed, 0)),
		}
		c := e.dial(t, e.recvAddr, e.ca, testvin.C)
		for _, p := range ps {
			id := tx()
			send(t, c, testvin.C, id, p, g0)
			expectAck(t, c, id, 30*time.Second)
		}
		c.Close()
		e.waitCount(t, 6, `SELECT count(*) FROM volta_telemetry.records WHERE vehicle_id = 3 AND tx_type = 'V' AND source_ts BETWEEN $1 AND $2`, at(0), at(5))
		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.samples WHERE vehicle_id = 3 AND field = 'Gear' AND source_ts = $1
				AND invalid AND quality = 'invalid'`, at(2)); n != 1 {
			t.Fatal("invalid gear not stored as a vehicle-invalid sample")
		}
		var membership string
		waitFor(t, "drive derived", 30*time.Second, func() (bool, error) {
			err := e.admin.QueryRow(ctx, `SELECT membership FROM volta_telemetry.sessions
				WHERE vehicle_id = 3 AND kind = 'drive' AND start_ts = $1 AND end_ts = $2
				  AND gaps @> '[{"reason":"gear_invalid"}]'`, at(1), at(5)).Scan(&membership)
			return err == nil, err
		})
		if membership != "partial" {
			t.Fatalf("drive across an invalid gear is %q, want partial", membership)
		}
		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.gaps WHERE vehicle_id = 3 AND reason = 'gear_invalid' AND start_ts = $1 AND end_ts = $2`, at(2), at(5)); n != 1 {
			t.Fatalf("gear_invalid gaps = %d, want 1 from the invalid value to the next valid gear", n)
		}
		pts, err := e.api.DrivePoints(ctx, 3, at(1), at(5))
		must(t, err)
		for _, p := range pts {
			if p.TripMembership != "partial" {
				t.Fatalf("point membership %q, want partial", p.TripMembership)
			}
		}
	})

	t.Run("short_known_disconnect_is_a_gap", func(t *testing.T) {
		// Vehicle 4, real time: a 40 s disconnect in the middle of a drive
		// is an unknown span (no minimum length). The drive is partial, the
		// gap is stored, and the route breaks at the first point after it.
		sendD := func(c *sim.Client, d ...*protos.Datum) time.Time {
			at := time.Now().UTC().Truncate(time.Millisecond)
			id := tx()
			send(t, c, testvin.D, id, sim.Payload(testvin.D, at, false, d...), at)
			expectAck(t, c, id, 30*time.Second)
			time.Sleep(1100 * time.Millisecond)
			return at
		}
		c := e.dial(t, e.recvAddr, e.ca, testvin.D)
		time.Sleep(1500 * time.Millisecond)
		p0 := sendD(c, sim.Gear(protos.ShiftState_ShiftStateP), sim.Loc(44, -76), sim.Num(protos.Field_VehicleSpeed, 0))
		d1 := sendD(c, sim.Gear(protos.ShiftState_ShiftStateD), sim.Loc(44.001, -76), sim.Num(protos.Field_VehicleSpeed, 20))
		last := sendD(c, sim.Loc(44.002, -76), sim.Num(protos.Field_VehicleSpeed, 30))
		c.Close()
		time.Sleep(40 * time.Second)
		c2 := e.dial(t, e.recvAddr, e.ca, testvin.D)
		defer c2.Close()
		time.Sleep(1500 * time.Millisecond)
		r1 := sendD(c2, sim.Loc(44.003, -76), sim.Num(protos.Field_VehicleSpeed, 30))
		r2 := sendD(c2, sim.Loc(44.004, -76), sim.Num(protos.Field_VehicleSpeed, 20))
		end := sendD(c2, sim.Gear(protos.ShiftState_ShiftStateP), sim.Loc(44.005, -76), sim.Num(protos.Field_VehicleSpeed, 0))
		e.waitCount(t, 6, `SELECT count(*) FROM volta_telemetry.records WHERE vehicle_id = 4 AND tx_type = 'V' AND source_ts BETWEEN $1 AND $2`, p0, end)
		var membership string
		waitFor(t, "drive derived", 30*time.Second, func() (bool, error) {
			err := e.admin.QueryRow(ctx, `SELECT membership FROM volta_telemetry.sessions
				WHERE vehicle_id = 4 AND kind = 'drive' AND start_ts = $1 AND end_ts = $2
				  AND gaps @> '[{"reason":"disconnected"}]'`, d1, end).Scan(&membership)
			return err == nil, err
		})
		if membership != "partial" {
			t.Fatalf("drive across a 40 s disconnect is %q, want partial", membership)
		}
		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.gaps WHERE vehicle_id = 4 AND reason = 'disconnected' AND start_ts = $1 AND end_ts = $2`, last, r1); n != 1 {
			t.Fatalf("disconnected gaps = %d, want 1 from the last point before to the first after", n)
		}
		pts, err := e.api.DrivePoints(ctx, 4, p0, end)
		must(t, err)
		if len(pts) != 6 {
			t.Fatalf("points = %d, want 6", len(pts))
		}
		for _, p := range pts {
			wantBreak := time.Time(p.T).Equal(r1)
			if p.RouteBreakBefore != wantBreak {
				t.Fatalf("point %v routeBreakBefore %v, want %v (r1 %v r2 %v)", time.Time(p.T), p.RouteBreakBefore, wantBreak, r1, r2)
			}
			if !time.Time(p.T).Before(d1) && p.TripMembership != "partial" {
				t.Fatalf("point %v membership %q, want partial", time.Time(p.T), p.TripMembership)
			}
		}
	})

	t.Run("same_instant_payloads_never_combine", func(t *testing.T) {
		// Vehicle 3 with an operator sign: voltage and current in two
		// different payloads at the same instant never form a power value,
		// an exact retransmit is idempotent, and a different value at the
		// same instant is a conflict, never a guess.
		e.psql(t, `INSERT INTO volta_telemetry.power_calibration (vehicle_id, sign, source, evidence_note)
			VALUES (3, 'discharge_positive', 'operator_live_gate', 'acceptance fixture')`)
		defer e.psql(t, `DELETE FROM volta_telemetry.power_calibration WHERE vehicle_id = 3`)
		s0 := time.Now().UTC().Add(-90 * time.Minute).Truncate(time.Second)
		c := e.dial(t, e.recvAddr, e.ca, testvin.C)
		defer c.Close()
		sendAck := func(p []byte) {
			id := tx()
			send(t, c, testvin.C, id, p, s0)
			expectAck(t, c, id, 30*time.Second)
		}
		sendAck(sim.Payload(testvin.C, s0, false, sim.Loc(45, -77), sim.Num(protos.Field_PackVoltage, 400)))
		sendAck(sim.Payload(testvin.C, s0, false, sim.Num(protos.Field_PackCurrent, 50)))
		sendAck(sim.Payload(testvin.C, s0, true, sim.Num(protos.Field_PackCurrent, 50))) // exact retransmit
		e.waitCount(t, 3, `SELECT count(*) FROM volta_telemetry.records WHERE vehicle_id = 3 AND tx_type = 'V' AND source_ts = $1`, s0)
		if n := e.count(t, `SELECT count(*) FROM volta_telemetry.samples WHERE vehicle_id = 3 AND field = 'PackCurrent' AND source_ts = $1`, s0); n != 1 {
			t.Fatalf("retransmit stored %d PackCurrent samples, want 1", n)
		}
		pts, err := e.api.DrivePoints(ctx, 3, s0, s0)
		must(t, err)
		if len(pts) != 1 {
			t.Fatalf("points at the instant = %d, want 1 (the payload with a position)", len(pts))
		}
		if pts[0].PowerKw != nil {
			t.Fatalf("power %v: payloads at one instant were combined", *pts[0].PowerKw)
		}
		packCurrent := func() contract.Value {
			snap, err := e.api.Snapshot(ctx, 3, time.Now())
			must(t, err)
			for _, v := range snap.Values {
				if v.Field == "PackCurrent" {
					return v
				}
			}
			t.Fatal("no PackCurrent in the snapshot")
			return contract.Value{}
		}
		if v := packCurrent(); v.Quality != "ok" || v.Num == nil || *v.Num != 50 {
			t.Fatalf("PackCurrent after retransmit: %+v", v)
		}
		sendAck(sim.Payload(testvin.C, s0, false, sim.Num(protos.Field_PackCurrent, 60)))
		e.waitCount(t, 4, `SELECT count(*) FROM volta_telemetry.records WHERE vehicle_id = 3 AND tx_type = 'V' AND source_ts = $1`, s0)
		if v := packCurrent(); v.Quality != "conflict" || v.Num != nil || !v.Invalid {
			t.Fatalf("PackCurrent with two values at one instant: %+v, want conflict without a value", v)
		}
		pts, err = e.api.DrivePoints(ctx, 3, s0, s0)
		must(t, err)
		for _, p := range pts {
			if p.PowerKw != nil {
				t.Fatalf("power %v from payloads at one instant", *p.PowerKw)
			}
		}
	})

	t.Run("same_second_old_connect_does_not_cross_receiver_generation", func(t *testing.T) {
		st := store.New(e.admin)
		second := time.Now().UTC().Truncate(time.Second).Add(-time.Second)
		started := second.Add(800 * time.Millisecond)
		now := second.Add(900 * time.Millisecond)
		oldEvent := second.Add(100 * time.Millisecond)
		_, err := e.admin.Exec(ctx, `INSERT INTO volta_telemetry.connectivity
			(vehicle_id, connection_id, status, source_ts, network_interface, received_at)
			VALUES (99, 'old-generation', 'CONNECTED', $1, '', $1)`, oldEvent)
		must(t, err)
		defer func() { _, _ = e.admin.Exec(ctx, `DELETE FROM volta_telemetry.connectivity WHERE vehicle_id = 99`) }()
		must(t, st.UpdateHealth(ctx, store.Health{
			ReceiverGeneration: "replacement-generation", ReceiverStartedAt: started,
			ReceiverSeenAt: now, ConsumerStartedAt: second, CaughtUpAt: now,
		}, now))
		link, err := st.Link(ctx, 99, now, time.Minute)
		must(t, err)
		if link.Connected {
			t.Fatal("old same-second CONNECTED crossed receiver generation")
		}
		newReceived := started.Add(10 * time.Millisecond)
		_, err = e.admin.Exec(ctx, `INSERT INTO volta_telemetry.connectivity
			(vehicle_id, connection_id, status, source_ts, network_interface, received_at)
			VALUES (99, 'replacement-generation', 'CONNECTED', $1, '', $2)`, second.Add(200*time.Millisecond), newReceived)
		must(t, err)
		link, err = st.Link(ctx, 99, now, time.Minute)
		must(t, err)
		if !link.Connected || !link.Since.Equal(started) {
			t.Fatalf("current exact-generation CONNECTED not accepted: %+v", link)
		}
	})

	t.Run("receiver_sigkill_drops_stream_connected", func(t *testing.T) {
		// A receiver killed without a DISCONNECTED event must not leave the
		// last CONNECTED event "current": liveness comes from the receiver
		// guard, per start generation.
		c := e.dial(t, e.recvAddr, e.ca, testvin.A)
		defer c.Close()
		connected := func(at time.Time) bool {
			s, err := e.api.Snapshot(ctx, 1, at)
			must(t, err)
			return s.StreamConnected
		}
		waitFor(t, "stream connected", 90*time.Second, func() (bool, error) { return connected(time.Now()), nil })
		later, err := e.api.Snapshot(ctx, 1, time.Now().Add(24*time.Hour))
		must(t, err)
		if later.StreamConnected {
			t.Fatal("stream still connected when read 24 h later")
		}
		for _, v := range later.Values {
			if v.Freshness != contract.FreshLastKnown {
				t.Fatalf("%s is %s 24 h later", v.Field, v.Freshness)
			}
		}
		gen := e.psql(t, `SELECT receiver_generation FROM volta_telemetry.stream_health WHERE id = 1`)
		docker(t, "kill", "--signal", "KILL", prefix+"receiver")
		waitFor(t, "stream not connected after receiver death", 150*time.Second, func() (bool, error) { return !connected(time.Now()), nil })
		e.waitUsage(t, "meter unknown without a receiver", func(m map[string]any) bool {
			return m["state"] == "unknown" && hasReason(m, "receiver_unobserved")
		})
		docker(t, "start", prefix+"receiver")
		e.recvAddr = e.waitListening(t, "receiver")
		waitFor(t, "new receiver generation observed", 90*time.Second, func() (bool, error) {
			out := e.psql(t, fmt.Sprintf(`SELECT receiver_generation <> '%s' AND receiver_seen_at > now() - interval '30 seconds'
				FROM volta_telemetry.stream_health WHERE id = 1`, gen))
			return out == "t", nil
		})
		if connected(time.Now()) {
			t.Fatal("CONNECTED from before the restart counted as current")
		}
		c2 := e.dial(t, e.recvAddr, e.ca, testvin.A)
		defer c2.Close()
		waitFor(t, "stream connected again", 90*time.Second, func() (bool, error) { return connected(time.Now()), nil })
	})

	t.Run("retention_bounds_raw_and_rejections", func(t *testing.T) {
		st := store.New(e.admin)
		if _, err := st.Prune(ctx, store.Retention{Raw: time.Nanosecond, Rejections: time.Nanosecond, Receipts: 30 * 24 * time.Hour, BatchLimit: 5000}, time.Now()); err == nil {
			t.Fatal("prune accepted a receipt retention shorter than two billing months")
		}
		// Earlier subtests' closed connections produce connectivity records
		// asynchronously; let the handoff go quiet so none lands after the
		// prune cutoff.
		prev := int64(-1)
		waitFor(t, "consumer quiescent", 60*time.Second, func() (bool, error) {
			out, err := dockerErr("exec", prefix+"redpanda", "rpk", "group", "describe", "volta-telemetry-consumer")
			if err != nil || !regexp.MustCompile(`TOTAL-LAG\s+0\b`).MatchString(out) {
				return false, err
			}
			n := e.count(t, `SELECT count(*) FROM volta_telemetry.records`)
			stable := n == prev
			prev = n
			if !stable {
				time.Sleep(2 * time.Second)
			}
			return stable, nil
		})
		billed := e.billedSignals(t)
		n, err := st.Prune(ctx, store.Retention{Raw: time.Nanosecond, Rejections: time.Nanosecond, Receipts: store.DefaultRetention.Receipts, BatchLimit: 5000}, time.Now().Add(time.Second))
		must(t, err)
		if n == 0 {
			t.Fatal("prune touched nothing")
		}
		if left := e.count(t, `SELECT count(*) FROM volta_telemetry.records WHERE raw IS NOT NULL`); left != 0 {
			t.Fatalf("%d raw payloads left", left)
		}
		if left := e.count(t, `SELECT count(*) FROM volta_telemetry.rejected_records`); left != 0 {
			t.Fatalf("%d rejections left", left)
		}
		if after := e.billedSignals(t); after != billed {
			t.Fatalf("pruning diagnostics changed billing: %d -> %d", billed, after)
		}
		out := docker(t, "exec", prefix+"redpanda", "rpk", "topic", "describe", ns+"_V", "-c")
		for _, want := range []string{`retention\.ms\s+604800000`, `retention\.bytes\s+1073741824`, `cleanup\.policy\s+delete`, `write\.caching\s+false`} {
			if !regexp.MustCompile(want).MatchString(out) {
				t.Errorf("topic config missing %s", want)
			}
		}
		if out := docker(t, "exec", prefix+"redpanda", "rpk", "cluster", "config", "get", "auto_create_topics_enabled"); out != "false" {
			t.Errorf("auto_create_topics_enabled = %q", out)
		}
	})

	t.Run("upstream_rate_limiter_inert_in_v095", func(t *testing.T) {
		// v0.9.5 never sets RateLimit.MessageIntervalTimeSecond, so the
		// configured 600/60s limiter admits everything. Tripwire: if an
		// upgrade makes it effective, excess messages go unacked (the car
		// resends) and this test must be revisited with the docs.
		c := e.dial(t, e.recvAddr, e.ca, testvin.Rogue)
		defer c.Close()
		const n = 640
		for i := 0; i < n; i++ {
			send(t, c, testvin.Rogue, fmt.Sprintf("rl-%d", i), sim.Payload(testvin.Rogue, base, false, sim.Num(protos.Field_Soc, 1)), base)
		}
		acks := 0
		for {
			if _, err := c.ReadAck(10 * time.Second); err != nil {
				break
			}
			acks++
		}
		if acks != n {
			t.Fatalf("acks = %d of %d: upstream rate limiting changed; update docs/TELEMETRY_CAPTURE.md", acks, n)
		}
	})

	t.Run("full_producer_queue_withholds_acks", func(t *testing.T) {
		// Same production config with a 3-message producer queue, to reach
		// the bound quickly: while the broker is down, messages beyond the
		// queue are refused and never acked, so the car keeps them.
		var cfg map[string]any
		b, err := os.ReadFile(filepath.Join(e.dir, "receiver-test", "config.json"))
		must(t, err)
		must(t, json.Unmarshal(b, &cfg))
		cfg["kafka"].(map[string]any)["queue.buffering.max.messages"] = 3
		small, _ := json.Marshal(cfg)
		writeFile(t, filepath.Join(e.dir, "receiver-smallq", "config.json"), small)
		addr := e.startReceiver(t, "receiver-smallq", "receiver-smallq", true, "")
		c := e.dial(t, addr, e.ca, testvin.A)
		defer c.Close()
		time.Sleep(2 * time.Second) // let the CONNECTED event drain from the queue
		docker(t, "pause", prefix+"redpanda")
		const n = 10
		at := base.Add(30 * time.Minute)
		for i := 0; i < n; i++ {
			send(t, c, testvin.A, fmt.Sprintf("q-%d", i), drivePayload(testvin.A, at.Add(time.Duration(i)*time.Second), 33.3, 33.3, 1, nil, 50), base)
		}
		if _, err := c.ReadAck(5 * time.Second); err == nil {
			docker(t, "unpause", prefix+"redpanda")
			t.Fatal("acked while the broker was paused")
		}
		docker(t, "unpause", prefix+"redpanda")
		acks := 0
		for {
			if _, err := c.ReadAck(30 * time.Second); err != nil {
				break
			}
			acks++
		}
		if acks == 0 || acks > 3 {
			t.Fatalf("acks = %d of %d, want 1..3 (queue bound)", acks, n)
		}
		e.waitCount(t, int64(acks), `SELECT count(*) FROM volta_telemetry.samples WHERE vehicle_id = 1 AND field = 'Location' AND latitude = 33.3`)
		if l := logsOf(t, "receiver-smallq"); strings.Contains(l, "33.3") || strings.Contains(l, testvin.A) {
			t.Fatal("queue-full error path logged a value or VIN")
		}
	})

	t.Run("uncountable_record_makes_meter_unknown", func(t *testing.T) {
		// A record whose payload cannot be decoded cannot be counted: the
		// month's total becomes a lower bound and the meter says unknown
		// until the record is accounted for.
		cmd := exec.Command("docker", "exec", "-i", prefix+"redpanda", "rpk", "topic", "produce", ns+"_V",
			"-k", "garbage", "-H", "txtype:V", "-H", "vin:garbage", "-H", fmt.Sprintf("receivedat:%d", time.Now().UnixMilli()))
		cmd.Stdin = strings.NewReader("zzzz\n")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("produce: %v %s", err, out)
		}
		e.waitCount(t, 1, `SELECT count(*) FROM volta_telemetry.receipts WHERE topic = $1 AND signal_count IS NULL`, ns+"_V")
		e.waitUsage(t, "meter unknown with an uncountable record", func(m map[string]any) bool {
			return m["state"] == "unknown" && hasReason(m, "uncountable_records")
		})
		e.psql(t, `DELETE FROM volta_telemetry.rejected_records j USING volta_telemetry.receipts r
			WHERE (j.topic, j.kafka_partition, j.kafka_offset) = (r.topic, r.kafka_partition, r.kafka_offset) AND r.signal_count IS NULL;
			DELETE FROM volta_telemetry.receipts WHERE signal_count IS NULL;`)
		e.waitUsage(t, "meter complete again", func(m map[string]any) bool { return m["confidence"] == "complete" })
	})

	t.Run("two_second_drive_reaches_postgres", func(t *testing.T) {
		// Real protobuf frames over the pinned mTLS receiver, at the normal
		// profile's two-second cadence. Slow state is co-timed every 30 s;
		// no value is synthesized or forward-filled by the ingester.
		apiWindowStart = time.Now().UTC().Add(-6 * time.Hour).Truncate(time.Second)
		const points = 40
		apiWindowEnd = apiWindowStart.Add((points - 1) * 2 * time.Second)
		c := e.dial(t, e.recvAddr, e.ca, testvin.B)
		defer c.Close()
		for i := 0; i < points; i++ {
			at := apiWindowStart.Add(time.Duration(i) * 2 * time.Second)
			d := []*protos.Datum{
				sim.Loc(43+float64(i)/10000, -75),
				sim.Num(protos.Field_VehicleSpeed, 30),
				sim.Num(protos.Field_GpsHeading, 90),
				sim.Num(protos.Field_PackVoltage, 400),
				sim.Num(protos.Field_PackCurrent, 25),
				sim.Num(protos.Field_LongitudinalAcceleration, float64(i%5-2)/10),
				sim.Num(protos.Field_LateralAcceleration, float64(i%3-1)/10),
			}
			if i == 0 {
				d = append(d, sim.Gear(protos.ShiftState_ShiftStateD))
			} else if i == points-1 {
				d = append(d, sim.Gear(protos.ShiftState_ShiftStateP))
			}
			if i%15 == 0 || i == points-1 {
				d = append(d,
					sim.Num(protos.Field_BatteryLevel, 70-float64(i)/20),
					sim.Num(protos.Field_EnergyRemaining, 52-float64(i)/40),
					sim.Num(protos.Field_ModuleTempMin, 24),
					sim.Num(protos.Field_ModuleTempMax, 27),
					sim.Num(protos.Field_InsideTemp, 21),
					sim.Num(protos.Field_OutsideTemp, 14),
				)
			}
			id := tx()
			send(t, c, testvin.B, id, sim.Payload(testvin.B, at, false, d...), at)
			expectAck(t, c, id, 30*time.Second)
		}
		e.waitCount(t, points, `SELECT count(DISTINCT source_ts) FROM volta_telemetry.records
			WHERE vehicle_id = 2 AND tx_type = 'V' AND source_ts BETWEEN $1 AND $2`, apiWindowStart, apiWindowEnd)
		var maxStep float64
		must(t, e.admin.QueryRow(ctx, `SELECT max(extract(epoch FROM source_ts-prev)) FROM (
			SELECT source_ts,lag(source_ts) OVER (ORDER BY source_ts) prev
			FROM volta_telemetry.samples WHERE vehicle_id=2 AND field='Location' AND source_ts BETWEEN $1 AND $2
		) q WHERE prev IS NOT NULL`, apiWindowStart, apiWindowEnd).Scan(&maxStep))
		if maxStep > 2 {
			t.Fatalf("dense fixture maximum GPS cadence = %.3f seconds", maxStep)
		}
	})

	t.Run("teslamate_tables_untouched_and_no_vin_in_any_log", func(t *testing.T) {
		if after := e.psql(t, `SELECT md5(string_agg(t::text, ',' ORDER BY id)) FROM public.positions t`); after != positionsBefore {
			t.Fatal("public.positions changed")
		}
		if n := e.psql(t, `SELECT count(*) FROM pg_tables WHERE schemaname = 'public'`); n != "1" {
			t.Fatalf("public tables = %s", n)
		}
		// Every container of the run, every log line: no VIN, ever. Values
		// (fixture coordinates, the poison sentinel) never reach the
		// receiver, consumer or database logs.
		names := strings.Fields(docker(t, "ps", "-a", "--filter", "name=^/"+prefix, "--format", "{{.Names}}"))
		if len(names) < 5 {
			t.Fatalf("containers %v", names)
		}
		for _, full := range names {
			n := strings.TrimPrefix(full, prefix)
			l := logsOf(t, n)
			if strings.Contains(l, "5YJ3E1EA0XF") {
				t.Errorf("%s logs contain a VIN", n)
			}
			if strings.HasPrefix(n, "receiver") {
				guardLogs(t, n)
			}
			if strings.HasPrefix(n, "receiver") || n == "consumer" || n == "postgres" {
				for _, v := range []string{"12.345678", "40.517317", "43.0001", "98.765432", "postgres://", "Failing row"} {
					if strings.Contains(l, v) {
						t.Errorf("%s logs contain %q", n, v)
					}
				}
			}
		}
	})

	t.Run("bun_api_returns_dense_fleet_series", func(t *testing.T) {
		// This runs last because the standalone API harness replaces the
		// one-table TeslaMate sentinel with its disposable full-schema fixture.
		// Connection strings stay in the child environment and are never
		// included in failure output.
		cmd := exec.Command("bun", "test/fleet-pipeline.ts")
		cmd.Dir = filepath.Join(absPath(t, filepath.Join("..", "..")), "server")
		cmd.Env = append(os.Environ(),
			"VT_API_TEST_DATABASE_URL="+e.admin.Config().ConnString(),
			"VT_API_READER_DATABASE_URL="+e.api.Pool.Config().ConnString(),
			"VT_PIPELINE_DISPOSABLE=volta-telemetry-test-postgres",
			"VT_API_WINDOW_START="+apiWindowStart.Format(time.RFC3339Nano),
			"VT_API_WINDOW_END="+apiWindowEnd.Format(time.RFC3339Nano),
		)
		var output bytes.Buffer
		cmd.Stdout, cmd.Stderr = &output, &output
		if err := cmd.Run(); err != nil {
			stage := "unknown"
			if m := regexp.MustCompile(`receiver-to-API acceptance failed:\s*([a-z-]+(?:\s+[a-z-]+)?)`).FindStringSubmatch(output.String()); m != nil {
				stage = strings.ReplaceAll(m[1], " ", "-")
			}
			t.Fatalf("Bun API pipeline acceptance failed at fixed stage %s", stage)
		}
		proof := regexp.MustCompile(`\{"receiverToAPI":"PASS","samples":40,"chargeSamples":[0-9]+,"maxGPSIntervalSeconds":2\}`).FindString(output.String())
		if proof == "" {
			t.Fatal("Bun API pipeline returned no fixed success receipt")
		}
		t.Log(proof)
	})
}
