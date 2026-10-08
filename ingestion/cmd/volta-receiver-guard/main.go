// Command volta-receiver-guard runs the official Fleet Telemetry receiver
// as its child and is the container's only log writer (see package guard).
//
//	volta-receiver-guard [flags] -- /fleet-telemetry -config ...
//	volta-receiver-guard healthcheck
//
// It serves GET /v1/liveness on -liveness (internal network only) and exits
// with the child's exit code, so the container restarts with a new
// generation whenever the receiver dies.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/georgenijo/volta/ingestion/guard"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck(env("GUARD_LIVENESS_URL", "http://127.0.0.1:8450/v1/liveness")))
	}
	fs := flag.NewFlagSet("volta-receiver-guard", flag.ContinueOnError)
	liveness := fs.String("liveness", ":8450", "liveness listen address")
	probe := fs.String("probe", "127.0.0.1:8448", "receiver listener to probe")
	perSecond := fs.Int("events-per-second", 20, "emitted receiver events per second")
	f := &guard.Filter{Out: os.Stdout}
	if err := fs.Parse(os.Args[1:]); err != nil {
		f.Emit(guard.Event{Level: "error", Event: "guard_usage_error"})
		os.Exit(2)
	}
	f.PerSecond = *perSecond
	s := &guard.Supervisor{Args: fs.Args(), Probe: *probe, Filter: f}

	srv := &http.Server{Addr: *liveness, Handler: s.Handler(), ReadHeaderTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second}
	// net/http's own error lines can carry client addresses: drop them.
	srv.ErrorLog = log.New(io.Discard, "", 0)
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			f.Emit(guard.Event{Level: "error", Event: "guard_liveness_listen_error"})
		}
	}()
	code, err := s.Run(context.Background())
	if err != nil {
		f.Emit(guard.Event{Level: "error", Event: "guard_start_error"})
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	_ = srv.Shutdown(ctx)
	cancel()
	os.Exit(code)
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// healthcheck exits 0 only when the receiver child runs and listens.
func healthcheck(url string) int {
	c := http.Client{Timeout: 3 * time.Second}
	resp, err := c.Get(url)
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	var l guard.Liveness
	if resp.StatusCode != http.StatusOK || json.NewDecoder(resp.Body).Decode(&l) != nil || !l.ChildRunning || !l.Listening {
		return 1
	}
	return 0
}
