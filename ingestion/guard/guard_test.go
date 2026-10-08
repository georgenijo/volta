package guard

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/georgenijo/volta/ingestion/internal/testvin"
)

var t0 = time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)

// Real v0.9.5 line shapes (logrus JSON), with synthetic identifiers.
func upstreamLines() []string {
	vin := testvin.A
	return []string{
		fmt.Sprintf(`{"context":"server","error":"unexpected sender id","expected_sender_id":"vehicle_device.%s","level":"error","msg":"unexpected_sender_id","record_type":"alerts","sender_id":"vehicle_device.%s","time":"2026-10-08T12:00:00Z","txid":"t1"}`, vin, testvin.B),
		fmt.Sprintf(`{"context":"server","level":"error","msg":"unauthorized_sender_id","sender_id":"%s","time":"2026-10-08T12:00:00Z"}`, vin),
		fmt.Sprintf(`{"activity":true,"context":"server","level":"info","method":"GET","msg":"request_start","remote_ip":"203.0.113.7:41234","urlPath":"/","uuid":"u"}`),
		fmt.Sprintf(`{"activity":true,"context":"server","level":"info","msg":"socket_connected","device_id":"%s","network_interface":"wifi"}`, vin),
		fmt.Sprintf(`{"context":"server","error":"kafka: %s 12.3456","level":"error","msg":"kafka_err"}`, vin),
		fmt.Sprintf(`{"activity":true,"context":"server","level":"info","msg":"http: TLS handshake error from 203.0.113.7:5555: remote error: %s\n"}`, vin),
		fmt.Sprintf(`{"level":"info","msg":"record_payload","vin":"%s","data":"12.3456"}`, vin),
		fmt.Sprintf(`plain text %s`, vin),
		fmt.Sprintf(`panic: error=load_service_config value="%s"`, vin),
	}
}

func TestOnlyCodesLeave(t *testing.T) {
	var out bytes.Buffer
	f := &Filter{Out: &out, Now: func() time.Time { return t0 }}
	f.Consume(strings.NewReader(strings.Join(upstreamLines(), "\n") + "\n" + strings.Repeat("x", MaxLine+10) + "\n"))
	f.Flush()
	got := out.String()
	for _, s := range []string{testvin.A, testvin.B, "203.0.113.7", "12.3456", "vehicle_device", "load_service_config", "TLS handshake"} {
		if strings.Contains(got, s) {
			t.Fatalf("guard output contains %q:\n%s", s, got)
		}
	}
	var events []Event
	for _, l := range strings.Split(strings.TrimSpace(got), "\n") {
		var e Event
		dec := json.NewDecoder(strings.NewReader(l))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&e); err != nil {
			t.Fatalf("not a guard event: %q", l)
		}
		events = append(events, e)
	}
	want := []string{"unexpected_sender_id", "unauthorized_sender_id", "request_start", "socket_connected", "kafka_error", CodePanic, CodeUnrecognized}
	if len(events) != len(want) {
		t.Fatalf("events %+v", events)
	}
	for i, w := range want {
		if events[i].Event != w {
			t.Fatalf("event %d = %s want %s", i, events[i].Event, w)
		}
	}
	// TLS handshake text, record_payload, plain text, overlong line.
	if events[len(events)-1].Count != 4 {
		t.Fatalf("unrecognized count %d", events[len(events)-1].Count)
	}
}

func TestEmittedCodesComeFromTheTable(t *testing.T) {
	for msg, code := range Allowed {
		if strings.ContainsAny(code, " \"\\") || code == "" {
			t.Fatalf("bad code for %s: %q", msg, code)
		}
	}
	// A message that merely contains an allowed name is not allowed.
	if _, _, ok := Classify([]byte(`{"msg":"socket_err ` + testvin.A + `","level":"error"}`)); ok {
		t.Fatal("prefix match accepted")
	}
}

func TestRateBound(t *testing.T) {
	var out bytes.Buffer
	f := &Filter{Out: &out, PerSecond: 5, Now: func() time.Time { return t0 }}
	for i := 0; i < 50; i++ {
		f.Line([]byte(`{"msg":"socket_err","level":"error"}`))
	}
	f.Flush()
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 6 || !strings.Contains(lines[5], `"event":"receiver_log_suppressed","count":45`) {
		t.Fatalf("%v", lines)
	}
}

// TestSupervisorWithFakeReceiver runs a child that writes VIN-bearing lines
// and listens, then exits with a signal-like code.
func TestSupervisorWithFakeReceiver(t *testing.T) {
	if os.Getenv("GUARD_FAKE_CHILD") == "1" {
		ln, err := net.Listen("tcp", os.Getenv("GUARD_FAKE_ADDR"))
		if err != nil {
			os.Exit(3)
		}
		for _, l := range upstreamLines() {
			fmt.Fprintln(os.Stderr, l)
		}
		fmt.Println(`{"level":"info","msg":"starting_server"}`)
		time.Sleep(600 * time.Millisecond)
		ln.Close()
		os.Exit(7)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	t.Setenv("GUARD_FAKE_CHILD", "1")
	t.Setenv("GUARD_FAKE_ADDR", addr)
	var out syncBuffer
	s := &Supervisor{Args: []string{os.Args[0], "-test.run=^TestSupervisorWithFakeReceiver$"}, Probe: addr, Filter: &Filter{Out: &out}}
	done := make(chan int, 1)
	go func() {
		code, _ := s.Run(context.Background())
		done <- code
	}()
	var live Liveness
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, httptest.NewRequest("GET", "/v1/liveness", nil))
		_ = json.Unmarshal(w.Body.Bytes(), &live)
		if w.Code == 200 && live.Listening {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !live.ChildRunning || !live.Listening || len(live.Generation) != 32 || live.StartedAt.IsZero() {
		t.Fatalf("liveness %+v", live)
	}
	if code := <-done; code != 7 {
		t.Fatalf("exit %d", code)
	}
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, httptest.NewRequest("GET", "/v1/liveness", nil))
	if w.Code != 503 {
		t.Fatalf("liveness after exit: %d", w.Code)
	}
	got := out.String()
	if strings.Contains(got, testvin.A) || strings.Contains(got, "203.0.113.7") || !strings.Contains(got, `"event":"starting_server"`) || !strings.Contains(got, `"exitCode":7`) {
		t.Fatalf("output:\n%s", got)
	}
}
