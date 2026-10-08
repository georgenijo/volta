// Package vehicles holds the explicit VIN -> Volta vehicle id binding.
//
// The mapping uses the same shape as commander's COMMANDER_VEHICLES
// ({"<vehicle id>":"<full VIN>"}). There is no fuzzy matching: a VIN is
// accepted only when it is listed exactly. The VIN itself is never stored,
// logged or returned; everything downstream is keyed by the vehicle id.
package vehicles

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"
)

const bindingDomain = "volta-telemetry-vin-binding-v1\x00"

// Allowlist maps full VINs to Volta vehicle ids.
type Allowlist struct {
	byVIN map[string]int
}

// ErrUnregistered is returned for any VIN not on the list. It never contains
// the VIN.
var ErrUnregistered = errors.New("vehicle not registered for telemetry")

// Parse reads {"<vehicle id>":"<VIN>"}. Ids must be canonical positive
// integers ("1", never "01", "+1" or " 1"), every key and every VIN must
// appear once, and VINs must be well formed, so a typo can neither
// cross-bind two cars to one id nor silently drop an entry. Any violation
// fails the whole mapping; there is no partial load.
func Parse(raw string) (*Allowlist, error) {
	if raw == "" {
		return nil, errors.New("telemetry vehicle mapping is empty")
	}
	notObject := errors.New("telemetry vehicle mapping is not a JSON object of id -> VIN")
	dec := json.NewDecoder(strings.NewReader(raw))
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		return nil, notObject
	}
	a := &Allowlist{byVIN: map[string]int{}}
	ids := map[int]bool{}
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return nil, notObject
		}
		idText, _ := tok.(string)
		if !canonicalID.MatchString(idText) {
			return nil, fmt.Errorf("telemetry vehicle id %q is not a canonical positive integer", redactID(idText))
		}
		id, err := strconv.Atoi(idText)
		if err != nil {
			return nil, fmt.Errorf("telemetry vehicle id %q is out of range", redactID(idText))
		}
		tok, err = dec.Token()
		if err != nil {
			return nil, notObject
		}
		vin, isText := tok.(string)
		if !isText {
			return nil, notObject
		}
		if ids[id] {
			return nil, fmt.Errorf("telemetry vehicle id %d appears more than once", id)
		}
		if !ValidVIN(vin) {
			return nil, fmt.Errorf("telemetry vehicle %d has a malformed VIN", id)
		}
		if _, dup := a.byVIN[vin]; dup {
			return nil, fmt.Errorf("telemetry vehicle %d repeats a VIN already mapped", id)
		}
		ids[id] = true
		a.byVIN[vin] = id
	}
	if tok, err := dec.Token(); err != nil || tok != json.Delim('}') {
		return nil, notObject
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, notObject
	}
	if len(a.byVIN) == 0 {
		return nil, errors.New("telemetry vehicle mapping has no vehicles")
	}
	return a, nil
}

var canonicalID = regexp.MustCompile(`^[1-9][0-9]{0,8}$`)

// redactID keeps error text free of anything VIN-shaped: an id key long
// enough to be a VIN is not echoed.
func redactID(s string) string {
	if len(s) > 9 {
		return "<redacted>"
	}
	return s
}

// Lookup returns the vehicle id for an exact VIN match.
func (a *Allowlist) Lookup(vin string) (int, error) {
	if id, ok := a.byVIN[vin]; ok {
		return id, nil
	}
	return 0, ErrUnregistered
}

// Len reports how many vehicles are registered.
func (a *Allowlist) Len() int { return len(a.byVIN) }

// Bindings returns the permanent vehicle-id -> VIN digest bindings that the
// store must verify before consuming any records. The digest is deliberately
// domain separated and the VIN itself never leaves this package. A binding
// may be added, but changing either side is rejected by the database so an
// allowlist edit cannot mix two cars' histories under one vehicle id.
func (a *Allowlist) Bindings() map[int]string {
	out := make(map[int]string, len(a.byVIN))
	for vin, id := range a.byVIN {
		sum := sha256.Sum256([]byte(bindingDomain + vin))
		out[id] = hex.EncodeToString(sum[:])
	}
	return out
}

// ValidVIN checks the ISO 3779 shape: 17 characters, digits and capital
// letters except I, O and Q.
func ValidVIN(v string) bool {
	if len(v) != 17 {
		return false
	}
	for _, r := range v {
		switch {
		case r >= '0' && r <= '9':
		case r >= 'A' && r <= 'Z' && r != 'I' && r != 'O' && r != 'Q':
		default:
			return false
		}
	}
	return true
}
