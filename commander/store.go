package commander

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

type Tokens struct {
	Access    string    `json:"access"`
	Refresh   string    `json:"refresh"`
	Expires   time.Time `json:"expires"`
	FleetBase string    `json:"fleetBase"`
	// Set when Tesla rejects the refresh token; nothing retries until relinked.
	ReauthRequired bool `json:"reauthRequired,omitempty"`
	// LinkID is random per completed sign-in and survives token refreshes.
	// Tesla's token reply does not identify the account, so stored history is
	// namespaced by link: a relink, possibly to another account, starts fresh.
	LinkID string `json:"linkId,omitempty"`
}

// A pending sign-in survives restarts so a device can finish after the app
// was backgrounded. Only the state's hash is kept; the verifier never leaves.
type PendingLink struct {
	StateHash string    `json:"stateHash"`
	Verifier  string    `json:"verifier"`
	Device    string    `json:"device"`
	Expires   time.Time `json:"expires"`
}

// The consumed state's outcome lets the same device retry completion after a
// dropped response without a second code exchange.
type LinkOutcome struct {
	StateHash string    `json:"stateHash"`
	Device    string    `json:"device"`
	Status    int       `json:"status"`
	Result    Result    `json:"result"`
	Expires   time.Time `json:"expires"`
}

// Estimated Fleet API spend for the current UTC month.
type Usage struct {
	Month string  `json:"month"`
	Calls int     `json:"calls"`
	USD   float64 `json:"usd"`
}

// Charging-history calls for the current UTC day, plus local gates that stop
// repeated billable calls Tesla has already refused.
type HistoryUsage struct {
	Day   string `json:"day"`
	Calls int    `json:"calls"`
	// Calls in the UTC month of Day.
	Month int `json:"monthCalls"`
	// Tesla asked to back off (429 Retry-After) or refused billing until then.
	BlockedUntil time.Time `json:"blockedUntil,omitzero"`
	// The link namespace Tesla answered 403 for; cleared by relinking.
	ScopeMissing string `json:"scopeMissing,omitempty"`
	// Set durably with each call's reservation and cleared once its outcome
	// is recorded. One left behind (a crash or a failed ledger write) means a
	// reply, and any Retry-After in it, may be lost.
	Pending time.Time `json:"pendingSince,omitzero"`
}
type Receipt struct {
	Fingerprint string    `json:"fingerprint"`
	Created     time.Time `json:"created"`
	Result      *Result   `json:"result,omitempty"`
	HTTPStatus  int       `json:"httpStatus,omitempty"`
	RetryAfter  int       `json:"retryAfter,omitempty"`
}
type diskState struct {
	Version  int                    `json:"version"`
	Tokens   *Tokens                `json:"tokens,omitempty"`
	Receipts map[string]Receipt     `json:"receipts"`
	Rate     map[string][]time.Time `json:"rate"`
	Link     *PendingLink           `json:"link,omitempty"`
	Outcome  *LinkOutcome           `json:"linkOutcome,omitempty"`
	Usage    *Usage                 `json:"usage,omitempty"`
	History  *HistoryUsage          `json:"history,omitempty"`
}
type Store struct {
	mu    sync.Mutex
	path  string
	aead  cipher.AEAD
	state diskState
	lock  *os.File
}

var stateAAD = []byte("volta-commander-state-v1")

// A process lock protects single-use refresh tokens and command receipts. A
// second replica fails closed rather than issuing duplicate commands.
func OpenStore(dir string, key []byte) (*Store, error) {
	block, err := aes.NewCipher(key)
	if err != nil || len(key) != 32 {
		return nil, errors.New("store requires an AES-256 key")
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	if err = os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	if err = os.Chmod(dir, 0700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(dir, "state.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, errors.New("commander state already in use")
	}
	s := &Store{path: filepath.Join(dir, "state.enc"), aead: aead, lock: f, state: diskState{Version: 1, Receipts: map[string]Receipt{}, Rate: map[string][]time.Time{}}}
	data, err := os.ReadFile(s.path)
	if os.IsNotExist(err) {
		return s, nil
	}
	if err != nil {
		s.Close()
		return nil, err
	}
	if len(data) < aead.NonceSize() {
		s.Close()
		return nil, errors.New("invalid encrypted state")
	}
	plain, err := aead.Open(nil, data[:aead.NonceSize()], data[aead.NonceSize():], stateAAD)
	if err != nil {
		s.Close()
		return nil, errors.New("cannot decrypt state; check encryption key and file integrity")
	}
	if err = json.Unmarshal(plain, &s.state); err != nil || s.state.Version != 1 || s.state.Receipts == nil || s.state.Rate == nil {
		s.Close()
		return nil, errors.New("unsupported state format")
	}
	return s, nil
}

func (s *Store) Close() error { return s.lock.Close() }
func (s *Store) tokens() *Tokens {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state.Tokens == nil {
		return nil
	}
	t := *s.state.Tokens
	return &t
}
func (s *Store) saveTokens(t *Tokens) error {
	var owned *Tokens
	if t != nil {
		copy := *t
		owned = &copy
	}
	return s.update(func(d *diskState) { d.Tokens = owned })
}
func (s *Store) snapshot() diskState { s.mu.Lock(); defer s.mu.Unlock(); return cloneState(s.state) }
func cloneState(d diskState) diskState {
	b, _ := json.Marshal(d)
	var copy diskState
	_ = json.Unmarshal(b, &copy)
	return copy
}

// Write temp -> fsync -> rename -> fsync directory before considering a token
// rotation or an idempotency reservation committed.
func (s *Store) update(fn func(*diskState)) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := cloneState(s.state)
	fn(&next)
	plain, err := json.Marshal(next)
	if err != nil {
		return err
	}
	nonce := make([]byte, s.aead.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return err
	}
	data := s.aead.Seal(nonce, nonce, plain, stateAAD)
	f, err := os.CreateTemp(filepath.Dir(s.path), ".state-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(f.Name(), s.path); err != nil {
		return err
	}
	// Rename has happened: keep memory consistent even if directory fsync fails.
	s.state = cloneState(next)
	dir, err := os.Open(filepath.Dir(s.path))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
