package fleetconfig

import (
	"encoding/json"
	"math"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/georgenijo/volta/ingestion/internal/testvin"
)

const fakeCA = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"

const (
	warnUSD = 20.0
	stopUSD = 23.0
)

func TestProfileValid(t *testing.T) {
	if err := Validate(Profile()); err != nil {
		t.Fatal(err)
	}
	if err := Validate(EconomyProfile()); err != nil {
		t.Fatal(err)
	}
}

func TestCommanderProfilesAreGeneratedFromFleetConfig(t *testing.T) {
	want := map[string]map[string]FieldConfig{}
	for name, planned := range map[string][]Planned{"normal": Profile(), "economy": EconomyProfile()} {
		entries := map[string]FieldConfig{}
		for _, p := range planned {
			entries[p.Name] = p.FieldConfig
		}
		want[name] = entries
	}
	b, err := os.ReadFile("../../commander/telemetry_profiles.json")
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]map[string]FieldConfig
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatal("commander telemetry_profiles.json is stale; regenerate with go run ./cmd/volta-telemetry-config -mode=profiles")
	}
}

func TestPlanningBudgetWithinReservation(t *testing.T) {
	b := Estimate(Profile(), DefaultHours)
	if b.PlanningUSD > warnUSD {
		t.Fatalf("planning $%.2f exceeds warning $%.2f", b.PlanningUSD, warnUSD)
	}
	cheap := Estimate(EconomyProfile(), DefaultHours)
	if cheap.PlanningUSD >= b.PlanningUSD || cheap.PlanningUSD >= stopUSD {
		t.Fatalf("economy $%.2f must be cheaper than normal $%.2f and below stop", cheap.PlanningUSD, b.PlanningUSD)
	}
	if math.Round(b.PlanningSignals) != 636003 || math.Round(b.TheoreticalMaxSignals) != 1875900 || b.StartupSignals != 27000 {
		t.Fatalf("documented cost table drifted: planning=%.0f max=%.0f startup=%.0f", b.PlanningSignals, b.TheoreticalMaxSignals, b.StartupSignals)
	}
	t.Logf("planning %.0f signals ($%.2f), theoretical max %.0f signals ($%.2f), startup %.0f",
		b.PlanningSignals, b.PlanningUSD, b.TheoreticalMaxSignals, b.TheoreticalMaxUSD, b.StartupSignals)
}

func TestDenseTripFixture(t *testing.T) {
	var loc *Planned
	for i, p := range Profile() {
		if p.Name == "Location" {
			loc = &Profile()[i]
		}
	}
	if loc == nil || loc.IntervalSeconds != 2 {
		t.Fatal("Location must stream every 2 s")
	}
	want := map[string]bool{"VehicleSpeed": true, "PackVoltage": true, "PackCurrent": true, "LongitudinalAcceleration": true, "LateralAcceleration": true}
	for _, f := range loc.IncludeFields {
		delete(want, f)
	}
	if len(want) != 0 {
		t.Fatalf("Location is missing co-timed includes %v", want)
	}
}

func TestNormalChargingSlowFieldsStayWithinSixtySeconds(t *testing.T) {
	required := map[string]bool{
		"ACChargingPower": true, "ACChargingEnergyIn": true,
		"DCChargingEnergyIn": true, "ChargeAmps": true,
		"ChargerVoltage": true, "TimeToFullCharge": true,
	}
	for _, p := range Profile() {
		if !required[p.Name] {
			continue
		}
		if p.IntervalSeconds < 30 || p.IntervalSeconds > 60 {
			t.Errorf("%s interval %ds is outside the normal 30-60s charging cadence", p.Name, p.IntervalSeconds)
		}
		delete(required, p.Name)
	}
	if len(required) != 0 {
		t.Fatalf("normal profile is missing required charging fields: %v", required)
	}
}

func TestValidateRejectsUnbounded(t *testing.T) {
	bad := map[string][]Planned{
		"unknown":    {{Name: "VehicleName", FieldConfig: FieldConfig{IntervalSeconds: 60}}},
		"zero int":   {{Name: "Soc", FieldConfig: FieldConfig{IntervalSeconds: 0}}},
		"dup":        {{Name: "Soc", FieldConfig: FieldConfig{IntervalSeconds: 60}}, {Name: "Soc", FieldConfig: FieldConfig{IntervalSeconds: 60}}},
		"bool delta": {{Name: "Locked", FieldConfig: FieldConfig{IntervalSeconds: 60, MinimumDelta: f(1)}}},
		"neg delta":  {{Name: "Soc", FieldConfig: FieldConfig{IntervalSeconds: 60, MinimumDelta: f(-1)}}},
		"self inc":   {{Name: "Soc", FieldConfig: FieldConfig{IntervalSeconds: 60, IncludeFields: []string{"Soc"}}}},
		"bad inc":    {{Name: "Soc", FieldConfig: FieldConfig{IntervalSeconds: 60, IncludeFields: []string{"VehicleName"}}}},
		"many inc":   {{Name: "Soc", FieldConfig: FieldConfig{IntervalSeconds: 60, IncludeFields: []string{"Odometer", "Gear", "PackVoltage", "PackCurrent", "BatteryLevel", "RatedRange", "InsideTemp"}}}},
		"empty":      {},
	}
	for name, p := range bad {
		if err := Validate(p); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
}

func TestBuild(t *testing.T) {
	now := time.Date(2026, 10, 8, 0, 0, 0, 0, time.UTC)
	req, err := Build(Profile(), []string{testvin.A}, "volta-node.example.ts.net", 10000, fakeCA, now, DefaultExpiry)
	if err != nil {
		t.Fatal(err)
	}
	if req.Config.Port != 10000 || req.Config.DeliveryPolicy != "latest" || req.Config.Exp != now.Add(30*24*time.Hour).Unix() {
		t.Fatalf("config %+v", req.Config)
	}
	b, _ := json.Marshal(req)
	for _, s := range []string{`"interval_seconds":2`, `"include_fields":["VehicleSpeed"`, `"minimum_delta":3`} {
		if !strings.Contains(string(b), s) {
			t.Errorf("body lacks %s", s)
		}
	}
	if _, err := Build(Profile(), []string{testvin.A}, "h", 10000, fakeCA, now, 40*24*time.Hour); err == nil {
		t.Error("expiry over 31 days accepted")
	}
	if _, err := Build(Profile(), []string{testvin.A}, "h", 10000, "not pem", now, DefaultExpiry); err == nil {
		t.Error("non-PEM CA accepted")
	}
	if _, err := Build(Profile(), nil, "h", 10000, fakeCA, now, DefaultExpiry); err == nil {
		t.Error("no VINs accepted")
	}
}
