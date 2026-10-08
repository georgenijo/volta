package guard

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// Liveness is the receiver state the consumer polls. It carries no
// identifiers other than a random per-start generation.
type Liveness struct {
	Generation   string    `json:"generation"`
	StartedAt    time.Time `json:"startedAt"`
	ChildRunning bool      `json:"childRunning"`
	Listening    bool      `json:"listening"`
}

// Supervisor runs the receiver as a child and serves liveness.
type Supervisor struct {
	Args   []string // child argv
	Probe  string   // receiver TLS listener, e.g. 127.0.0.1:8448
	Filter *Filter
	// FlushEvery reports unrecognized/suppressed counts.
	FlushEvery time.Duration

	mu         sync.Mutex
	generation string
	startedAt  time.Time
	running    atomic.Bool
}

// NewGeneration returns a random generation id.
func NewGeneration() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// State returns liveness now.
func (s *Supervisor) State(ctx context.Context) Liveness {
	s.mu.Lock()
	l := Liveness{Generation: s.generation, StartedAt: s.startedAt, ChildRunning: s.running.Load()}
	s.mu.Unlock()
	if l.ChildRunning && s.Probe != "" {
		d := net.Dialer{Timeout: time.Second}
		if c, err := d.DialContext(ctx, "tcp", s.Probe); err == nil {
			_ = c.Close()
			l.Listening = true
		}
	}
	return l
}

// Handler serves GET /v1/liveness.
func (s *Supervisor) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/liveness", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		l := s.State(r.Context())
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		if !l.ChildRunning || !l.Listening {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
		_ = json.NewEncoder(w).Encode(l)
	})
	return mux
}

// Run starts the child, filters its output and waits for it. It returns
// the child's exit code. A signal to the guard is forwarded to the child.
func (s *Supervisor) Run(ctx context.Context) (int, error) {
	if len(s.Args) == 0 {
		return 2, errors.New("no receiver command")
	}
	s.mu.Lock()
	s.generation = NewGeneration()
	s.startedAt = time.Now().UTC()
	s.mu.Unlock()
	cmd := exec.Command(s.Args[0], s.Args[1:]...)
	cmd.Env = os.Environ()
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return 2, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return 2, err
	}
	if err := cmd.Start(); err != nil {
		return 2, errors.New("receiver could not be started")
	}
	s.running.Store(true)
	s.Filter.Emit(Event{Level: "info", Event: "guard_child_started"})

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); s.Filter.Consume(stdout) }()
	go func() { defer wg.Done(); s.Filter.Consume(stderr) }()

	sigs := make(chan os.Signal, 4)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer signal.Stop(sigs)
	every := s.FlushEvery
	if every <= 0 {
		every = 10 * time.Second
	}
	tick := time.NewTicker(every)
	defer tick.Stop()
	done := make(chan struct{})
	stop := ctx.Done()
	go func() {
		for {
			select {
			case sig := <-sigs:
				_ = cmd.Process.Signal(sig)
			case <-stop:
				_ = cmd.Process.Signal(syscall.SIGTERM)
				stop = nil
			case <-tick.C:
				s.Filter.Flush()
			case <-done:
				return
			}
		}
	}()
	wg.Wait() // pipes close when the child exits
	werr := cmd.Wait()
	s.running.Store(false)
	close(done)
	s.Filter.Flush()
	code := 0
	if werr != nil {
		var ee *exec.ExitError
		if errors.As(werr, &ee) {
			code = ee.ExitCode()
			if code < 0 {
				code = 128 + int(syscall.SIGKILL)
				if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
					code = 128 + int(ws.Signal())
				}
			}
		} else {
			code = 1
		}
	}
	s.Filter.Emit(Event{Level: "warning", Event: "guard_child_exited", Code: &code})
	return code, nil
}
