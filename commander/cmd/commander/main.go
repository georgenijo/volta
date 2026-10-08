package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/georgenijo/volta/commander"
)

func main() {
	if err := run(); err != nil {
		slog.Error("commander stopped", "error", err)
		os.Exit(1)
	}
}
func run() error {
	c, err := commander.ConfigFromEnv()
	if err != nil {
		return err
	}
	if len(os.Args) == 2 && os.Args[1] == "register" {
		client, err := commander.HTTPClient(commander.Config{})
		if err != nil {
			return err
		}
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		if err = commander.RegisterPartner(ctx, c, client, os.Getenv("TESLA_PARTNER_DOMAIN")); err != nil {
			return err
		}
		slog.Info("partner domain registered and public key verified")
		return nil
	}
	store, err := commander.OpenStore(c.DataDir, c.EncryptionKey)
	if err != nil {
		return err
	}
	defer store.Close()
	auditFile, err := os.OpenFile(filepath.Join(c.DataDir, "audit.jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer auditFile.Close()
	audit := slog.New(slog.NewJSONHandler(io.MultiWriter(os.Stdout, auditFile), nil))
	client, err := commander.HTTPClient(c)
	if err != nil {
		return err
	}
	s, err := commander.NewService(c, store, client, audit)
	if err != nil {
		return err
	}
	private := &http.Server{Addr: c.Listen, Handler: s.PrivateHandler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 75 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192}
	public := &http.Server{Addr: c.CallbackListen, Handler: s.PublicHandler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 40 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192}
	servers := []*http.Server{private, public}
	if c.CollectorEnabled {
		servers = append(servers, &http.Server{Addr: c.CollectorListen, Handler: s.CollectorHandler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 40 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 8192})
	}
	errCh := make(chan error, len(servers))
	for _, server := range servers {
		go func() { errCh <- server.ListenAndServe() }()
	}
	audit.Info("commander_started", "mode", c.Mode, "commandsEnabled", c.Enabled, "collectorEnabled", c.CollectorEnabled)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	select {
	case err = <-errCh:
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 75*time.Second)
	defer cancel()
	// Drain every listener before releasing the process lock.
	for _, server := range servers {
		_ = server.Shutdown(shutdown)
	}
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
