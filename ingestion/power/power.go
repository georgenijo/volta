// Package power derives battery power from same-payload PackVoltage and
// PackCurrent once the PackCurrent sign is known.
//
// Tesla documents where PackCurrent is measured (the HV contactors) but not
// its sign. Volta's convention, matching TeslaMate and the app, is
// powerKw > 0 while discharging (driving) and < 0 while charging or during
// regen.
//
// The sign is never inferred from the car's own charging data. Positive
// charger input does not prove the direction of net pack current: the car
// can draw more than the charger supplies (cabin or battery heating while
// plugged in), so a 1.4 kW charger with +10 A at the pack is consistent with
// either sign. Power therefore stays nil until an operator records a sign
// from a verified live observation of net charging (see the PackCurrent sign
// live gate in docs/TELEMETRY_CAPTURE.md). The consumer has no write access
// to that calibration.
package power

import "math"

// Sign of PackCurrent while discharging.
type Sign int

const (
	Unverified        Sign = 0
	DischargePositive Sign = 1  // PackCurrent > 0 while discharging
	DischargeNegative Sign = -1 // PackCurrent < 0 while discharging
)

func (s Sign) String() string {
	switch s {
	case DischargePositive:
		return "discharge_positive"
	case DischargeNegative:
		return "discharge_negative"
	}
	return "unverified"
}

// ParseSign is the inverse of String.
func ParseSign(v string) Sign {
	switch v {
	case "discharge_positive":
		return DischargePositive
	case "discharge_negative":
		return DischargeNegative
	}
	return Unverified
}

// Kw converts same-payload voltage and current into Volta-convention power,
// or nil when the sign is not verified or the inputs are not plausible.
func Kw(voltageV, currentA float64, s Sign) *float64 {
	if s == Unverified || voltageV <= 0 || math.IsNaN(voltageV) || math.IsNaN(currentA) ||
		math.IsInf(voltageV, 0) || math.IsInf(currentA, 0) {
		return nil
	}
	kw := voltageV * currentA / 1000 * float64(s)
	return &kw
}
