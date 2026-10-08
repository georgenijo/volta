// Package guard is the reviewed output boundary around the official Fleet
// Telemetry receiver. The receiver (v0.9.5) logs VINs and client addresses
// on several error paths (unexpected_sender_id, unauthorized_sender_id,
// unexpected_record, socket_err, connectivity_*_error, request_start /
// request_end remote_ip, socket_connected requestInfo, net/http server
// errors written through its logger, kafka_err). Its
// SUPPRESS_TLS_HANDSHAKE_ERROR_LOGGING switch drops only lines whose message
// starts with "http: TLS handshake error from", so it cannot close those.
//
// The guard runs the unmodified pinned binary as its child and is the only
// writer to the container's stdout/stderr. Every child line is parsed, and
// only a fixed event code from Allowed is emitted: never the child's text,
// fields, error strings or values. The emitted code string comes from this
// package's table, not from the input. Anything unparseable or not
// allowlisted is counted and reported only as a count. Output is rate
// bounded; excess is counted.
package guard

import (
	"bufio"
	"encoding/json"
	"io"
	"sync"
	"time"
)

// MaxLine bounds one child log line. Longer lines are discarded and counted
// as unrecognized.
const MaxLine = 64 << 10

// Allowed maps every receiver log message the guard may report to the code
// it emits. Keys are the logrus "msg" values in fleet-telemetry v0.9.5
// (logger.ActivityLog / ErrorLog / Log call sites). Only the code is
// emitted; all fields of the line are dropped.
var Allowed = map[string]string{
	// lifecycle
	"starting_server":                        "starting_server",
	"stopped_server":                         "stopped_server",
	"attempting_to_close":                    "attempting_to_close",
	"producer_close_error":                   "producer_close_error",
	"kafka_registered":                       "kafka_registered",
	"status_server_configured":               "status_server_configured",
	"config_skipping_empty_metrics_provider": "config_skipping_empty_metrics_provider",
	"invalid_level":                          "invalid_level",
	"custom_ca_file_appened":                 "custom_ca_file_appended",
	"status":                                 "status_server_error",
	"metrics_server_err":                     "metrics_server_error",
	// connections (fields carry remote_ip, requestInfo, device ids)
	"request_start":       "request_start",
	"request_end":         "request_end",
	"socket_connected":    "socket_connected",
	"socket_disconnected": "socket_disconnected",
	// stream errors (fields carry VINs, sender ids, txids)
	"extract_sender_id_err":              "extract_sender_id_err",
	"connectivity_registeration_error":   "connectivity_registration_error",
	"connectivity_deregisteration_error": "connectivity_deregistration_error",
	"websocket_promotion_error":          "websocket_promotion_error",
	"websocket_close_err":                "websocket_close_error",
	"rate_limit_exceeded":                "rate_limit_exceeded",
	"unauthorized_sender_id":             "unauthorized_sender_id",
	"unknown_message_type_error":         "unknown_message_type_error",
	"unexpected_record":                  "unexpected_record",
	"socket_err":                         "socket_error",
	"unexpected_sender_id":               "unexpected_sender_id",
	"set_delivered_at_bytes_error":       "set_delivered_at_bytes_error",
	"record_RawBytes_blank":              "record_raw_bytes_blank",
	// queue
	"kafka_err":           "kafka_error",
	"kafka_event_ignored": "kafka_event_ignored",
}

// Guard-generated codes.
const (
	CodeUnrecognized = "receiver_log_unrecognized"
	CodeSuppressed   = "receiver_log_suppressed"
	CodePanic        = "receiver_panic"
)

var levels = map[string]string{
	"debug": "debug", "info": "info", "warning": "warning", "warn": "warning",
	"error": "error", "fatal": "fatal", "panic": "panic",
}

// Event is one emitted line. It has no free-text field.
type Event struct {
	Time   time.Time `json:"time"`
	Level  string    `json:"level"`
	Source string    `json:"source"`
	Event  string    `json:"event"`
	Count  int64     `json:"count,omitempty"`
	Code   *int      `json:"exitCode,omitempty"`
}

// Classify maps one child line to an event code and level. ok is false for
// anything not allowlisted.
func Classify(line []byte) (code, level string, ok bool) {
	if len(line) >= 6 && string(line[:6]) == "panic:" {
		return CodePanic, "panic", true
	}
	var m struct {
		Msg   string `json:"msg"`
		Level string `json:"level"`
	}
	if json.Unmarshal(line, &m) != nil {
		return "", "", false
	}
	code, ok = Allowed[m.Msg]
	if !ok {
		return "", "", false
	}
	level, lok := levels[m.Level]
	if !lok {
		level = "unknown"
	}
	return code, level, true
}

// Filter writes events for child lines.
type Filter struct {
	Out io.Writer
	// PerSecond bounds emitted events per second (excluding summaries).
	PerSecond int
	Now       func() time.Time

	mu           sync.Mutex
	window       time.Time
	inWindow     int
	unrecognized int64
	suppressed   int64
}

func (f *Filter) now() time.Time {
	if f.Now != nil {
		return f.Now()
	}
	return time.Now()
}

// Line handles one complete child line.
func (f *Filter) Line(line []byte) {
	code, level, ok := Classify(line)
	f.mu.Lock()
	defer f.mu.Unlock()
	if !ok {
		f.unrecognized++
		return
	}
	now := f.now()
	if s := now.Truncate(time.Second); !s.Equal(f.window) {
		f.window, f.inWindow = s, 0
	}
	limit := f.PerSecond
	if limit <= 0 {
		limit = 20
	}
	if f.inWindow >= limit {
		f.suppressed++
		return
	}
	f.inWindow++
	f.write(Event{Time: now.UTC(), Level: level, Source: "receiver", Event: code})
}

// Emit writes a guard event.
func (f *Filter) Emit(e Event) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if e.Time.IsZero() {
		e.Time = f.now().UTC()
	}
	e.Source = "guard"
	f.write(e)
}

// Flush reports and resets the unrecognized and suppressed counts.
func (f *Filter) Flush() {
	f.mu.Lock()
	defer f.mu.Unlock()
	now := f.now().UTC()
	if f.unrecognized > 0 {
		f.write(Event{Time: now, Level: "warning", Source: "guard", Event: CodeUnrecognized, Count: f.unrecognized})
		f.unrecognized = 0
	}
	if f.suppressed > 0 {
		f.write(Event{Time: now, Level: "warning", Source: "guard", Event: CodeSuppressed, Count: f.suppressed})
		f.suppressed = 0
	}
}

func (f *Filter) write(e Event) {
	b, err := json.Marshal(e)
	if err != nil {
		return
	}
	_, _ = f.Out.Write(append(b, '\n'))
}

// Consume reads child output until EOF, one bounded line at a time.
func (f *Filter) Consume(r io.Reader) {
	br := bufio.NewReaderSize(r, 4096)
	var buf []byte
	tooLong := false
	for {
		chunk, isPrefix, err := br.ReadLine()
		if len(chunk) > 0 || (!isPrefix && err == nil) {
			if !tooLong && len(buf)+len(chunk) <= MaxLine {
				buf = append(buf, chunk...)
			} else {
				tooLong, buf = true, buf[:0]
			}
			if !isPrefix {
				if tooLong {
					f.mu.Lock()
					f.unrecognized++
					f.mu.Unlock()
				} else if len(buf) > 0 {
					f.Line(buf)
				}
				buf, tooLong = buf[:0], false
			}
		}
		if err != nil {
			if len(buf) > 0 || tooLong {
				f.mu.Lock()
				f.unrecognized++ // truncated final line
				f.mu.Unlock()
			}
			return
		}
	}
}
