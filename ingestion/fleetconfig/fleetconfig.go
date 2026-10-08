// Package fleetconfig builds the fleet_telemetry_config request body Volta
// would send (through the vehicle-command proxy, which signs it) and bounds
// its streaming cost. It never sends anything.
//
// Billing facts used (developer.tesla.com/docs/fleet-api/fleet-telemetry):
// 150,000 streaming signals per USD; a field is sent only when its interval
// has elapsed AND its value changed; include_fields (client 1.3.0+) are sent
// with their parent every time, changed or not. At the account billing cap
// Tesla suspends usage and removes telemetry configurations, which would
// also stop commander polling, so the budget below stays well under a
// reserved share of the existing $10/month cap and the consumer meters real
// signals for a stop threshold.
package fleetconfig

import (
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/georgenijo/volta/ingestion/fields"
)

// SignalsPerUSD is Tesla's published streaming price.
const SignalsPerUSD = 150000

// FieldConfig is one entry of config.fields.
type FieldConfig struct {
	IntervalSeconds int      `json:"interval_seconds"`
	MinimumDelta    *float64 `json:"minimum_delta,omitempty"`
	IncludeFields   []string `json:"include_fields,omitempty"`
}

// Config is the signed configuration body.
type Config struct {
	Hostname       string                 `json:"hostname"`
	Port           int                    `json:"port"`
	CA             string                 `json:"ca"`
	Fields         map[string]FieldConfig `json:"fields"`
	Exp            int64                  `json:"exp"`
	DeliveryPolicy string                 `json:"delivery_policy"`
}

// Request is the fleet_telemetry_config create body.
type Request struct {
	VINs   []string `json:"vins"`
	Config Config   `json:"config"`
}

// Planned is a profile entry plus the budget assumption for it.
type Planned struct {
	Name string
	FieldConfig
	// ChangesPerHour is the planning bound for discrete fields (gear, locks,
	// charge state). Zero means continuous: assume it changes every interval.
	ChangesPerHour float64
}

// Hours is the monthly exposure model per field class.
type Hours struct {
	Drive, ACCharge, DCCharge, Awake float64
	// Connections bounds new streaming connections per month. Each sends a
	// snapshot of every top-level field once.
	Connections float64
}

// DefaultHours models George's requested month: 30 driving hours, ordinary
// home charging plus several DC sessions, and generous awake/reconnect time.
var DefaultHours = Hours{Drive: 30, ACCharge: 120, DCCharge: 4, Awake: 300, Connections: 600}

func f(v float64) *float64 { return &v }

// Profile is Volta's normal streaming profile. A Location parent every two
// seconds carries the six values that must be co-timed for trip analytics.
// include_fields requires Fleet Telemetry client 1.3.0 or newer; commander
// refuses to install this profile on older clients.
func Profile() []Planned {
	return []Planned{
		{Name: "Location", FieldConfig: FieldConfig{IntervalSeconds: 2, MinimumDelta: f(3), IncludeFields: []string{"VehicleSpeed", "GpsHeading", "PackVoltage", "PackCurrent", "LongitudinalAcceleration", "LateralAcceleration"}}},
		{Name: "Gear", FieldConfig: FieldConfig{IntervalSeconds: 1}, ChangesPerHour: 12},
		{Name: "Odometer", FieldConfig: FieldConfig{IntervalSeconds: 30}},
		{Name: "LifetimeEnergyUsed", FieldConfig: FieldConfig{IntervalSeconds: 60}},
		{Name: "LifetimeEnergyGainedRegen", FieldConfig: FieldConfig{IntervalSeconds: 60}},

		{Name: "Soc", FieldConfig: FieldConfig{IntervalSeconds: 30}},
		{Name: "BatteryLevel", FieldConfig: FieldConfig{IntervalSeconds: 30}},
		{Name: "EnergyRemaining", FieldConfig: FieldConfig{IntervalSeconds: 30}},
		{Name: "RatedRange", FieldConfig: FieldConfig{IntervalSeconds: 60}},
		{Name: "EstBatteryRange", FieldConfig: FieldConfig{IntervalSeconds: 60}},
		{Name: "IdealBatteryRange", FieldConfig: FieldConfig{IntervalSeconds: 60}},
		{Name: "ModuleTempMin", FieldConfig: FieldConfig{IntervalSeconds: 60, MinimumDelta: f(0.5)}},
		{Name: "ModuleTempMax", FieldConfig: FieldConfig{IntervalSeconds: 60, MinimumDelta: f(0.5)}},
		{Name: "InsideTemp", FieldConfig: FieldConfig{IntervalSeconds: 60, MinimumDelta: f(0.5)}},
		{Name: "OutsideTemp", FieldConfig: FieldConfig{IntervalSeconds: 60, MinimumDelta: f(0.5)}},

		{Name: "DetailedChargeState", FieldConfig: FieldConfig{IntervalSeconds: 5}, ChangesPerHour: 1},
		{Name: "ACChargingPower", FieldConfig: FieldConfig{IntervalSeconds: 60, IncludeFields: []string{"PackVoltage", "PackCurrent"}}},
		{Name: "DCChargingPower", FieldConfig: FieldConfig{IntervalSeconds: 10, IncludeFields: []string{"PackVoltage", "PackCurrent"}}},
		{Name: "ACChargingEnergyIn", FieldConfig: FieldConfig{IntervalSeconds: 60}},
		{Name: "DCChargingEnergyIn", FieldConfig: FieldConfig{IntervalSeconds: 60}},
		{Name: "ChargerVoltage", FieldConfig: FieldConfig{IntervalSeconds: 60, MinimumDelta: f(2)}},
		{Name: "ChargeAmps", FieldConfig: FieldConfig{IntervalSeconds: 60}},
		{Name: "TimeToFullCharge", FieldConfig: FieldConfig{IntervalSeconds: 60}},
		{Name: "ChargeLimitSoc", FieldConfig: FieldConfig{IntervalSeconds: 60}, ChangesPerHour: 0.1},
		{Name: "FastChargerPresent", FieldConfig: FieldConfig{IntervalSeconds: 60}, ChangesPerHour: 0.2},
		{Name: "ChargePortDoorOpen", FieldConfig: FieldConfig{IntervalSeconds: 5}, ChangesPerHour: 0.5},
		{Name: "ChargePortLatch", FieldConfig: FieldConfig{IntervalSeconds: 5}, ChangesPerHour: 0.5},
		{Name: "ChargingCableType", FieldConfig: FieldConfig{IntervalSeconds: 60}, ChangesPerHour: 0.5},

		{Name: "Locked", FieldConfig: FieldConfig{IntervalSeconds: 5}, ChangesPerHour: 2},
		{Name: "SentryMode", FieldConfig: FieldConfig{IntervalSeconds: 5}, ChangesPerHour: 2},
		{Name: "TpmsPressureFl", FieldConfig: FieldConfig{IntervalSeconds: 1800}},
		{Name: "TpmsPressureFr", FieldConfig: FieldConfig{IntervalSeconds: 1800}},
		{Name: "TpmsPressureRl", FieldConfig: FieldConfig{IntervalSeconds: 1800}},
		{Name: "TpmsPressureRr", FieldConfig: FieldConfig{IntervalSeconds: 1800}},
		{Name: "Version", FieldConfig: FieldConfig{IntervalSeconds: 3600}, ChangesPerHour: 0.01},
	}
}

// EconomyProfile is installed at the warning threshold. It preserves the
// fields needed to segment drives/charges and render useful history, but
// reduces the fast parent to ten seconds and slows changing state.
func EconomyProfile() []Planned {
	return []Planned{
		{Name: "Location", FieldConfig: FieldConfig{IntervalSeconds: 10, MinimumDelta: f(15), IncludeFields: []string{"VehicleSpeed", "PackVoltage", "PackCurrent"}}},
		{Name: "Gear", FieldConfig: FieldConfig{IntervalSeconds: 2}, ChangesPerHour: 12},
		{Name: "Odometer", FieldConfig: FieldConfig{IntervalSeconds: 120}},
		{Name: "Soc", FieldConfig: FieldConfig{IntervalSeconds: 120}},
		{Name: "BatteryLevel", FieldConfig: FieldConfig{IntervalSeconds: 120}},
		{Name: "EnergyRemaining", FieldConfig: FieldConfig{IntervalSeconds: 120}},
		{Name: "ModuleTempMin", FieldConfig: FieldConfig{IntervalSeconds: 300, MinimumDelta: f(1)}},
		{Name: "ModuleTempMax", FieldConfig: FieldConfig{IntervalSeconds: 300, MinimumDelta: f(1)}},
		{Name: "InsideTemp", FieldConfig: FieldConfig{IntervalSeconds: 300, MinimumDelta: f(1)}},
		{Name: "OutsideTemp", FieldConfig: FieldConfig{IntervalSeconds: 300, MinimumDelta: f(1)}},
		{Name: "DetailedChargeState", FieldConfig: FieldConfig{IntervalSeconds: 10}, ChangesPerHour: 1},
		{Name: "ACChargingPower", FieldConfig: FieldConfig{IntervalSeconds: 120}},
		{Name: "DCChargingPower", FieldConfig: FieldConfig{IntervalSeconds: 30}},
		{Name: "ACChargingEnergyIn", FieldConfig: FieldConfig{IntervalSeconds: 300}},
		{Name: "DCChargingEnergyIn", FieldConfig: FieldConfig{IntervalSeconds: 300}},
		{Name: "ChargeLimitSoc", FieldConfig: FieldConfig{IntervalSeconds: 120}, ChangesPerHour: 0.1},
		{Name: "TimeToFullCharge", FieldConfig: FieldConfig{IntervalSeconds: 600}},
	}
}

// Limits for validation.
const (
	MaxTopLevelFields  = 40
	MaxIncludePerField = 6
	MinIntervalSeconds = 1
	MaxExpiry          = 31 * 24 * time.Hour
	DefaultExpiry      = 30 * 24 * time.Hour
)

// Validate enforces the bounded-cost rules: only registry fields, bounded
// counts, positive intervals, includes only of registry fields, and the
// Tesla rule for MilesSinceReset includes.
func Validate(p []Planned) error {
	if len(p) == 0 || len(p) > MaxTopLevelFields {
		return fmt.Errorf("profile must have 1..%d fields", MaxTopLevelFields)
	}
	seen := map[string]bool{}
	for _, e := range p {
		spec, ok := fields.ByName(e.Name)
		if !ok {
			return fmt.Errorf("field %s is not in the Volta registry", e.Name)
		}
		if seen[e.Name] {
			return fmt.Errorf("field %s listed twice", e.Name)
		}
		seen[e.Name] = true
		if e.IntervalSeconds < MinIntervalSeconds {
			return fmt.Errorf("field %s interval must be >= %d s", e.Name, MinIntervalSeconds)
		}
		if len(e.IncludeFields) > MaxIncludePerField {
			return fmt.Errorf("field %s includes more than %d fields", e.Name, MaxIncludePerField)
		}
		if e.MinimumDelta != nil && (*e.MinimumDelta <= 0 || math.IsNaN(*e.MinimumDelta)) {
			return fmt.Errorf("field %s minimum_delta must be positive", e.Name)
		}
		if e.MinimumDelta != nil && spec.Kind != fields.KindNumber && spec.Kind != fields.KindLocation {
			return fmt.Errorf("field %s cannot take minimum_delta", e.Name)
		}
		inc := map[string]bool{}
		for _, i := range e.IncludeFields {
			if _, ok := fields.ByName(i); !ok {
				return fmt.Errorf("field %s includes unregistered %s", e.Name, i)
			}
			if i == e.Name || inc[i] {
				return fmt.Errorf("field %s has a self or duplicate include %s", e.Name, i)
			}
			inc[i] = true
		}
		if spec.NeedsLocationScope && e.Name != "Location" && e.Name != "GpsHeading" {
			return fmt.Errorf("field %s needs vehicle_location scope and is not approved", e.Name)
		}
	}
	return nil
}

// Build returns the request body. VINs are supplied by the caller at send
// time (commander owns them); placeholders are used in checked-in examples.
func Build(p []Planned, vins []string, hostname string, port int, caPEM string, now time.Time, expiry time.Duration) (Request, error) {
	if err := Validate(p); err != nil {
		return Request{}, err
	}
	if hostname == "" || port <= 0 || port > 65535 {
		return Request{}, errors.New("hostname and port are required")
	}
	if !strings.Contains(caPEM, "BEGIN CERTIFICATE") {
		return Request{}, errors.New("ca must be a PEM certificate chain")
	}
	if expiry <= 0 || expiry > MaxExpiry {
		return Request{}, fmt.Errorf("expiry must be within (0, %s]", MaxExpiry)
	}
	if len(vins) == 0 {
		return Request{}, errors.New("at least one VIN is required")
	}
	fs := make(map[string]FieldConfig, len(p))
	for _, e := range p {
		fs[e.Name] = e.FieldConfig
	}
	return Request{
		VINs: vins,
		Config: Config{
			Hostname:       hostname,
			Port:           port,
			CA:             caPEM,
			Fields:         fs,
			Exp:            now.Add(expiry).Unix(),
			DeliveryPolicy: "latest",
		},
	}, nil
}

// Line is one field's budget.
type Line struct {
	Field           string  `json:"field"`
	Class           string  `json:"class"`
	IntervalSeconds int     `json:"intervalSeconds"`
	Includes        int     `json:"includes"`
	Hours           float64 `json:"hours"`
	PlanningSignals float64 `json:"planningSignals"`
	StartupSignals  float64 `json:"startupSignals"`
	TotalSignals    float64 `json:"totalPlanningSignals"`
	PlanningUSD     float64 `json:"planningUSD"`
	TheoreticalMax  float64 `json:"theoreticalMaxSignals"`
}

// Budget is the monthly estimate.
type Budget struct {
	Hours                 Hours   `json:"hours"`
	Lines                 []Line  `json:"lines"`
	StartupSignals        float64 `json:"startupSignals"`
	PlanningSignals       float64 `json:"planningSignals"`
	PlanningUSD           float64 `json:"planningUSD"`
	TheoreticalMaxSignals float64 `json:"theoreticalMaxSignals"`
	TheoreticalMaxUSD     float64 `json:"theoreticalMaxUSD"`
}

func hoursFor(c fields.Class, h Hours) float64 {
	switch c {
	case fields.ClassDrive:
		return h.Drive
	case fields.ClassCharge:
		return h.ACCharge + h.DCCharge
	case fields.ClassDCCharge:
		return h.DCCharge
	case fields.ClassEnergy:
		return h.Drive + h.ACCharge + h.DCCharge
	default:
		return h.Awake
	}
}

// Estimate computes the planning and theoretical-maximum monthly signals.
// Planning: continuous fields change every interval during their class
// hours; discrete fields change ChangesPerHour times. Theoretical maximum:
// every field changes every interval for all its class hours. Both count
// each include as one more signal per parent send. Reconnect snapshots also
// count a full parent+includes send for every top-level entry; duplicate
// includes across parents are counted separately because coalescing is not a
// billing guarantee.
func Estimate(p []Planned, h Hours) Budget {
	b := Budget{Hours: h}
	for _, e := range p {
		spec, _ := fields.ByName(e.Name)
		hours := hoursFor(spec.Class, h)
		maxPerHour := 3600 / float64(e.IntervalSeconds)
		perSend := 1 + float64(len(e.IncludeFields))
		plan := maxPerHour
		if e.ChangesPerHour > 0 {
			plan = math.Min(e.ChangesPerHour, maxPerHour)
		}
		l := Line{
			Field: e.Name, Class: string(spec.Class), IntervalSeconds: e.IntervalSeconds,
			Includes: len(e.IncludeFields), Hours: hours,
			PlanningSignals: plan * hours * perSend,
			TheoreticalMax:  maxPerHour * hours * perSend,
		}
		l.StartupSignals = h.Connections * perSend
		l.TotalSignals = l.PlanningSignals + l.StartupSignals
		l.PlanningUSD = l.TotalSignals / SignalsPerUSD
		b.Lines = append(b.Lines, l)
		b.PlanningSignals += l.TotalSignals
		b.TheoreticalMaxSignals += l.TheoreticalMax + l.StartupSignals
		b.StartupSignals += l.StartupSignals
	}
	sort.Slice(b.Lines, func(i, j int) bool { return b.Lines[i].TotalSignals > b.Lines[j].TotalSignals })
	b.PlanningUSD = b.PlanningSignals / SignalsPerUSD
	b.TheoreticalMaxUSD = b.TheoreticalMaxSignals / SignalsPerUSD
	return b
}
