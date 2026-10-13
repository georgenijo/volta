package commander

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"slices"
	"strings"
)

// These are the operations implemented by the pinned Tesla signing proxy.
// remote_boombox remains ErrCommandNotImplemented even in upstream main; do
// not advertise Locate or replace its quiet ping with a horn command.
var supportedCommands = []string{
	"lock", "unlock", "climate_on", "climate_off", "set_temps",
	"charge_start", "charge_stop", "set_charge_limit",
	"open_charge_port", "close_charge_port", "actuate_trunk", "window_control",
	"honk", "flash", "sentry_on", "sentry_off", "trigger_homelink", "wake_up",
	"seat_heater", "steering_wheel_heat", "defrost",
}

type commandCapabilities struct {
	Available bool     `json:"available"`
	Reason    *string  `json:"reason"`
	Commands  []string `json:"commands"`
}

func (s *Service) handleCommandCapabilities(w http.ResponseWriter, r *http.Request) {
	v := commandCapabilities{Commands: slices.Clone(supportedCommands)}
	reason := ""
	t := s.store.tokens()
	switch {
	case !s.c.Enabled:
		reason = "commands_unavailable"
	case s.c.Mode != "live":
		reason = "stub_mode"
	case s.c.Vehicles[r.PathValue("id")] == "":
		reason = "vehicle_not_found"
	case t == nil:
		reason = "authorization_required"
	case t.ReauthRequired:
		reason = "reauthorization_required"
	case !hasCommandScopes(t):
		reason = "command_scope_required"
	default:
		v.Available = true
	}
	if reason != "" {
		v.Reason = &reason
		v.Commands = []string{}
	}
	// This endpoint makes no paid Fleet reads or wakes. It describes local
	// command readiness, not proof of pairing, hardware support, or execution.
	writeJSON(w, http.StatusOK, v)
}

// Scope claims are a readiness hint from credentials received directly from
// Tesla over TLS and retained in the encrypted store, never client input. This
// does not validate a bearer token or authorize an inbound request: Tesla and
// the signing proxy remain authoritative and can still refuse the command.
func tokenScopeClaims(access string) ([]string, bool) {
	parts := strings.Split(access, ".")
	if len(parts) != 3 || len(parts[1]) > 64<<10 {
		return nil, false
	}
	b, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, false
	}
	var claims struct {
		SCP   json.RawMessage `json:"scp"`
		Scope json.RawMessage `json:"scope"`
	}
	if json.Unmarshal(b, &claims) != nil {
		return nil, false
	}
	for _, raw := range []json.RawMessage{claims.SCP, claims.Scope} {
		if len(raw) == 0 {
			continue
		}
		var list []string
		if json.Unmarshal(raw, &list) == nil {
			return list, true
		}
		var spaceSeparated string
		if json.Unmarshal(raw, &spaceSeparated) == nil {
			return strings.Fields(spaceSeparated), true
		}
		return nil, true // present but malformed: fail closed
	}
	return nil, false
}

func tokenHasScopeClaim(access string) bool {
	_, present := tokenScopeClaims(access)
	return present
}

func hasCommandScopes(t *Tokens) bool {
	if t == nil {
		return false
	}
	scopes, present := tokenScopeClaims(t.Access)
	if !present {
		scopes = strings.Fields(t.Scope)
	}
	return slices.Contains(scopes, "vehicle_cmds") && slices.Contains(scopes, "vehicle_charging_cmds")
}

// Used only to bind an in-place consent upgrade to the same Tesla account.
func tokenSubject(access string) string {
	parts := strings.Split(access, ".")
	if len(parts) != 3 || len(parts[1]) > 64<<10 {
		return ""
	}
	b, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return ""
	}
	var claims struct {
		Subject string `json:"sub"`
	}
	if json.Unmarshal(b, &claims) != nil || len(claims.Subject) == 0 || len(claims.Subject) > 1024 {
		return ""
	}
	return claims.Subject
}
