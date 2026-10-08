package commander

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

type fleetReply struct {
	Response    json.RawMessage `json:"response"`
	Error       string          `json:"error"`
	Description string          `json:"error_description"`
}
type Fleet struct {
	c      Config
	client *http.Client
}

func (f *Fleet) request(ctx context.Context, method, endpoint, token string, params map[string]any) (int, fleetReply, *Result) {
	var body io.Reader
	if params != nil {
		b, _ := json.Marshal(params)
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, body)
	if err != nil {
		r := failure(502, "upstream_unavailable", "Cannot reach the command service.")
		return 0, fleetReply{}, &r
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	res, err := f.client.Do(req)
	if err != nil {
		var dial *net.OpError
		if errors.As(err, &dial) && dial.Op == "dial" {
			r := failure(503, "upstream_unavailable", "Command was not sent; the command service is unreachable.")
			return 0, fleetReply{}, &r
		}
		r := failure(504, "command_outcome_unknown", "Command outcome is unknown; check the vehicle before trying again.")
		return 0, fleetReply{}, &r
	}
	defer res.Body.Close()
	var reply fleetReply
	if err := json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&reply); err != nil {
		if res.StatusCode == 429 || res.StatusCode == 401 || res.StatusCode == 403 || res.StatusCode == 404 || res.StatusCode == 400 || res.StatusCode == 422 {
			return res.StatusCode, fleetReply{}, nil
		}
		r := failure(502, "command_outcome_unknown", "Invalid command response; check the vehicle before trying again.")
		return res.StatusCode, reply, &r
	}
	return res.StatusCode, reply, nil
}

func mapFleetError(status int, b fleetReply) *Result {
	var car struct {
		Result *bool  `json:"result"`
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(b.Response, &car)
	text := strings.ToLower(b.Error + " " + b.Description + " " + car.Reason)
	var r Result
	switch {
	case strings.Contains(text, "not been paired") || strings.Contains(text, "key not paired") || strings.Contains(text, "unknown key") || strings.Contains(text, "key_not_paired"):
		r = failure(409, "virtual_key_missing", "Pair Volta's virtual key in the Tesla app.")
	case strings.Contains(text, "offline or asleep") || strings.Contains(text, "vehicle asleep") || strings.Contains(text, "vehicle is asleep"):
		r = failure(409, "vehicle_asleep", "Vehicle is asleep or unavailable; waking may take a moment.")
	case strings.Contains(text, "vehicle is offline") || strings.Contains(text, "vehicle offline"):
		r = failure(409, "vehicle_offline", "Vehicle is offline; check its connectivity.")
	case status == 401:
		r = failure(409, "reauthorization_required", "Reconnect the Tesla account.")
	case status == 403:
		r = failure(403, "permission_denied", "Tesla denied this command; check account permissions and scopes.")
	case status == 404:
		r = failure(404, "vehicle_not_found", "Vehicle is unavailable to this Tesla account.")
	case status == 429:
		r = failure(429, "tesla_rate_limited", "Tesla rate limit reached; wait before trying again.")
		r.RetryAfter = 60
	case status >= 200 && status < 300 && b.Error == "" && car.Result != nil && *car.Result:
		return nil
	case status >= 200 && status < 300 && car.Result != nil && !*car.Result:
		r = failure(409, "command_rejected", "Vehicle rejected the command; check vehicle state.")
	case status == 400 || status == 422:
		r = failure(409, "command_rejected", "Tesla rejected the command parameters or vehicle state.")
	default:
		// Server errors and generic request timeouts cannot prove non-execution.
		r = failure(502, "command_outcome_unknown", "Command outcome is unknown; check the vehicle before trying again.")
	}
	return &r
}

func (f *Fleet) send(ctx context.Context, t *Tokens, vin string, c Command) Result {
	if c.Name == "wake_up" {
		return f.wake(ctx, t, vin)
	}
	endpoint := f.c.ProxyURL + "/api/1/vehicles/" + vin + "/command/" + c.Upstream
	status, b, err := f.request(ctx, "POST", endpoint, t.Access, c.Params)
	if err != nil {
		return *err
	}
	failure := mapFleetError(status, b)
	if failure == nil {
		return Result{Status: 200, OK: true}
	}
	if failure.Error.Code != "vehicle_asleep" {
		return *failure
	}
	// Retry ONLY after an explicit non-execution/asleep rejection, one wake,
	// and confirmed online state. No retry after a timeout or generic 5xx.
	if wake := f.wake(ctx, t, vin); wake.Error != nil {
		return wake
	}
	if ready := f.waitOnline(ctx, t, vin); ready != nil {
		return *ready
	}
	status, b, err = f.request(ctx, "POST", endpoint, t.Access, c.Params)
	if err != nil {
		return *err
	}
	if failure = mapFleetError(status, b); failure != nil {
		return *failure
	}
	return Result{Status: 200, OK: true}
}

func (f *Fleet) wake(ctx context.Context, t *Tokens, vin string) Result {
	status, b, err := f.request(ctx, "POST", t.FleetBase+"/api/1/vehicles/"+vin+"/wake_up", t.Access, map[string]any{})
	if err != nil {
		return *err
	}
	var car struct {
		State string `json:"state"`
	}
	if status == 200 && b.Error == "" && json.Unmarshal(b.Response, &car) == nil && (car.State == "online" || car.State == "asleep" || car.State == "offline") {
		return Result{Status: 200, OK: true}
	}
	if err := mapFleetError(status, b); err != nil {
		return *err
	}
	return Result{Status: 200, OK: true}
}

func (f *Fleet) waitOnline(ctx context.Context, t *Tokens, vin string) *Result {
	ctx, cancel := context.WithTimeout(ctx, f.c.WakeTimeout)
	defer cancel()
	lastState := "asleep"
	timedOut := func() *Result {
		if lastState == "offline" {
			r := failure(409, "vehicle_offline", "Vehicle remains offline after the wake window.")
			return &r
		}
		r := failure(409, "vehicle_asleep", "Vehicle did not wake in time; try later.")
		return &r
	}
	for {
		status, b, err := f.request(ctx, "GET", t.FleetBase+"/api/1/vehicles/"+vin, t.Access, nil)
		if err != nil {
			if ctx.Err() != nil {
				return timedOut()
			}
			r := failure(409, "vehicle_asleep", "Vehicle did not become reachable within the wake window.")
			return &r
		}
		var car struct {
			State string `json:"state"`
		}
		if status != 200 || b.Error != "" || json.Unmarshal(b.Response, &car) != nil {
			if status == 429 {
				return mapFleetError(status, b)
			}
			r := failure(503, "upstream_unavailable", "Cannot confirm vehicle wake state.")
			return &r
		}
		if car.State == "online" {
			return nil
		}
		if car.State != "asleep" && car.State != "offline" {
			r := failure(409, "vehicle_unavailable", "Vehicle cannot accept commands in its current state.")
			return &r
		}
		lastState = car.State
		timer := time.NewTimer(f.c.WakeInterval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return timedOut()
		case <-timer.C:
		}
	}
}
