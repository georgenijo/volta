// Command volta-telemetry-consumer moves Fleet Telemetry records from the
// dedicated Redpanda queue into the volta_telemetry schema and serves a
// private, aggregate-only usage meter for commander.
//
// Configuration is environment only. Secrets and the VIN mapping are read
// from files and never logged; logs carry counts and error kinds only.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	stdlog "log"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/georgenijo/volta/ingestion/consumer"
	"github.com/georgenijo/volta/ingestion/guard"
	"github.com/georgenijo/volta/ingestion/meter"
	"github.com/georgenijo/volta/ingestion/normalize"
	"github.com/georgenijo/volta/ingestion/store"
	"github.com/georgenijo/volta/ingestion/vehicles"
	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck())
	}
	log := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	if err := run(log); err != nil {
		// Configuration errors are written by us and never contain secrets.
		log.Error("volta-telemetry-consumer stopped", "error", err.Error())
		os.Exit(1)
	}
}

func env(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

func envFloat(k string, def float64) (float64, error) {
	v := env(k, "")
	if v == "" {
		return def, nil
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return 0, errors.New(k + " must be a number")
	}
	return f, nil
}

func envDuration(k string, def time.Duration) (time.Duration, error) {
	v := env(k, "")
	if v == "" {
		return def, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil || d <= 0 {
		return 0, errors.New(k + " must be a positive duration")
	}
	return d, nil
}

func readSecretFile(k string) (string, error) {
	p := env(k, "")
	if p == "" {
		return "", errors.New(k + " is required")
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return "", errors.New(k + " is not readable")
	}
	s := strings.TrimSpace(string(b))
	if s == "" {
		return "", errors.New(k + " is empty")
	}
	return s, nil
}

func run(log *slog.Logger) error {
	ns := env("TELEMETRY_NAMESPACE", "tesla_telemetry")
	brokers := strings.Split(env("TELEMETRY_KAFKA_BROKERS", "redpanda:9092"), ",")
	group := env("TELEMETRY_GROUP", "volta-telemetry-consumer")
	reservation, err := envFloat("TELEMETRY_RESERVATION_USD", 3)
	if err != nil {
		return err
	}
	warn, err := envFloat("TELEMETRY_WARN_RATIO", 0.6)
	if err != nil {
		return err
	}
	stop, err := envFloat("TELEMETRY_STOP_RATIO", 0.8)
	if err != nil {
		return err
	}
	if reservation <= 0 || warn <= 0 || stop <= warn || stop > 1 {
		return errors.New("telemetry budget must satisfy reservation > 0 and 0 < warn < stop <= 1")
	}
	ret := store.DefaultRetention
	if ret.Raw, err = envDuration("TELEMETRY_RAW_RETENTION", ret.Raw); err != nil {
		return err
	}
	if ret.Rejections, err = envDuration("TELEMETRY_REJECTION_RETENTION", ret.Rejections); err != nil {
		return err
	}
	livenessURL := env("TELEMETRY_RECEIVER_LIVENESS_URL", "http://receiver:8450/v1/liveness")

	vehiclesJSON, err := readSecretFile("TELEMETRY_VEHICLES_FILE")
	if err != nil {
		return err
	}
	allow, err := vehicles.Parse(vehiclesJSON)
	if err != nil {
		return err
	}
	dsn, err := readSecretFile("TELEMETRY_DATABASE_URL_FILE")
	if err != nil {
		return err
	}
	statusSecret, err := readSecretFile("TELEMETRY_STATUS_SECRET_FILE")
	if err != nil {
		return err
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	pcfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return errors.New("TELEMETRY_DATABASE_URL_FILE is not a valid connection string")
	}
	pcfg.MaxConns = 3
	pool, err := pgxpool.NewWithConfig(ctx, pcfg)
	if err != nil {
		return errors.New("database pool could not be created")
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		return errors.New("database is not reachable")
	}

	st := store.New(pool)
	// Bind each numeric vehicle id permanently to a privacy-preserving VIN
	// digest before the queue is opened. A remapped allowlist fails startup
	// instead of blending the new car with the old car's telemetry history.
	if err := st.EnsureVehicleBindings(ctx, allow.Bindings()); err != nil {
		return errors.New("telemetry vehicle identity binding verification failed")
	}
	topics := []string{ns + "_V", ns + "_connectivity"}
	src, err := consumer.NewKafkaSource(consumer.KafkaConfig{Brokers: brokers, Group: group, Topics: topics})
	if err != nil {
		return err
	}
	defer src.Close()
	// The meter starts "unknown" and stays so until the handoff is proven.
	m := &meter.Meter{
		Counter: meter.CounterFunc(func(ctx context.Context, now time.Time) (meter.Usage, error) {
			u, err := st.MonthUsage(ctx, now)
			return meter.Usage{Signals: u.Signals, Uncountable: u.Uncountable, Undated: u.Undated}, err
		}),
		ReservationUSD: reservation, WarnRatio: warn, StopRatio: stop,
	}
	progress := &consumer.Progress{Reader: consumer.NewKafkaOffsets(src.Client, group), Checkpoints: st, Topics: topics}

	srv := &http.Server{
		Addr:              env("TELEMETRY_STATUS_ADDR", ":8449"),
		Handler:           m.Handler([]byte(statusSecret)),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      5 * time.Second,
		// net/http error lines can carry client addresses: drop them.
		ErrorLog: stdlog.New(io.Discard, "", 0),
	}
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("usage status server stopped", "error_kind", "listen")
			cancel()
		}
	}()
	defer func() {
		sctx, scancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer scancel()
		_ = srv.Shutdown(sctx)
	}()

	stats := &consumer.Stats{}
	c := &consumer.Consumer{Source: src, Sink: st, Norm: normalize.New(ns, allow), Log: log, Stats: stats}

	w := &watch{log: log, st: st, m: m, progress: progress, stats: stats, livenessURL: livenessURL,
		http: &http.Client{Timeout: 5 * time.Second}, health: store.Health{ConsumerStartedAt: time.Now().UTC()}}
	go w.loop(ctx, ret)

	log.Info("volta-telemetry-consumer started", "vehicles", allow.Len(), "reservation_usd", reservation)
	err = c.Run(ctx)
	if err != nil {
		return errors.New("consumer loop failed: " + kindOf(err))
	}
	return nil
}

// watch measures the handoff and receiver liveness, records them for
// readers (stream_health) and refreshes the meter.
type watch struct {
	log         *slog.Logger
	st          *store.Store
	m           *meter.Meter
	progress    *consumer.Progress
	stats       *consumer.Stats
	livenessURL string
	http        *http.Client
	health      store.Health
	lastState   string
}

func (w *watch) loop(ctx context.Context, ret store.Retention) {
	w.tick(ctx)
	every := time.NewTicker(15 * time.Second)
	report := time.NewTicker(time.Minute)
	prune := time.NewTicker(time.Hour)
	defer every.Stop()
	defer report.Stop()
	defer prune.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-every.C:
			w.tick(ctx)
		case <-report.C:
			snap := w.stats.Snapshot()
			w.log.Info("telemetry consumer stats", "accepted", snap.Accepted, "rejected", snap.Rejected, "batches", snap.Batches, "retries", snap.Retries)
		case now := <-prune.C:
			n, err := w.st.Prune(ctx, ret, now)
			if err != nil {
				w.log.Warn("telemetry retention failed", "error_kind", "store_error")
				continue
			}
			if n > 0 {
				w.log.Info("telemetry retention applied", "rows", n)
			}
		}
	}
}

func (w *watch) tick(ctx context.Context) {
	at := time.Now()
	if err := w.progress.Tick(ctx, at); err != nil {
		w.log.Warn("telemetry queue progress unavailable", "error_kind", "queue")
	}
	if l, ok := w.receiver(ctx); ok {
		w.health.ReceiverGeneration, w.health.ReceiverStartedAt, w.health.ReceiverSeenAt = l.Generation, l.StartedAt, time.Now().UTC()
	}
	ps := w.progress.State()
	w.health.CaughtUpAt, w.health.LagRecords = ps.AccountedThrough, ps.LagRecords
	now := time.Now()
	if err := w.st.UpdateHealth(ctx, w.health, now); err != nil {
		w.log.Warn("telemetry stream health not stored", "error_kind", "store_error")
	}
	s := w.m.Refresh(ctx, meter.Coverage{
		AccountedThrough: ps.AccountedThrough,
		Retrying:         w.stats.Snapshot().Retrying,
		ReceiverSeenAt:   w.health.ReceiverSeenAt,
	}, now)
	if s.State != w.lastState {
		w.log.Info("telemetry usage state", "state", s.State, "confidence", s.Confidence, "reasons", s.Reasons, "usd", s.USD, "reservation_usd", s.ReservationUSD)
		w.lastState = s.State
	}
}

// receiver polls the guard's liveness endpoint. Only a running, listening
// receiver counts as observed.
func (w *watch) receiver(ctx context.Context) (guard.Liveness, bool) {
	var l guard.Liveness
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, w.livenessURL, nil)
	if err != nil {
		return l, false
	}
	resp, err := w.http.Do(req)
	if err != nil {
		return l, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&l) != nil {
		return l, false
	}
	if !l.ChildRunning || !l.Listening || l.Generation == "" || l.StartedAt.IsZero() {
		return l, false
	}
	return l, true
}

func kindOf(err error) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	return "queue_or_store"
}

// healthcheck exits 0 only when the status endpoint answers with a fresh
// evaluation, i.e. the process serves and its watch loop is ticking. It
// says nothing about the budget state and prints nothing.
func healthcheck() int {
	secret, err := readSecretFile("TELEMETRY_STATUS_SECRET_FILE")
	if err != nil {
		return 1
	}
	addr := env("TELEMETRY_STATUS_ADDR", ":8449")
	if strings.HasPrefix(addr, ":") {
		addr = "127.0.0.1" + addr
	}
	req, err := http.NewRequest(http.MethodGet, "http://"+addr+"/v1/usage", nil)
	if err != nil {
		return 1
	}
	req.Header.Set("Authorization", "Bearer "+secret)
	resp, err := (&http.Client{Timeout: 3 * time.Second}).Do(req)
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	var s meter.Status
	if resp.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(resp.Body, 8192)).Decode(&s) != nil {
		return 1
	}
	for _, r := range s.Reasons {
		if r == meter.ReasonStarting || r == meter.ReasonMeterStale {
			return 1
		}
	}
	return 0
}
