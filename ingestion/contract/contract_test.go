package contract

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func fp(v float64) *float64 { return &v }
func sp(v string) *string   { return &v }

var t0 = time.Date(2026, 10, 8, 17, 0, 0, 123_456_789, time.UTC)

func TestDrivePointCompatibleWithIOS(t *testing.T) {
	p := FromRow(DrivePointRow{
		SourceTS: t0, Latitude: 37.77, Longitude: -122.42, SpeedKph: fp(48.28032), HeadingDeg: fp(90),
		PowerKw: fp(12.3456), PowerSign: "discharge_positive", PackVoltageV: fp(380), PackCurrentA: fp(32.5),
		BatteryLevelPct: fp(79.6), TripMembership: "member",
	})
	b, _ := json.Marshal(p)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	// iOS DrivePoint keys must be present with the iOS types.
	if m["t"] != "2026-10-08T17:00:00.123Z" {
		t.Fatalf("t = %v", m["t"])
	}
	for _, k := range []string{"latitude", "longitude", "speedKph", "powerKw", "elevationM", "batteryLevel"} {
		if _, ok := m[k]; !ok {
			t.Errorf("missing %s", k)
		}
	}
	if m["batteryLevel"] != float64(80) || m["elevationM"] != nil || m["powerKw"] != 12.346 || m["speedKph"] != 48.28 {
		t.Fatalf("values %s", b)
	}
	if m["source"] != Source || m["tripMembership"] != "member" {
		t.Fatalf("additive %s", b)
	}
}

func TestUnverifiedPowerIsNull(t *testing.T) {
	p := FromRow(DrivePointRow{SourceTS: t0, Latitude: 1, Longitude: 1, PowerKw: fp(5), PowerSign: "unverified"})
	if p.PowerKw != nil || p.TripMembership != "unknown" || p.BatteryLevel != nil || p.SpeedKph != nil {
		t.Fatalf("%+v", p)
	}
	b, _ := json.Marshal(p)
	if !strings.Contains(string(b), `"powerKw":null`) || !strings.Contains(string(b), `"speedKph":null`) {
		t.Fatalf("unknowns must be explicit nulls: %s", b)
	}
}

func TestSnapshotFreshnessAndUnits(t *testing.T) {
	now := t0.Add(2 * time.Hour)
	rows := []LatestRow{
		{Field: "Odometer", SourceTS: t0.Add(90 * time.Minute), Num: fp(100)},
		{Field: "TpmsPressureFl", SourceTS: t0, Num: fp(2.9)}, // sparse, before the reconnect
		{Field: "Version", SourceTS: t0.Add(100 * time.Minute), Text: sp("2026.27.11")},
		{Field: "PackCurrent", SourceTS: t0.Add(100 * time.Minute), Invalid: true},
		{Field: "VehicleName", SourceTS: t0, Text: sp("Friday")},
	}
	link := Link{Connected: true, Since: t0.Add(80 * time.Minute)}
	s := SnapshotFrom(1, rows, link, now)
	by := map[string]Value{}
	for _, v := range s.Values {
		by[v.Field] = v
	}
	if _, ok := by["VehicleName"]; ok {
		t.Fatal("unregistered field exposed")
	}
	odo := by["Odometer"]
	if odo.Num == nil || *odo.Num != 160.9344 || odo.Unit != "km" || odo.UnitStatus != "doc" || odo.Freshness != FreshCurrent {
		t.Fatalf("odometer %+v", odo)
	}
	if tp := by["TpmsPressureFl"]; tp.Freshness != FreshLastKnown || tp.AgeSeconds != 7200 {
		t.Fatalf("tpms %+v", tp)
	}
	if pc := by["PackCurrent"]; !pc.Invalid || pc.Num != nil || pc.UnitStatus != "inferred" {
		t.Fatalf("pack current %+v", pc)
	}
	// Disconnected stream: nothing is current.
	s = SnapshotFrom(1, rows, Link{}, now)
	for _, v := range s.Values {
		if v.Freshness != FreshLastKnown {
			t.Fatalf("%s current while disconnected", v.Field)
		}
	}
}

func TestRouteBreakAndQuality(t *testing.T) {
	p := FromRow(DrivePointRow{SourceTS: t0, Latitude: 1, Longitude: 1, RouteBreak: true})
	b, _ := json.Marshal(p)
	if !strings.Contains(string(b), `"routeBreakBefore":true`) {
		t.Fatalf("%s", b)
	}
	rows := []LatestRow{
		{Field: "Soc", SourceTS: t0, Num: fp(50), Quality: "ok"},
		{Field: "Gear", SourceTS: t0, Invalid: true, Quality: "conflict"},
		{Field: "Odometer", SourceTS: t0, Invalid: true},
	}
	s := SnapshotFrom(1, rows, Link{}, t0)
	q := map[string]string{}
	for _, v := range s.Values {
		q[v.Field] = v.Quality
	}
	if q["Soc"] != "ok" || q["Gear"] != "conflict" || q["Odometer"] != "invalid" {
		t.Fatalf("%v", q)
	}
	if s.StreamConnected {
		t.Fatal("unconfirmed link reported connected")
	}
}
