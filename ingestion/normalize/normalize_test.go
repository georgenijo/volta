package normalize

import (
	"math"
	"strconv"
	"testing"
	"time"

	"github.com/georgenijo/volta/ingestion/internal/testvin"
	"github.com/georgenijo/volta/ingestion/vehicles"
	"github.com/teslamotors/fleet-telemetry/protos"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

var t0 = time.Date(2026, 10, 8, 17, 0, 0, 0, time.UTC)

func norm(t *testing.T) *Normalizer {
	t.Helper()
	a, err := vehicles.Parse(testvin.Mapping)
	if err != nil {
		t.Fatal(err)
	}
	return New("tesla_telemetry", a)
}

// rec builds a record exactly as the receiver produces it: key, vin header
// and payload VIN all come from the client certificate.
func rec(vin string, created time.Time, data ...*protos.Datum) Record {
	b, _ := proto.Marshal(&protos.Payload{Vin: vin, CreatedAt: timestamppb.New(created), Data: data})
	return Record{
		Topic: "tesla_telemetry_V", Key: []byte(vin), Value: b,
		Headers: map[string]string{
			"vin": vin, "txtype": "V", "txid": "tx-1",
			"receivedat":            strconv.FormatInt(created.Add(2*time.Second).UnixMilli(), 10),
			"device_client_version": "1.3.0",
		},
	}
}

func num(f protos.Field, v float64) *protos.Datum {
	return &protos.Datum{Key: f, Value: &protos.Value{Value: &protos.Value_DoubleValue{DoubleValue: v}}}
}

func reason(t *testing.T, err error) string {
	t.Helper()
	r, ok := IsRejection(err)
	if !ok {
		t.Fatalf("expected rejection, got %v", err)
	}
	return r
}

func TestAcceptsRegisteredVehicle(t *testing.T) {
	m, err := norm(t).Normalize(rec(testvin.A, t0, num(protos.Field_VehicleSpeed, 42)))
	if err != nil {
		t.Fatal(err)
	}
	if m.VehicleID != 1 || !m.SourceTS.Equal(t0) || len(m.Samples) != 1 || *m.Samples[0].Num != 42 || m.Samples[0].SourceUnit != "mph" {
		t.Fatalf("unexpected message %+v", m)
	}
	if m.ClientVersion != "1.3.0" || m.SignalCount() != 1 {
		t.Fatalf("metadata %+v", m)
	}
}

func TestVINBindingAndSpoofing(t *testing.T) {
	n := norm(t)
	// Unregistered (valid Tesla cert, not on the allowlist).
	if _, err := n.Normalize(rec(testvin.Rogue, t0, num(protos.Field_Soc, 50))); reason(t, err) != ReasonUnregistered {
		t.Fatal("unregistered VIN accepted")
	}
	// Payload claims another registered car.
	r := rec(testvin.A, t0, num(protos.Field_Soc, 50))
	b, _ := proto.Marshal(&protos.Payload{Vin: testvin.B, CreatedAt: timestamppb.New(t0), Data: []*protos.Datum{num(protos.Field_Soc, 50)}})
	r.Value = b
	if _, err := n.Normalize(r); reason(t, err) != ReasonVINMismatch {
		t.Fatal("payload VIN spoof accepted")
	}
	// Header differs from key.
	r = rec(testvin.A, t0, num(protos.Field_Soc, 50))
	r.Headers["vin"] = testvin.B
	if _, err := n.Normalize(r); reason(t, err) != ReasonVINMismatch {
		t.Fatal("header VIN spoof accepted")
	}
	// Missing key.
	r = rec(testvin.A, t0, num(protos.Field_Soc, 50))
	r.Key = nil
	if _, err := n.Normalize(r); reason(t, err) != ReasonVINMismatch {
		t.Fatal("keyless record accepted")
	}
	// Rejection text never contains the VIN.
	_, err := n.Normalize(rec(testvin.Rogue, t0, num(protos.Field_Soc, 50)))
	if s := err.Error(); s != "telemetry record rejected: unregistered_vin" {
		t.Fatalf("rejection text %q", s)
	}
}

func TestTopicAndHeaders(t *testing.T) {
	n := norm(t)
	r := rec(testvin.A, t0, num(protos.Field_Soc, 50))
	r.Topic = "tesla_telemetry_alerts"
	if _, err := n.Normalize(r); reason(t, err) != ReasonUnknownTopic {
		t.Fatal("alerts topic accepted")
	}
	r = rec(testvin.A, t0, num(protos.Field_Soc, 50))
	r.Headers["txtype"] = "connectivity"
	if _, err := n.Normalize(r); reason(t, err) != ReasonBadHeaders {
		t.Fatal("txtype mismatch accepted")
	}
}

func TestTimestampUnits(t *testing.T) {
	n := norm(t)
	// receivedat in seconds instead of ms decodes to 1970: refuse.
	r := rec(testvin.A, t0, num(protos.Field_Soc, 50))
	r.Headers["receivedat"] = strconv.FormatInt(t0.Unix(), 10)
	if _, err := n.Normalize(r); reason(t, err) != ReasonReceivedUnit {
		t.Fatal("seconds receivedat accepted")
	}
	// created_at missing.
	b, _ := proto.Marshal(&protos.Payload{Vin: testvin.A, Data: []*protos.Datum{num(protos.Field_Soc, 50)}})
	r = rec(testvin.A, t0)
	r.Value = b
	if _, err := n.Normalize(r); reason(t, err) != ReasonTimestampMissing {
		t.Fatal("missing created_at accepted")
	}
	// created_at in the future beyond skew (e.g. ms written as seconds).
	r = rec(testvin.A, t0, num(protos.Field_Soc, 50))
	r.Headers["receivedat"] = strconv.FormatInt(t0.Add(-time.Hour).UnixMilli(), 10)
	if _, err := n.Normalize(r); reason(t, err) != ReasonTimestampRange {
		t.Fatal("future created_at accepted")
	}
	// Too old.
	r = rec(testvin.A, t0.Add(-40*24*time.Hour), num(protos.Field_Soc, 50))
	r.Headers["receivedat"] = strconv.FormatInt(t0.UnixMilli(), 10)
	if _, err := n.Normalize(r); reason(t, err) != ReasonTooOld {
		t.Fatal("stale created_at accepted")
	}
	// Buffered replay inside the window keeps its own source time.
	old := t0.Add(-6 * time.Hour)
	r = rec(testvin.A, old, num(protos.Field_Soc, 50))
	r.Headers["receivedat"] = strconv.FormatInt(t0.UnixMilli(), 10)
	m, err := n.Normalize(r)
	if err != nil || !m.SourceTS.Equal(old) || !m.ReceivedAt.Equal(t0) {
		t.Fatalf("replay times %v %v %v", m, err, old)
	}
}

func TestDatumDecoding(t *testing.T) {
	n := norm(t)
	loc := func(lat, lon float64) *protos.Datum {
		return &protos.Datum{Key: protos.Field_Location, Value: &protos.Value{Value: &protos.Value_LocationValue{LocationValue: &protos.LocationValue{Latitude: lat, Longitude: lon}}}}
	}
	m, err := n.Normalize(rec(testvin.A, t0,
		&protos.Datum{Key: protos.Field_Gear, Value: &protos.Value{Value: &protos.Value_ShiftStateValue{ShiftStateValue: protos.ShiftState_ShiftStateD}}},
		&protos.Datum{Key: protos.Field_DetailedChargeState, Value: &protos.Value{Value: &protos.Value_DetailedChargeStateValue{DetailedChargeStateValue: protos.DetailedChargeStateValue_DetailedChargeStateCharging}}},
		&protos.Datum{Key: protos.Field_PackCurrent, Value: &protos.Value{Value: &protos.Value_Invalid{Invalid: true}}},
		&protos.Datum{Key: protos.Field_Odometer, Value: &protos.Value{Value: &protos.Value_StringValue{StringValue: "12345.6"}}},
		&protos.Datum{Key: protos.Field_Version, Value: &protos.Value{Value: &protos.Value_StringValue{StringValue: "2026.27.11"}}},
		&protos.Datum{Key: protos.Field_Locked, Value: &protos.Value{Value: &protos.Value_BooleanValue{BooleanValue: true}}},
		num(protos.Field_PackVoltage, math.NaN()),
		loc(37.77, -122.42),
		&protos.Datum{Key: protos.Field_VehicleName, Value: &protos.Value{Value: &protos.Value_StringValue{StringValue: "Friday"}}},
	))
	if err != nil {
		t.Fatal(err)
	}
	by := map[string]Sample{}
	for _, s := range m.Samples {
		by[s.Field] = s
	}
	if g := by["Gear"]; g.Text == nil || *g.Text != "ShiftStateD" || g.Invalid {
		t.Errorf("gear %+v", g)
	}
	if c := by["DetailedChargeState"]; c.Text == nil || *c.Text != "DetailedChargeStateCharging" {
		t.Errorf("charge state %+v", c)
	}
	if p := by["PackCurrent"]; !p.Invalid || p.Num != nil {
		t.Errorf("invalid not preserved %+v", p)
	}
	if o := by["Odometer"]; o.Num == nil || *o.Num != 12345.6 {
		t.Errorf("numeric string %+v", o)
	}
	if v := by["Version"]; v.Text == nil || *v.Text != "2026.27.11" {
		t.Errorf("version %+v", v)
	}
	if l := by["Locked"]; l.Bool == nil || !*l.Bool {
		t.Errorf("locked %+v", l)
	}
	if v := by["PackVoltage"]; !v.Invalid {
		t.Errorf("NaN must be invalid %+v", v)
	}
	if l := by["Location"]; l.Lat == nil || *l.Lat != 37.77 || *l.Lon != -122.42 {
		t.Errorf("location %+v", l)
	}
	// VehicleName is not registered: billed, counted, not stored.
	if _, ok := by["VehicleName"]; ok || m.IgnoredFields != 1 || m.SignalCount() != 9 {
		t.Errorf("ignored %d signals %d", m.IgnoredFields, m.SignalCount())
	}

	// 0,0 and out-of-range coordinates are not a fix.
	for _, c := range [][2]float64{{0, 0}, {91, 0}, {0, 181}} {
		m, err := n.Normalize(rec(testvin.A, t0, loc(c[0], c[1])))
		if err != nil || !m.Samples[0].Invalid || m.Samples[0].Lat != nil {
			t.Errorf("coord %v accepted: %+v %v", c, m, err)
		}
	}
}

func TestConnectivity(t *testing.T) {
	n := norm(t)
	b, _ := proto.Marshal(&protos.VehicleConnectivity{Vin: testvin.A, ConnectionId: "c1", Status: protos.ConnectivityEvent_CONNECTED, CreatedAt: timestamppb.New(t0), NetworkInterface: "wifi"})
	r := Record{Topic: "tesla_telemetry_connectivity", Key: []byte(testvin.A), Value: b, Headers: map[string]string{
		"vin": testvin.A, "txtype": "connectivity", "receivedat": strconv.FormatInt(t0.UnixMilli(), 10),
	}}
	m, err := n.Normalize(r)
	if err != nil {
		t.Fatal(err)
	}
	if m.Connectivity == nil || m.Connectivity.Status != "CONNECTED" || m.Connectivity.ConnectionID != "c1" || m.SignalCount() != 0 {
		t.Fatalf("connectivity %+v", m.Connectivity)
	}
}

func TestEmptyAndUndecodable(t *testing.T) {
	n := norm(t)
	if _, err := n.Normalize(rec(testvin.A, t0)); reason(t, err) != ReasonEmpty {
		t.Fatal("empty payload accepted")
	}
	r := rec(testvin.A, t0, num(protos.Field_Soc, 1))
	r.Value = []byte{0xff, 0xff, 0xff}
	if _, err := n.Normalize(r); reason(t, err) != ReasonDecode {
		t.Fatal("garbage accepted")
	}
}

func TestStrictTyping(t *testing.T) {
	n := norm(t)
	val := func(f protos.Field, v *protos.Value) *protos.Datum { return &protos.Datum{Key: f, Value: v} }
	m, err := n.Normalize(rec(testvin.A, t0,
		// Boolean where a number is registered (the R1 poison case).
		val(protos.Field_ACChargingPower, &protos.Value{Value: &protos.Value_BooleanValue{BooleanValue: true}}),
		num(protos.Field_PackCurrent, 12),
		// Text that is not a number for a numeric field.
		val(protos.Field_Soc, &protos.Value{Value: &protos.Value_StringValue{StringValue: "high"}}),
		// Wrong enum type for Gear.
		val(protos.Field_Gear, &protos.Value{Value: &protos.Value_ChargePortLatchValue{ChargePortLatchValue: protos.ChargePortLatchValue_ChargePortLatchEngaged}}),
		// Undeclared enum number of the right type.
		val(protos.Field_DetailedChargeState, &protos.Value{Value: &protos.Value_DetailedChargeStateValue{DetailedChargeStateValue: 999}}),
		// Number where a bool is registered.
		val(protos.Field_Locked, &protos.Value{Value: &protos.Value_IntValue{IntValue: 1}}),
		// Number where a string is registered.
		val(protos.Field_Version, &protos.Value{Value: &protos.Value_DoubleValue{DoubleValue: 2026}}),
		// Number where a location is registered.
		val(protos.Field_Location, &protos.Value{Value: &protos.Value_DoubleValue{DoubleValue: 1}}),
		// Infinity.
		num(protos.Field_PackVoltage, math.Inf(1)),
		// Vehicle-reported invalid.
		val(protos.Field_ChargeAmps, &protos.Value{Value: &protos.Value_Invalid{Invalid: true}}),
	))
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"ACChargingPower": QualityMalformed, "PackCurrent": QualityOK, "Soc": QualityMalformed,
		"Gear": QualityMalformed, "DetailedChargeState": QualityMalformed, "Locked": QualityMalformed,
		"Version": QualityMalformed, "Location": QualityMalformed, "PackVoltage": QualityMalformed,
		"ChargeAmps": QualityVehicleInvalid,
	}
	for _, s := range m.Samples {
		q, ok := want[s.Field]
		if !ok || s.Quality != q {
			t.Errorf("%s quality %q want %q", s.Field, s.Quality, q)
		}
		if q != QualityOK && (!s.Invalid || s.Num != nil || s.Text != nil || s.Bool != nil || s.Lat != nil) {
			t.Errorf("%s: malformed sample carries a value %+v", s.Field, s)
		}
	}
	if len(m.Samples) != len(want) || m.SignalCount() != len(want) {
		t.Fatalf("samples %d", len(m.Samples))
	}
}

func TestPayloadIdentity(t *testing.T) {
	n := norm(t)
	a, _ := n.Normalize(rec(testvin.A, t0, num(protos.Field_PackVoltage, 400)))
	b, _ := n.Normalize(rec(testvin.A, t0, num(protos.Field_PackCurrent, 50)))
	if a.PayloadID == "" || a.PayloadID == b.PayloadID {
		t.Fatalf("same created_at, different content must differ: %q %q", a.PayloadID, b.PayloadID)
	}
	// An exact retransmit (is_resend set) keeps its identity.
	r := rec(testvin.A, t0, num(protos.Field_PackVoltage, 400))
	raw, _ := proto.Marshal(&protos.Payload{Vin: testvin.A, CreatedAt: timestamppb.New(t0), IsResend: true, Data: []*protos.Datum{num(protos.Field_PackVoltage, 400)}})
	r.Value = raw
	c, err := n.Normalize(r)
	if err != nil || c.PayloadID != a.PayloadID || !c.IsResend {
		t.Fatalf("resend identity %q vs %q (%v)", c.PayloadID, a.PayloadID, err)
	}
}

func TestReceiptBillsRejectedRecords(t *testing.T) {
	n := norm(t)
	now := t0.Add(time.Hour)
	// Unregistered VIN: rejected by Normalize, still billed with its count.
	r := rec(testvin.Rogue, t0, num(protos.Field_Soc, 1), num(protos.Field_PackVoltage, 2))
	if _, err := n.Normalize(r); err == nil {
		t.Fatal("rogue accepted")
	}
	rc := n.Receipt(r, now)
	if !rc.Billable || rc.Signals == nil || *rc.Signals != 2 || !rc.Dated || !rc.ReceivedAt.Equal(t0.Add(2*time.Second)) {
		t.Fatalf("receipt %+v", rc)
	}
	// Undecodable: billable but uncountable.
	r.Value = []byte{0xff, 0xff}
	if rc := n.Receipt(r, now); !rc.Billable || rc.Signals != nil {
		t.Fatalf("garbage receipt %+v", rc)
	}
	// Bad receivedat header falls back to the broker timestamp, then now.
	r = rec(testvin.A, t0, num(protos.Field_Soc, 1))
	r.Headers["receivedat"] = "x"
	r.Timestamp = t0.Add(time.Minute)
	if rc := n.Receipt(r, now); !rc.ReceivedAt.Equal(t0.Add(time.Minute)) || !rc.Dated {
		t.Fatalf("broker time %+v", rc)
	}
	r.Timestamp = time.Time{}
	if rc := n.Receipt(r, now); !rc.ReceivedAt.Equal(now) || rc.Dated {
		t.Fatalf("fallback %+v", rc)
	}
	// Connectivity is not billed.
	r.Topic = "tesla_telemetry_connectivity"
	if rc := n.Receipt(r, now); rc.Billable || rc.Signals == nil || *rc.Signals != 0 {
		t.Fatalf("connectivity %+v", rc)
	}
}
