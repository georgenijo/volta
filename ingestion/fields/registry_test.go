package fields

import (
	"math"
	"testing"

	"github.com/teslamotors/fleet-telemetry/protos"
	"google.golang.org/protobuf/reflect/protoreflect"
)

func TestRegistryMatchesProto(t *testing.T) {
	for _, s := range All() {
		if protos.Field_name[int32(s.Field)] != s.Name {
			t.Errorf("%s does not match proto enum %d", s.Name, s.Field)
		}
		if got, ok := ByField(s.Field); !ok || got.Name != s.Name {
			t.Errorf("ByField(%s) mismatch", s.Name)
		}
		if s.Kind == KindNumber && s.UnitStatus == UnitNone {
			t.Errorf("%s is numeric but has no unit status", s.Name)
		}
		if s.Kind == KindNumber && s.SourceUnit == "" {
			t.Errorf("%s is numeric but has no source unit", s.Name)
		}
		if s.Kind == KindEnum {
			fd := (&protos.Value{}).ProtoReflect().Descriptor().Fields().ByName(protoreflect.Name(s.EnumOneof))
			if fd == nil || fd.Kind() != protoreflect.EnumKind || fd.ContainingOneof() == nil {
				t.Errorf("%s: enum oneof %q is not an enum member of protos.Value", s.Name, s.EnumOneof)
			}
		}
	}
}

func TestRequiredFieldsPresent(t *testing.T) {
	required := []string{
		"Location", "GpsHeading", "VehicleSpeed", "Odometer", "Soc", "Gear",
		"RatedRange", "EstBatteryRange", "IdealBatteryRange", "InsideTemp", "OutsideTemp",
		"ModuleTempMin", "ModuleTempMax", "EnergyRemaining", "LifetimeEnergyUsed",
		"LifetimeEnergyGainedRegen", "PackVoltage", "PackCurrent", "DetailedChargeState",
		"ACChargingPower", "DCChargingPower", "ACChargingEnergyIn", "DCChargingEnergyIn",
		"ChargePortDoorOpen", "ChargePortLatch", "Locked", "SentryMode",
		"TpmsPressureFl", "TpmsPressureFr", "TpmsPressureRl", "TpmsPressureRr", "Version",
	}
	for _, n := range required {
		if _, ok := ByName(n); !ok {
			t.Errorf("required field %s missing", n)
		}
	}
}

func TestImperialConversionsAreDocumentedOrMapped(t *testing.T) {
	// Only miles are converted; everything else is passed through.
	for _, s := range All() {
		if s.ToMetric == nil {
			continue
		}
		if s.SourceUnit != "mph" && s.SourceUnit != "mi" {
			t.Errorf("%s converts from %q; only mi/mph conversions are allowed", s.Name, s.SourceUnit)
		}
		if got := s.Metric(1); math.Abs(got-1.609344) > 1e-9 {
			t.Errorf("%s converts 1 to %v", s.Name, got)
		}
	}
	speed, _ := ByName("VehicleSpeed")
	if speed.UnitStatus != UnitDoc || speed.SourceUnit != "mph" {
		t.Fatal("VehicleSpeed must be documented mph")
	}
	odo, _ := ByName("Odometer")
	if odo.UnitStatus != UnitDoc || odo.SourceUnit != "mi" {
		t.Fatal("Odometer must be documented mi")
	}
}
