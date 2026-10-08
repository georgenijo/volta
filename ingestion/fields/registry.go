// Package fields is the single registry of the Fleet Telemetry fields Volta
// streams, their source units, how sure we are about those units, and the
// metric conversion the Volta API exposes.
//
// Unit status is deliberately explicit:
//
//   - UnitDoc: the unit is stated on developer.tesla.com
//     (fleet-telemetry/available-data) for the field itself.
//   - UnitLegacyMap: the page maps the field to a legacy vehicle_data key
//     whose unit is known (for example RatedRange -> charge_state.battery_range,
//     miles). Strong inference; a live gate compares it against polling.
//   - UnitInferred: unit not stated anywhere; inferred from physics and
//     magnitude. Never shown as verified until a live gate confirms it.
//
// Nothing here is guessed silently: anything not UnitDoc is surfaced in the
// API contract as unitStatus so the app can choose not to present it as fact.
package fields

import (
	"sort"

	"github.com/teslamotors/fleet-telemetry/protos"
)

// UnitStatus describes how the source unit of a field was established.
type UnitStatus string

const (
	UnitDoc       UnitStatus = "doc"
	UnitLegacyMap UnitStatus = "legacy_map"
	UnitInferred  UnitStatus = "inferred"
	UnitNone      UnitStatus = "none" // enums, booleans, strings
)

// Kind is the value shape Volta expects for a field.
type Kind string

const (
	KindNumber   Kind = "number"
	KindBool     Kind = "bool"
	KindEnum     Kind = "enum"
	KindLocation Kind = "location"
	KindString   Kind = "string"
)

// Class bounds when a field can change. The budget calculator multiplies a
// field's maximum send rate by the hours of its class.
type Class string

const (
	ClassDrive    Class = "drive"     // changes only while moving
	ClassCharge   Class = "charge"    // changes only while charging (AC or DC)
	ClassDCCharge Class = "dc_charge" // changes only while DC fast charging
	ClassEnergy   Class = "energy"    // changes while driving or charging
	ClassAwake    Class = "awake"     // can change any time the car is awake
)

// Spec is one registry entry.
type Spec struct {
	Name       string
	Field      protos.Field
	Kind       Kind
	SourceUnit string // as sent by the vehicle
	UnitStatus UnitStatus
	// MetricUnit and ToMetric describe the conversion the Volta API exposes.
	// For fields already metric ToMetric is nil.
	MetricUnit string
	ToMetric   func(float64) float64
	Class      Class
	// Location-scope fields need the vehicle_location OAuth scope.
	NeedsLocationScope bool
	// EnumOneof is the protos.Value oneof member an enum field must arrive
	// in (for example "shift_state_value"). Any other member is malformed.
	EnumOneof string
	Note      string
}

const (
	kmPerMile = 1.609344
)

func miToKm(v float64) float64 { return v * kmPerMile }

var registry = []Spec{
	// Trip / route.
	{Name: "Location", Field: protos.Field_Location, Kind: KindLocation, SourceUnit: "deg", UnitStatus: UnitInferred, MetricUnit: "deg", Class: ClassDrive, NeedsLocationScope: true, Note: "WGS84 latitude/longitude"},
	{Name: "GpsHeading", Field: protos.Field_GpsHeading, Kind: KindNumber, SourceUnit: "deg", UnitStatus: UnitDoc, MetricUnit: "deg", Class: ClassDrive, NeedsLocationScope: true, Note: "0 = North, 90 = East (doc)"},
	{Name: "VehicleSpeed", Field: protos.Field_VehicleSpeed, Kind: KindNumber, SourceUnit: "mph", UnitStatus: UnitDoc, MetricUnit: "km/h", ToMetric: miToKm, Class: ClassDrive},
	{Name: "Odometer", Field: protos.Field_Odometer, Kind: KindNumber, SourceUnit: "mi", UnitStatus: UnitDoc, MetricUnit: "km", ToMetric: miToKm, Class: ClassDrive, Note: "default minimum_delta 0.1 since fw 2025.2.6"},
	{Name: "Gear", Field: protos.Field_Gear, Kind: KindEnum, EnumOneof: "shift_state_value", UnitStatus: UnitNone, Class: ClassDrive, Note: "ShiftState enum"},
	{Name: "LateralAcceleration", Field: protos.Field_LateralAcceleration, Kind: KindNumber, SourceUnit: "m/s2", UnitStatus: UnitDoc, MetricUnit: "m/s2", Class: ClassDrive, Note: "official available-data page: measured in m/s^2"},
	{Name: "LongitudinalAcceleration", Field: protos.Field_LongitudinalAcceleration, Kind: KindNumber, SourceUnit: "m/s2", UnitStatus: UnitDoc, MetricUnit: "m/s2", Class: ClassDrive, Note: "official available-data page: measured in m/s^2"},

	// Battery and range.
	{Name: "Soc", Field: protos.Field_Soc, Kind: KindNumber, SourceUnit: "%", UnitStatus: UnitDoc, MetricUnit: "%", Class: ClassEnergy, Note: "usable SoC (legacy usable_battery_level)"},
	{Name: "BatteryLevel", Field: protos.Field_BatteryLevel, Kind: KindNumber, SourceUnit: "%", UnitStatus: UnitDoc, MetricUnit: "%", Class: ClassEnergy},
	{Name: "RatedRange", Field: protos.Field_RatedRange, Kind: KindNumber, SourceUnit: "mi", UnitStatus: UnitLegacyMap, MetricUnit: "km", ToMetric: miToKm, Class: ClassEnergy, Note: "maps to charge_state.battery_range"},
	{Name: "EstBatteryRange", Field: protos.Field_EstBatteryRange, Kind: KindNumber, SourceUnit: "mi", UnitStatus: UnitLegacyMap, MetricUnit: "km", ToMetric: miToKm, Class: ClassEnergy, Note: "maps to charge_state.est_battery_range"},
	{Name: "IdealBatteryRange", Field: protos.Field_IdealBatteryRange, Kind: KindNumber, SourceUnit: "mi", UnitStatus: UnitInferred, MetricUnit: "km", ToMetric: miToKm, Class: ClassEnergy, Note: "no legacy mapping on the doc page"},
	{Name: "EnergyRemaining", Field: protos.Field_EnergyRemaining, Kind: KindNumber, SourceUnit: "kWh", UnitStatus: UnitDoc, MetricUnit: "kWh", Class: ClassEnergy, Note: "nominal energy remaining"},
	{Name: "LifetimeEnergyUsed", Field: protos.Field_LifetimeEnergyUsed, Kind: KindNumber, SourceUnit: "kWh", UnitStatus: UnitDoc, MetricUnit: "kWh", Class: ClassDrive, Note: "doc: total energy-lost kWh count during discharging"},
	{Name: "LifetimeEnergyGainedRegen", Field: protos.Field_LifetimeEnergyGainedRegen, Kind: KindNumber, SourceUnit: "kWh", UnitStatus: UnitInferred, MetricUnit: "kWh", Class: ClassDrive, Note: "proto only; not on the doc page"},
	{Name: "PackVoltage", Field: protos.Field_PackVoltage, Kind: KindNumber, SourceUnit: "V", UnitStatus: UnitInferred, MetricUnit: "V", Class: ClassEnergy, Note: "battery side of HV contactors"},
	{Name: "PackCurrent", Field: protos.Field_PackCurrent, Kind: KindNumber, SourceUnit: "A", UnitStatus: UnitInferred, MetricUnit: "A", Class: ClassEnergy, Note: "at HV contactors; sign undocumented, see power.Calibrate"},
	{Name: "ModuleTempMin", Field: protos.Field_ModuleTempMin, Kind: KindNumber, SourceUnit: "C", UnitStatus: UnitInferred, MetricUnit: "C", Class: ClassAwake, Note: "minimum thermistor temperature (not a pack average)"},
	{Name: "ModuleTempMax", Field: protos.Field_ModuleTempMax, Kind: KindNumber, SourceUnit: "C", UnitStatus: UnitInferred, MetricUnit: "C", Class: ClassAwake, Note: "maximum thermistor temperature (not a pack average)"},

	// Climate.
	{Name: "InsideTemp", Field: protos.Field_InsideTemp, Kind: KindNumber, SourceUnit: "C", UnitStatus: UnitDoc, MetricUnit: "C", Class: ClassAwake},
	{Name: "OutsideTemp", Field: protos.Field_OutsideTemp, Kind: KindNumber, SourceUnit: "C", UnitStatus: UnitLegacyMap, MetricUnit: "C", Class: ClassAwake, Note: "maps to climate_state.outside_temp"},

	// Charging.
	{Name: "DetailedChargeState", Field: protos.Field_DetailedChargeState, Kind: KindEnum, EnumOneof: "detailed_charge_state_value", UnitStatus: UnitNone, Class: ClassAwake, Note: "DetailedChargeStateValue enum, fw 2024.38+"},
	{Name: "ACChargingPower", Field: protos.Field_ACChargingPower, Kind: KindNumber, SourceUnit: "kW", UnitStatus: UnitInferred, MetricUnit: "kW", Class: ClassCharge},
	{Name: "DCChargingPower", Field: protos.Field_DCChargingPower, Kind: KindNumber, SourceUnit: "kW", UnitStatus: UnitInferred, MetricUnit: "kW", Class: ClassDCCharge},
	{Name: "ACChargingEnergyIn", Field: protos.Field_ACChargingEnergyIn, Kind: KindNumber, SourceUnit: "kWh", UnitStatus: UnitDoc, MetricUnit: "kWh", Class: ClassCharge, Note: "measured from the charger; ignore during DC"},
	{Name: "DCChargingEnergyIn", Field: protos.Field_DCChargingEnergyIn, Kind: KindNumber, SourceUnit: "kWh", UnitStatus: UnitDoc, MetricUnit: "kWh", Class: ClassCharge, Note: "measured at the battery; valid for AC and DC"},
	{Name: "ChargerVoltage", Field: protos.Field_ChargerVoltage, Kind: KindNumber, SourceUnit: "V", UnitStatus: UnitInferred, MetricUnit: "V", Class: ClassCharge, Note: "AC RMS input voltage; default minimum_delta 0.3"},
	{Name: "ChargeAmps", Field: protos.Field_ChargeAmps, Kind: KindNumber, SourceUnit: "A", UnitStatus: UnitLegacyMap, MetricUnit: "A", Class: ClassCharge, Note: "maps to charge_state.charger_actual_current"},
	{Name: "ChargeLimitSoc", Field: protos.Field_ChargeLimitSoc, Kind: KindNumber, SourceUnit: "%", UnitStatus: UnitDoc, MetricUnit: "%", Class: ClassAwake},
	{Name: "TimeToFullCharge", Field: protos.Field_TimeToFullCharge, Kind: KindNumber, SourceUnit: "h", UnitStatus: UnitDoc, MetricUnit: "h", Class: ClassCharge},
	{Name: "FastChargerPresent", Field: protos.Field_FastChargerPresent, Kind: KindBool, UnitStatus: UnitNone, Class: ClassAwake},
	{Name: "ChargePortDoorOpen", Field: protos.Field_ChargePortDoorOpen, Kind: KindBool, UnitStatus: UnitNone, Class: ClassAwake},
	{Name: "ChargePortLatch", Field: protos.Field_ChargePortLatch, Kind: KindEnum, EnumOneof: "charge_port_latch_value", UnitStatus: UnitNone, Class: ClassAwake},
	{Name: "ChargingCableType", Field: protos.Field_ChargingCableType, Kind: KindEnum, EnumOneof: "cable_type_value", UnitStatus: UnitNone, Class: ClassAwake, Note: "Invalid when no cable is present"},

	// Security and service.
	{Name: "Locked", Field: protos.Field_Locked, Kind: KindBool, UnitStatus: UnitNone, Class: ClassAwake},
	{Name: "SentryMode", Field: protos.Field_SentryMode, Kind: KindEnum, EnumOneof: "sentry_mode_state_value", UnitStatus: UnitNone, Class: ClassAwake},
	{Name: "TpmsPressureFl", Field: protos.Field_TpmsPressureFl, Kind: KindNumber, SourceUnit: "bar", UnitStatus: UnitDoc, MetricUnit: "bar", Class: ClassAwake},
	{Name: "TpmsPressureFr", Field: protos.Field_TpmsPressureFr, Kind: KindNumber, SourceUnit: "bar", UnitStatus: UnitDoc, MetricUnit: "bar", Class: ClassAwake},
	{Name: "TpmsPressureRl", Field: protos.Field_TpmsPressureRl, Kind: KindNumber, SourceUnit: "bar", UnitStatus: UnitDoc, MetricUnit: "bar", Class: ClassAwake},
	{Name: "TpmsPressureRr", Field: protos.Field_TpmsPressureRr, Kind: KindNumber, SourceUnit: "bar", UnitStatus: UnitDoc, MetricUnit: "bar", Class: ClassAwake},
	{Name: "Version", Field: protos.Field_Version, Kind: KindString, UnitStatus: UnitNone, Class: ClassAwake, Note: "firmware version string"},
}

var (
	byName  = map[string]Spec{}
	byField = map[protos.Field]Spec{}
)

func init() {
	for _, s := range registry {
		if _, dup := byName[s.Name]; dup {
			panic("fields: duplicate registry name " + s.Name)
		}
		if protos.Field_name[int32(s.Field)] != s.Name {
			panic("fields: registry name does not match proto enum name: " + s.Name)
		}
		if (s.Kind == KindEnum) != (s.EnumOneof != "") {
			panic("fields: enum oneof must be set exactly for enum fields: " + s.Name)
		}
		byName[s.Name] = s
		byField[s.Field] = s
	}
}

// ByName returns the registry entry for a proto field name.
func ByName(name string) (Spec, bool) { s, ok := byName[name]; return s, ok }

// ByField returns the registry entry for a proto field.
func ByField(f protos.Field) (Spec, bool) { s, ok := byField[f]; return s, ok }

// All returns every registered field sorted by name.
func All() []Spec {
	out := append([]Spec(nil), registry...)
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// Metric converts a source value to the API's metric unit.
func (s Spec) Metric(v float64) float64 {
	if s.ToMetric == nil {
		return v
	}
	return s.ToMetric(v)
}
