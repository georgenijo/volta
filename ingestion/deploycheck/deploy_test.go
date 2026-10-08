// Package deploycheck statically checks deploy/telemetry: exposure, trust,
// durability and log hygiene settings that must not drift.
package deploycheck

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

var deployDir = filepath.Join("..", "..", "deploy", "telemetry")

type service struct {
	Image string `yaml:"image"`
	Build *struct {
		Context    string `yaml:"context"`
		Dockerfile string `yaml:"dockerfile"`
		Target     string `yaml:"target"`
	} `yaml:"build"`
	Healthcheck *struct {
		Test []string `yaml:"test"`
	} `yaml:"healthcheck"`
	Ports       []string          `yaml:"ports"`
	Expose      []string          `yaml:"expose"`
	Networks    []string          `yaml:"networks"`
	ReadOnly    *bool             `yaml:"read_only"`
	CapDrop     []string          `yaml:"cap_drop"`
	CapAdd      []string          `yaml:"cap_add"`
	SecurityOpt []string          `yaml:"security_opt"`
	Privileged  bool              `yaml:"privileged"`
	NetworkMode string            `yaml:"network_mode"`
	User        string            `yaml:"user"`
	Environment map[string]string `yaml:"environment"`
	Volumes     []string          `yaml:"volumes"`
	Command     []string          `yaml:"command"`
	MemLimit    string            `yaml:"mem_limit"`
	Logging     struct {
		Driver string `yaml:"driver"`
	} `yaml:"logging"`
}

type compose struct {
	Services map[string]service `yaml:"services"`
	Networks map[string]struct {
		Name     string `yaml:"name"`
		Internal bool   `yaml:"internal"`
		External bool   `yaml:"external"`
	} `yaml:"networks"`
}

func loadCompose(t *testing.T) compose {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(deployDir, "compose.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var c compose
	if err := yaml.Unmarshal(b, &c); err != nil {
		t.Fatal(err)
	}
	return c
}

func loadReceiverConfig(t *testing.T) map[string]any {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(deployDir, "receiver", "config.prod.json"))
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

var digestRe = regexp.MustCompile(`^[a-z0-9./-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$`)

func TestComposeExposure(t *testing.T) {
	c := loadCompose(t)
	want := []string{"consumer", "receiver", "redpanda", "redpanda-init"}
	for _, name := range want {
		if _, ok := c.Services[name]; !ok {
			t.Fatalf("service %s missing", name)
		}
	}
	if len(c.Services) != len(want) {
		t.Fatalf("unexpected services: %d", len(c.Services))
	}
	for name, s := range c.Services {
		if s.Privileged || s.NetworkMode != "" {
			t.Errorf("%s: privileged or custom network_mode", name)
		}
		if len(s.Expose) != 0 {
			t.Errorf("%s: expose is not allowed", name)
		}
		if !contains(s.CapDrop, "ALL") || len(s.CapAdd) != 0 {
			t.Errorf("%s: must drop all capabilities and add none", name)
		}
		if !contains(s.SecurityOpt, "no-new-privileges:true") {
			t.Errorf("%s: no-new-privileges missing", name)
		}
		if s.Logging.Driver != "local" {
			t.Errorf("%s: log driver %q, want local (rotated, not shipped)", name, s.Logging.Driver)
		}
		if s.MemLimit == "" {
			t.Errorf("%s: mem_limit missing", name)
		}
		if s.Build != nil {
			// Built locally from ingestion/Dockerfile, whose bases are pinned
			// (TestDockerfilePinned).
			if s.Build.Context != "../../ingestion" || s.Build.Dockerfile != "Dockerfile" || s.Build.Target != name {
				t.Errorf("%s: build %+v, want ingestion/Dockerfile target %s", name, *s.Build, name)
			}
		} else if !digestRe.MatchString(s.Image) {
			t.Errorf("%s: image %q not pinned by digest", name, s.Image)
		}
		if name != "receiver" && len(s.Ports) != 0 {
			t.Errorf("%s: publishes ports %v", name, s.Ports)
		}
		if name != "redpanda" && (s.ReadOnly == nil || !*s.ReadOnly) {
			t.Errorf("%s: root filesystem must be read-only", name)
		}
	}
	r := c.Services["receiver"]
	if len(r.Ports) != 1 || r.Ports[0] != "127.0.0.1:8448:8448" {
		t.Errorf("receiver ports %v, want only 127.0.0.1:8448:8448", r.Ports)
	}
	if r.Build == nil || r.Image != "volta-telemetry-receiver:local" {
		t.Errorf("receiver must be the guarded image built from ingestion/Dockerfile")
	}
	if len(r.Command) == 0 || r.Command[0] != "-config" {
		t.Errorf("receiver command %v must pass only receiver flags (the guard entrypoint runs /fleet-telemetry)", r.Command)
	}
	for name, want := range map[string]string{"receiver": "/volta-receiver-guard", "consumer": "/volta-telemetry-consumer"} {
		h := c.Services[name].Healthcheck
		if h == nil || len(h.Test) != 3 || h.Test[0] != "CMD" || h.Test[1] != want || h.Test[2] != "healthcheck" {
			t.Errorf("%s healthcheck must run %s healthcheck", name, want)
		}
	}
	if r.Environment["SUPPRESS_TLS_HANDSHAKE_ERROR_LOGGING"] != "true" {
		t.Error("receiver must suppress TLS handshake error logs (they carry remote addresses)")
	}
	for _, v := range r.Volumes {
		if !strings.HasSuffix(v, ":ro") {
			t.Errorf("receiver volume %q must be read-only", v)
		}
	}
	cons := c.Services["consumer"]
	if cons.User != "65532:65532" {
		t.Errorf("consumer user %q", cons.User)
	}
	for _, v := range cons.Volumes {
		if !strings.HasSuffix(v, ":ro") {
			t.Errorf("consumer volume %q must be read-only", v)
		}
	}
	for k := range cons.Environment {
		if strings.Contains(k, "PASSWORD") || (strings.Contains(k, "SECRET") && !strings.HasSuffix(k, "_FILE")) ||
			(strings.Contains(k, "DATABASE_URL") && !strings.HasSuffix(k, "_FILE")) {
			t.Errorf("consumer secret %s must come from a file", k)
		}
	}
	rp := c.Services["redpanda"]
	if contains(rp.Command, "--mode=dev-container") || contains(rp.Command, "dev-container") {
		t.Error("redpanda must not run in dev-container mode (relaxed fsync)")
	}
	for _, a := range rp.Command {
		if strings.Contains(a, "developer_mode") || strings.Contains(a, "unsafe_bypass_fsync") {
			t.Errorf("redpanda flag %q weakens durability", a)
		}
	}
	for key, n := range c.Networks {
		if key == "telemetry" || key == "telemetry-usage" {
			if !n.Internal {
				t.Errorf("network %s must be internal", key)
			}
		}
	}
	if !contains(rp.Networks, "telemetry") || len(rp.Networks) != 1 {
		t.Errorf("redpanda networks %v, want only the internal telemetry network", rp.Networks)
	}
}

// The receiver image is the official one, unmodified, with the guard as the
// entrypoint; no stage may use an unpinned base.
func TestDockerfilePinned(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "Dockerfile"))
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	fromRe := regexp.MustCompile(`(?m)^FROM\s+(\S+)(?:\s+AS\s+(\S+))?`)
	stages := map[string]string{}
	for _, m := range fromRe.FindAllStringSubmatch(s, -1) {
		if !digestRe.MatchString(m[1]) {
			t.Errorf("FROM %s is not pinned by digest", m[1])
		}
		stages[m[2]] = m[1]
	}
	if got := stages["receiver"]; got != "tesla/fleet-telemetry:v0.9.5@sha256:7cb5f429210128b8edc5aac1e403589315893106f4c5a3ff85cb32213e2f8e37" {
		t.Errorf("receiver stage base %q is not the pinned official v0.9.5", got)
	}
	if stages["consumer"] == "" || stages["build"] == "" {
		t.Error("build and consumer stages missing")
	}
	recv := s[strings.Index(s, "AS receiver"):strings.Index(s, "AS consumer")]
	for _, want := range []string{
		"COPY --from=build /out/volta-receiver-guard /volta-receiver-guard",
		`ENTRYPOINT ["/volta-receiver-guard", "--", "/fleet-telemetry"]`,
		"USER 65532:65532",
	} {
		if !strings.Contains(recv, want) {
			t.Errorf("receiver stage missing %q", want)
		}
	}
	if strings.Count(recv, "COPY") != 1 || strings.Contains(recv, "RUN ") {
		t.Error("receiver stage may only add the guard binary")
	}
}

// Telemetry CI is an active workflow, not a proposal.
func TestCIWorkflowActive(t *testing.T) {
	root := filepath.Join("..", "..")
	b, err := os.ReadFile(filepath.Join(root, ".github", "workflows", "telemetry.yml"))
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	for _, want := range []string{"go test", "-tags acceptance", "test-check.sh", "test-funnel.sh", "test-renew.sh", "--target receiver", "--target consumer"} {
		if !strings.Contains(s, want) {
			t.Errorf("telemetry workflow missing %q", want)
		}
	}
	for _, banned := range []string{"TESLA_", "TS_AUTHKEY", "TAILSCALE"} {
		if strings.Contains(s, banned) {
			t.Errorf("telemetry workflow references %q: CI uses fakes only", banned)
		}
	}
	if workflowSecretReference(s) {
		t.Error("telemetry workflow references a GitHub secret context: CI uses fakes only")
	}
	if _, err := os.Stat(filepath.Join(deployDir, "ci")); err == nil {
		t.Error("deploy/telemetry/ci proposal must be removed once the workflow is active")
	}
}

func workflowSecretReference(s string) bool {
	return regexp.MustCompile(`\$\{\{\s*secrets\.|\bsecrets\.[A-Z_][A-Z0-9_]*\b`).MatchString(s)
}

func TestWorkflowSecretReferenceDetection(t *testing.T) {
	for _, bad := range []string{"${{ secrets.TESLA_TOKEN }}", "token: secrets.TS_AUTHKEY"} {
		if !workflowSecretReference(bad) {
			t.Fatalf("secret reference not detected: %q", bad)
		}
	}
	for _, safe := range []string{"python3 test-prepare-secrets.py", "# no repository secret is referenced"} {
		if workflowSecretReference(safe) {
			t.Fatalf("safe workflow text rejected: %q", safe)
		}
	}
}

func TestReceiverProdConfig(t *testing.T) {
	m := loadReceiverConfig(t)
	tlsCfg, _ := m["tls"].(map[string]any)
	if tlsCfg == nil {
		t.Fatal("tls block missing")
	}
	if _, ok := tlsCfg["ca_file"]; ok {
		t.Error("prod config must not set tls.ca_file: it is appended to the trusted client CA pool")
	}
	if v, _ := m["use_default_eng_ca"].(bool); v {
		t.Error("prod config must not trust Tesla's engineering CA")
	}
	if m["log_level"] != "info" {
		t.Errorf("log_level %v, want info", m["log_level"])
	}
	if _, ok := m["monitoring"]; ok {
		t.Error("monitoring must stay off: upstream metrics carry VIN labels")
	}
	if _, ok := m["logger"]; ok {
		t.Error("no logger dispatcher: it would print payloads")
	}
	if v, ok := m["transmit_decoded_records"].(bool); ok && v {
		t.Error("transmit_decoded_records must stay off")
	}
	if v, _ := m["vins_signal_tracking_enabled"].([]any); len(v) != 0 {
		t.Error("vins_signal_tracking_enabled must be empty")
	}
	records, _ := m["records"].(map[string]any)
	if len(records) != 2 {
		t.Errorf("records %v, want exactly V and connectivity", records)
	}
	for _, k := range []string{"V", "connectivity"} {
		d, _ := records[k].([]any)
		if len(d) != 1 || d[0] != "kafka" {
			t.Errorf("records.%s = %v, want [kafka]", k, records[k])
		}
	}
	ack, _ := m["reliable_ack_sources"].(map[string]any)
	if len(ack) != 1 || ack["V"] != "kafka" {
		t.Errorf("reliable_ack_sources %v, want {V: kafka}", ack)
	}
	k, _ := m["kafka"].(map[string]any)
	if k["acks"] != "all" || k["enable.idempotence"] != true {
		t.Errorf("kafka must use acks=all and idempotence: %v", k)
	}
	for _, key := range []string{"queue.buffering.max.messages", "queue.buffering.max.kbytes", "message.timeout.ms"} {
		if _, ok := k[key].(float64); !ok {
			t.Errorf("kafka.%s must be set (bounded producer queue)", key)
		}
	}
	rl, _ := m["rate_limit"].(map[string]any)
	if rl["enabled"] != true {
		t.Error("rate limit must be enabled (excess is dropped unacked, so the car resends)")
	}
	if m["host"] != "0.0.0.0" || m["port"] != float64(8448) {
		t.Errorf("receiver must listen on container port 8448")
	}
	if _, ok := m["status_port"]; ok {
		t.Error("status_port is unauthenticated; leave it unset")
	}
}

func TestTopicInitBounded(t *testing.T) {
	b, err := os.ReadFile(filepath.Join(deployDir, "redpanda", "init-topics.sh"))
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	for _, want := range []string{"auto_create_topics_enabled false", "write_caching_default false",
		"retention_ms=604800000", "retention_bytes=1073741824", "cleanup.policy=delete", "write.caching=false", "-r 1"} {
		if !strings.Contains(s, want) {
			t.Errorf("init-topics.sh missing %q", want)
		}
	}
}

func TestFunnelScriptsScope(t *testing.T) {
	lib, err := os.ReadFile(filepath.Join(deployDir, "funnel", "lib.sh"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"FUNNEL_PORT=10000", "FUNNEL_TARGET=tcp://127.0.0.1:8448",
		`EXPECTED_SERVE_PORTS="443 8443 8446 8447 8500 8844 8845 8879 9443"`} {
		if !strings.Contains(string(lib), want) {
			t.Errorf("funnel/lib.sh missing %q", want)
		}
	}
	for _, f := range []string{"stage-funnel.sh", "rollback-funnel.sh", "check.sh", "lib.sh"} {
		b, err := os.ReadFile(filepath.Join(deployDir, "funnel", f))
		if err != nil {
			t.Fatal(err)
		}
		s := string(b)
		for _, banned := range []string{"--tls-terminated-tcp", "tailscale serve reset", "funnel reset", "--set-path", "--https="} {
			if strings.Contains(s, banned) {
				t.Errorf("%s uses %q", f, banned)
			}
		}
	}
	stage, _ := os.ReadFile(filepath.Join(deployDir, "funnel", "stage-funnel.sh"))
	if !strings.Contains(string(stage), `[[ "${1:-}" == "--apply" ]] && apply=1`) {
		t.Error("stage-funnel.sh must default to a dry run")
	}
}

func TestNoSecretsCommitted(t *testing.T) {
	keyRe := regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----`)
	vinRe := regexp.MustCompile(`\b[5L]YJ[0-9A-HJ-NPR-Z]{14}\b|\b7SA[0-9A-HJ-NPR-Z]{14}\b`)
	err := filepath.WalkDir(deployDir, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		if keyRe.Match(b) {
			t.Errorf("%s contains a private key", p)
		}
		for _, v := range vinRe.FindAll(b, -1) {
			if !strings.HasPrefix(string(v), "5YJ3E1EA0XF") { // the fake test VIN family
				t.Errorf("%s contains a VIN-like string", p)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}
