package commander

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"sync/atomic"
	"testing"
	"time"
)

type fakeTelemetryReader struct {
	snap   telemetrySnapshot
	err    error
	calls  int
	during func()
}

func (f *fakeTelemetryReader) Read(_ context.Context, _ string) (telemetrySnapshot, error) {
	f.calls++
	if f.during != nil {
		f.during()
	}
	return f.snap, f.err
}
func floatPtr(n float64) *float64 { return &n }
func textPtr(s string) *string    { return &s }
func readTemplate() []byte {
	return []byte(fmt.Sprintf(`{"response":{"id":9007199254740993,"id_s":"9007199254740993","vehicle_id":1,"vin":%q,"state":"asleep","drive_state":{"timestamp":1,"speed":99,"power":99,"latitude":37.4,"longitude":-122.1,"native_latitude":37.4,"native_longitude":-122.1},"charge_state":{"timestamp":1,"battery_level":99,"charger_power":99,"charge_energy_added":99,"charging_state":"Charging"},"climate_state":{"timestamp":1,"inside_temp":99},"vehicle_state":{"timestamp":1,"odometer":99,"df":0,"dr":0,"pf":0,"pr":0,"ft":0,"rt":0,"software_update":{"status":""},"car_version":"synthetic"},"gui_settings":{"gui_distance_units":"mi/hr"},"vehicle_config":{"car_type":"model3"}}}`, testVIN))
}
func readSnapshot(now time.Time) telemetrySnapshot {
	start := now.Add(-time.Hour)
	s := telemetrySnapshot{VIN: testVIN, Digest: telemetryDigest(testVIN), APIDigest: telemetryDigest(testVIN), Generation: "synthetic-generation", Started: start, Seen: now, CaughtUp: now, Status: "CONNECTED", ConnectedAt: start, ReceivedAt: start, Sign: "discharge_positive", ChargeStart: now.Add(-30 * time.Minute), LagRecords: new(int64)}
	s.Samples = []telemetrySample{
		{Field: "Location", At: now, Latitude: floatPtr(37.5), Longitude: floatPtr(-122.2), Unit: "deg", Quality: "ok"},
		{Field: "Gear", At: now.Add(-30 * time.Minute), Text: textPtr("ShiftStateD"), Quality: "ok"},
		{Field: "DetailedChargeState", At: now.Add(-30 * time.Minute), Text: textPtr("DetailedChargeStateDisconnected"), Quality: "ok"},
	}
	return s
}
func fieldMap(t *testing.T, s telemetrySnapshot, now time.Time) map[string]telemetrySample {
	t.Helper()
	f, ok := s.fields(testVIN, now)
	if !ok {
		t.Fatal("no fresh fields")
	}
	return f
}
func overlayFixture(t *testing.T, s telemetrySnapshot, now time.Time) map[string]any {
	t.Helper()
	e, _, ok := telemetryTemplate(readTemplate(), "1")
	if !ok || !overlayTelemetry(e, fieldMap(t, s, now), s.Sign, s.ChargeStart) {
		t.Fatal("overlay failed")
	}
	return e["response"].(map[string]any)
}
func TestTelemetryMappingAndUnits(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Millisecond)
	s := readSnapshot(now)
	values := []struct {
		field, unit string
		n           float64
	}{
		{"VehicleSpeed", "km/h", 80.4672}, {"GpsHeading", "deg", 90}, {"Odometer", "km", 16093.44},
		{"BatteryLevel", "%", 70.2}, {"Soc", "%", 68.8}, {"RatedRange", "km", 321.8688},
		{"IdealBatteryRange", "mi", 210}, {"EstBatteryRange", "mi", 190}, {"ChargeLimitSoc", "%", 80},
		{"TimeToFullCharge", "min", 90}, {"ChargerVoltage", "V", 240}, {"ChargeAmps", "A", 32},
		{"InsideTemp", "F", 68}, {"OutsideTemp", "C", 15}, {"PackVoltage", "V", 400}, {"PackCurrent", "A", 50},
		{"ACChargingPower", "kW", 7.2}, {"DCChargingPower", "kW", 0}, {"DCChargingEnergyIn", "kWh", 12.5},
	}
	for _, v := range values {
		s.Samples = append(s.Samples, telemetrySample{Field: v.field, At: now, Num: floatPtr(v.n), Unit: v.unit, Quality: "ok", Payload: "same"})
	}
	r := overlayFixture(t, s, now)
	d, c, v, cl := r["drive_state"].(map[string]any), r["charge_state"].(map[string]any), r["vehicle_state"].(map[string]any), r["climate_state"].(map[string]any)
	for key, want := range map[string]int64{"speed": 50, "heading": 90, "power": 20} {
		if d[key] != want {
			t.Errorf("drive %s=%v", key, d[key])
		}
	}
	if d["shift_state"] != "D" || d["latitude"] != 37.5 || d["native_latitude"] != nil {
		t.Fatal("drive mapping")
	}
	if math.Abs(v["odometer"].(float64)-10000) > 1e-8 || math.Abs(c["battery_range"].(float64)-200) > 1e-8 {
		t.Fatal("distance conversion")
	}
	if c["usable_battery_level"] != int64(69) || c["battery_level"] != int64(70) || c["time_to_full_charge"] != 1.5 || cl["inside_temp"] != float64(20) || c["charger_power"] != int64(7) || c["charge_energy_added"] != 12.5 {
		t.Fatal("charge/climate mapping")
	}
	if r["id"] != json.Number("9007199254740993") || r["state"] != "online" {
		t.Fatal("identity precision/state")
	}
	for _, section := range []string{"drive_state", "charge_state", "climate_state", "vehicle_state"} {
		if r[section].(map[string]any)["timestamp"] != now.UnixMilli() {
			t.Fatal("timestamp", section)
		}
	}
}
func TestTelemetryFreshnessBindingAndContinuity(t *testing.T) {
	now := time.Now().UTC()
	cases := map[string]func(*telemetrySnapshot){
		"stale":          func(s *telemetrySnapshot) { s.Samples[0].At = now.Add(-91 * time.Second) },
		"future":         func(s *telemetrySnapshot) { s.Samples[0].At = now.Add(time.Second) },
		"receiver stale": func(s *telemetrySnapshot) { s.Seen = now.Add(-91 * time.Second) },
		"consumer lag":   func(s *telemetrySnapshot) { n := int64(1); s.LagRecords = &n },
		"consumer stale": func(s *telemetrySnapshot) { s.CaughtUp = now.Add(-91 * time.Second) },
		"disconnected":   func(s *telemetrySnapshot) { s.Status = "DISCONNECTED" },
		"unknown":        func(s *telemetrySnapshot) { s.Status = "UNKNOWN" },
		"receiver restart": func(s *telemetrySnapshot) {
			s.Started = now.Add(-time.Minute)
			s.ReceivedAt = s.Started.Add(-time.Nanosecond)
		},
		"missing generation":   func(s *telemetrySnapshot) { s.Generation = "" },
		"binding mismatch":     func(s *telemetrySnapshot) { s.Digest = "mismatch" },
		"API binding mismatch": func(s *telemetrySnapshot) { s.APIDigest = "mismatch" },
		"wrong car":            func(s *telemetrySnapshot) { s.VIN = "" },
		"gap":                  func(s *telemetrySnapshot) { s.GapEnd = now.Add(time.Second) },
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			s := readSnapshot(now)
			change(&s)
			if _, ok := s.fields(testVIN, now); ok {
				t.Fatal("accepted unsafe snapshot")
			}
		})
	}
	s := readSnapshot(now)
	s.Samples[0].At = now.Add(-90 * time.Second)
	if _, ok := s.fields(testVIN, now); !ok {
		t.Fatal("inclusive threshold")
	}
	// Old unchanged enums remain current only across the proven continuous link.
	s = readSnapshot(now)
	s.GapEnd = now.Add(-time.Minute)
	f, ok := s.fields(testVIN, now)
	if !ok || len(f) != 1 {
		t.Fatal("pre-gap fields carried")
	}
	e, _, _ := telemetryTemplate(readTemplate(), "1")
	if overlayTelemetry(e, f, s.Sign, s.ChargeStart) {
		t.Fatal("missing gear used cache")
	}
}
func TestTelemetryInvalidAndUnknownValues(t *testing.T) {
	now := time.Now().UTC()
	s := readSnapshot(now)
	s.Samples = append(s.Samples,
		telemetrySample{Field: "BatteryLevel", At: now, Num: floatPtr(50), Unit: "%", Invalid: true, Quality: "invalid"},
		telemetrySample{Field: "VehicleSpeed", At: now, Num: floatPtr(60), Unit: "mph", Quality: "conflict"},
		telemetrySample{Field: "InsideTemp", At: now, Num: floatPtr(math.NaN()), Unit: "C", Quality: "ok"},
		telemetrySample{Field: "Odometer", At: now, Num: floatPtr(100), Unit: "unknown", Quality: "ok"},
		telemetrySample{Field: "PackCurrent", At: now, Num: floatPtr(40), Unit: "A", Quality: "ok", Payload: "one"},
		telemetrySample{Field: "PackVoltage", At: now, Num: floatPtr(400), Unit: "V", Quality: "ok", Payload: "two"})
	r := overlayFixture(t, s, now)
	for section, keys := range map[string][]string{"drive_state": {"speed", "power"}, "charge_state": {"battery_level", "charger_power", "charge_energy_added"}, "climate_state": {"inside_temp"}, "vehicle_state": {"odometer"}} {
		for _, key := range keys {
			if r[section].(map[string]any)[key] != nil {
				t.Fatal("invalid cache refreshed", key)
			}
		}
	}
	for _, bad := range []string{"ShiftStateUnknown", "ShiftStateSNA"} {
		s.Samples[1].Text = textPtr(bad)
		e, _, _ := telemetryTemplate(readTemplate(), "1")
		if overlayTelemetry(e, fieldMap(t, s, now), s.Sign, s.ChargeStart) {
			t.Fatal("unknown gear")
		}
	}
	if _, _, ok := telemetryTemplate(readTemplate(), "2"); ok {
		t.Fatal("request identity mismatch")
	}
}
func TestTelemetryDrivingChargingEnums(t *testing.T) {
	now := time.Now().UTC()
	for _, gear := range []string{"D", "R", "N", "P"} {
		for _, state := range []string{"Disconnected", "NoPower", "Starting", "Charging", "Complete", "Stopped"} {
			s := readSnapshot(now)
			s.Samples[1].Text = textPtr("ShiftState" + gear)
			s.Samples[2].Text = textPtr("DetailedChargeState" + state)
			r := overlayFixture(t, s, now)
			if r["drive_state"].(map[string]any)["shift_state"] != gear || r["charge_state"].(map[string]any)["charging_state"] != state {
				t.Fatal("enum mapping")
			}
		}
	}
}
func TestTelemetryCollectorZeroCostAndFallback(t *testing.T) {
	now := time.Now().UTC()
	for _, scenario := range []string{"fresh", "summary", "off", "stale", "invalid", "binding", "db error", "account changed"} {
		t.Run(scenario, func(t *testing.T) {
			var calls atomic.Int32
			s, store, up := collectorFixture(t, func(w http.ResponseWriter, r *http.Request) { calls.Add(1); w.Write(readTemplate()) })
			authorize(t, store, up.URL)
			s.c.TelemetryReads = true
			s.collector.clock = func() time.Time { return now }
			reader := &fakeTelemetryReader{snap: readSnapshot(now)}
			s.telemetryReader = reader
			// Bootstrap from a genuine successful response, even with a query key.
			key := "/api/1/vehicles/1/vehicle_data?endpoints=drive_state%3Bcharge_state"
			status, base, _ := s.collect(context.Background(), key, "1")
			if status != 200 || calls.Load() != 1 {
				t.Fatal("bootstrap")
			}
			before := s.usage(now)
			// Cached 408 does not destroy the last successful data template.
			s.collector.cache[key] = cached{status: 408, body: []byte(`{"error":"vehicle unavailable"}`), at: now}
			switch scenario {
			case "summary":
				key = "/api/1/vehicles/1"
			case "off":
				s.c.TelemetryReads = false
			case "stale":
				reader.snap.Samples[0].At = now.Add(-91 * time.Second)
			case "invalid":
				reader.snap.Samples[0].Invalid = true
			case "binding":
				reader.snap.Digest = "mismatch"
			case "db error":
				reader.err = errors.New("synthetic unavailable")
			case "account changed":
				reader.during = func() { s.oauth.account.Add(1) }
			}
			status, body, _ := s.collect(context.Background(), key, "1")
			if calls.Load() != 1 || s.usage(now) != before {
				t.Fatal("telemetry billed/called upstream")
			}
			if scenario == "fresh" || scenario == "summary" {
				if status != 200 || string(body) == string(base) {
					t.Fatal("telemetry not served")
				}
			} else if scenario == "account changed" {
				if status != 503 {
					t.Fatal("account fence")
				}
			} else {
				if status != 408 || string(body) != `{"error":"vehicle unavailable"}` {
					t.Fatal("fallback changed", status)
				}
			}
			if scenario == "off" && reader.calls != 0 {
				t.Fatal("flag off queried DB")
			}
		})
	}
}
func TestTelemetryFlagOffByteIdentical(t *testing.T) {
	s, store, up := collectorFixture(t, func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(" {\"response\": {\"state\": \"asleep\"}}\n"))
	})
	authorize(t, store, up.URL)
	reader := &fakeTelemetryReader{snap: readSnapshot(time.Now())}
	s.telemetryReader = reader
	for i := 0; i < 2; i++ {
		status, body, _ := s.collect(context.Background(), "/api/1/vehicles/1", "1")
		if status != 200 || string(body) != " {\"response\": {\"state\": \"asleep\"}}\n" {
			t.Fatal("changed bytes")
		}
	}
	if reader.calls != 0 {
		t.Fatal("DB touched")
	}
}

func TestTelemetryChargeSessionFence(t *testing.T) {
	now := time.Now().UTC()
	for _, state := range []string{"Starting", "Charging"} {
		t.Run(state, func(t *testing.T) {
			s := readSnapshot(now)
			s.Samples[1].Text = textPtr("ShiftStateP")
			s.Samples[2].Text = textPtr("DetailedChargeState" + state)
			s.Samples[2].At = now.Add(-time.Second)
			s.ChargeStart = s.Samples[2].At
			s.Samples = append(s.Samples,
				telemetrySample{Field: "DCChargingEnergyIn", At: now.Add(-time.Minute), Num: floatPtr(40), Unit: "kWh", Quality: "ok"},
				telemetrySample{Field: "DCChargingPower", At: now.Add(-time.Minute), Num: floatPtr(150), Unit: "kW", Quality: "ok"},
				telemetrySample{Field: "ACChargingPower", At: now, Num: floatPtr(7), Unit: "kW", Quality: "ok"})
			r := overlayFixture(t, s, now)
			c := r["charge_state"].(map[string]any)
			if c["charge_energy_added"] != nil || c["charger_power"] != int64(7) {
				t.Fatal("previous charge values carried", c)
			}
			// A completed session with no counter update cannot reuse old energy.
			s.Samples[2].Text = textPtr("DetailedChargeStateComplete")
			r = overlayFixture(t, s, now)
			if r["charge_state"].(map[string]any)["charge_energy_added"] != nil {
				t.Fatal("old energy resurrected at completion")
			}
			s.Samples[2].Text = textPtr("DetailedChargeState" + state)
			s.Samples[3].At = now
			s.Samples[3].Num = floatPtr(0.25)
			r = overlayFixture(t, s, now)
			if r["charge_state"].(map[string]any)["charge_energy_added"] != 0.25 {
				t.Fatal("current session energy lost")
			}
			// Completion retains the final reading from this session, before Complete.
			s.Samples[2].Text = textPtr("DetailedChargeStateComplete")
			s.Samples[2].At = now
			s.Samples[3].At = now.Add(-time.Second)
			r = overlayFixture(t, s, now)
			if r["charge_state"].(map[string]any)["charge_energy_added"] != 0.25 {
				t.Fatal("closing energy lost")
			}
		})
	}
}
func TestTelemetrySummaryRequiresUsableData(t *testing.T) {
	now := time.Now().UTC()
	for _, bad := range []string{"Location", "Gear", "DetailedChargeState"} {
		t.Run(bad, func(t *testing.T) {
			s, store, up := collectorFixture(t, func(w http.ResponseWriter, r *http.Request) { t.Fatal("unexpected upstream") })
			authorize(t, store, up.URL)
			s.c.TelemetryReads = true
			s.collector.account = s.oauth.Account()
			s.collector.clock = func() time.Time { return now }
			s.collector.data = map[string]cached{"1": {status: 200, body: readTemplate(), at: now}}
			body := []byte(`{"response":{"state":"asleep"}}`)
			s.collector.cache["/api/1/vehicles/1"] = cached{status: 200, body: body, at: now}
			snap := readSnapshot(now)
			for i := range snap.Samples {
				if snap.Samples[i].Field == bad {
					snap.Samples[i].Invalid = true
				}
			}
			snap.Samples = append(snap.Samples, telemetrySample{Field: "InsideTemp", At: now, Num: floatPtr(20), Unit: "C", Quality: "ok"})
			s.telemetryReader = &fakeTelemetryReader{snap: snap}
			status, got, _ := s.collect(context.Background(), "/api/1/vehicles/1", "1")
			if status != 200 || string(got) != string(body) {
				t.Fatal("summary advertised unusable telemetry")
			}
		})
	}
}
func TestTelemetryUnsupportedTemplateFields(t *testing.T) {
	now := time.Now().UTC()
	s := readSnapshot(now)
	e, _, _ := telemetryTemplate(readTemplate(), "1")
	r := e["response"].(map[string]any)
	for section, keys := range map[string][]string{"vehicle_state": {"is_user_present", "locked", "sentry_mode", "service_mode", "tpms_soft_warning_fl"}, "climate_state": {"is_preconditioning", "is_climate_on", "battery_heater", "is_front_defroster_on"}, "charge_state": {"battery_heater_on"}} {
		for _, key := range keys {
			r[section].(map[string]any)[key] = true
		}
	}
	r["vehicle_state"].(map[string]any)["tpms_pressure_fl"] = 99
	if !overlayTelemetry(e, fieldMap(t, s, now), s.Sign, s.ChargeStart) {
		t.Fatal("overlay")
	}
	for section, keys := range map[string][]string{"vehicle_state": {"is_user_present", "locked", "sentry_mode", "service_mode", "tpms_soft_warning_fl", "tpms_pressure_fl"}, "climate_state": {"is_preconditioning", "is_climate_on", "battery_heater", "is_front_defroster_on"}, "charge_state": {"battery_heater_on"}} {
		for _, key := range keys {
			if r[section].(map[string]any)[key] != nil {
				t.Fatal("stale flag refreshed", key)
			}
		}
	}
	for _, key := range []string{"df", "dr", "pf", "pr", "ft", "rt"} {
		e, _, _ = telemetryTemplate(readTemplate(), "1")
		e["response"].(map[string]any)["vehicle_state"].(map[string]any)[key] = json.Number("1")
		if overlayTelemetry(e, fieldMap(t, s, now), s.Sign, s.ChargeStart) {
			t.Fatal("open closure template served", key)
		}
	}
	e, _, _ = telemetryTemplate(readTemplate(), "1")
	e["response"].(map[string]any)["vehicle_state"].(map[string]any)["software_update"] = map[string]any{"status": "installing"}
	if overlayTelemetry(e, fieldMap(t, s, now), s.Sign, s.ChargeStart) {
		t.Fatal("active update template served")
	}
	f := false
	tr := true
	s.Samples = append(s.Samples, telemetrySample{Field: "Locked", At: now, Bool: &f, Quality: "ok"}, telemetrySample{Field: "SentryMode", At: now, Bool: &tr, Quality: "ok"}, telemetrySample{Field: "TpmsPressureFl", At: now, Num: floatPtr(2.5), Unit: "bar", Quality: "ok"}, telemetrySample{Field: "Version", At: now, Text: textPtr("synthetic-new"), Quality: "ok"})
	r = overlayFixture(t, s, now)
	v := r["vehicle_state"].(map[string]any)
	if v["locked"] != false || v["sentry_mode"] != true || v["tpms_pressure_fl"] != 2.5 || v["car_version"] != "synthetic-new" {
		t.Fatal("vehicle telemetry not mapped")
	}
}
