// Package normalize turns records produced by the official Fleet Telemetry
// receiver (Kafka key = VIN, value = protobuf, headers from
// telemetry.Record.Metadata) into Volta-owned samples.
//
// Rules enforced here:
//
//   - The Kafka key, the "vin" header and the payload VIN must be identical
//     and on the allowlist. The receiver sets all three from the verified
//     client certificate CN, so a mismatch means the record did not come from
//     the receiver path we configured; it is rejected, never re-bound.
//   - Every datum takes its source time from Payload.created_at. Telemetry
//     has no per-datum timestamp; a field absent from a payload is unknown at
//     that instant, never forward-filled.
//   - Datum.invalid is kept as an explicit invalid sample (value unknown),
//     not dropped and not replaced with a previous value.
//   - Timestamps are range-checked so seconds/milliseconds mix-ups and zero
//     timestamps are rejected instead of landing in 1970 or the far future.
//
// Rejections carry a reason only. They never include the VIN, the payload or
// any value.
package normalize

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/georgenijo/volta/ingestion/fields"
	"github.com/georgenijo/volta/ingestion/vehicles"
	"github.com/teslamotors/fleet-telemetry/protos"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
)

// Record is the subset of a Kafka record the normalizer needs.
type Record struct {
	Topic     string
	Partition int32
	Offset    int64
	Key       []byte
	Value     []byte
	Headers   map[string]string
	// Timestamp is the broker record timestamp (producer create time). It
	// dates billing receipts when the receivedat header is unusable.
	Timestamp time.Time
}

// TxType values Volta consumes.
const (
	TxVehicleData  = "V"
	TxConnectivity = "connectivity"
)

// Sample is one field value at the payload's source time.
type Sample struct {
	Field    string
	Num      *float64
	Text     *string
	Bool     *bool
	Lat, Lon *float64
	Invalid  bool
	// Quality explains an invalid sample: QualityVehicleInvalid when the
	// vehicle said the value is unavailable, QualityMalformed when the datum
	// did not match the field's registered type.
	Quality    string
	SourceUnit string
}

// Sample quality values. Stable strings: they are stored.
const (
	QualityOK             = "ok"
	QualityVehicleInvalid = "invalid"
	QualityMalformed      = "malformed"
)

// Connectivity is a receiver-generated connect/disconnect event. Its time is
// the receiver's clock, not the vehicle's.
type Connectivity struct {
	ConnectionID     string
	Status           string // CONNECTED | DISCONNECTED | UNKNOWN
	NetworkInterface string
}

// Message is a normalized, allowlisted record.
type Message struct {
	VehicleID     int
	TxType        string
	TxID          string
	SourceTS      time.Time
	ReceivedAt    time.Time
	IsResend      bool
	ClientVersion string
	Samples       []Sample
	// IgnoredFields counts datums for fields outside the registry. They are
	// still billed signals, so the meter counts them.
	IgnoredFields int
	Connectivity  *Connectivity
	Raw           []byte
	// PayloadID identifies the payload content independent of its Kafka
	// position and of is_resend, so an exact retransmit maps to the same
	// payload and two different payloads with the same created_at never do.
	PayloadID string
	Topic     string
	Partition int32
	Offset    int64
}

// SignalCount is the number of datums in the record (registered or not).
func (m *Message) SignalCount() int { return len(m.Samples) + m.IgnoredFields }

// Rejection reasons. Stable strings: they are stored as counter keys.
const (
	ReasonUnknownTopic     = "unknown_topic"
	ReasonBadHeaders       = "bad_headers"
	ReasonVINMismatch      = "vin_mismatch"
	ReasonUnregistered     = "unregistered_vin"
	ReasonDecode           = "decode_error"
	ReasonTimestampMissing = "timestamp_missing"
	ReasonTimestampRange   = "timestamp_out_of_range"
	ReasonReceivedUnit     = "received_at_unit"
	ReasonTooOld           = "timestamp_too_old"
	ReasonEmpty            = "empty_payload"
)

// Rejection explains why a record was not accepted. It deliberately holds no
// identifying data.
type Rejection struct {
	Reason string
}

func (r *Rejection) Error() string { return "telemetry record rejected: " + r.Reason }

func reject(reason string) (*Message, error) { return nil, &Rejection{Reason: reason} }

// Normalizer validates and decodes records.
type Normalizer struct {
	Namespace string
	Allow     *vehicles.Allowlist
	// MaxFutureSkew bounds created_at ahead of the receiver clock.
	MaxFutureSkew time.Duration
	// MaxAge bounds how old a payload may be relative to receipt. The car
	// buffers about 5000 messages, so anything older than this is not a
	// legitimate replay.
	MaxAge time.Duration
}

// New returns a Normalizer with conservative bounds.
func New(namespace string, allow *vehicles.Allowlist) *Normalizer {
	return &Normalizer{Namespace: namespace, Allow: allow, MaxFutureSkew: 5 * time.Minute, MaxAge: 30 * 24 * time.Hour}
}

var minPlausible = time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)

// TxTypeOf maps a topic name to the receiver txtype, or "".
func (n *Normalizer) TxTypeOf(topic string) string {
	prefix := n.Namespace + "_"
	if !strings.HasPrefix(topic, prefix) {
		return ""
	}
	switch t := strings.TrimPrefix(topic, prefix); t {
	case TxVehicleData, TxConnectivity:
		return t
	}
	return ""
}

// Normalize validates a record and decodes it. A *Rejection error means the
// record is permanently unacceptable (count it and move on); any other error
// never happens for well-formed input and is treated the same way by callers.
func (n *Normalizer) Normalize(r Record) (*Message, error) {
	tx := n.TxTypeOf(r.Topic)
	if tx == "" {
		return reject(ReasonUnknownTopic)
	}
	if r.Headers["txtype"] != tx {
		return reject(ReasonBadHeaders)
	}
	key := string(r.Key)
	if key == "" || r.Headers["vin"] != key {
		return reject(ReasonVINMismatch)
	}
	receivedMs, err := strconv.ParseInt(r.Headers["receivedat"], 10, 64)
	if err != nil {
		return reject(ReasonBadHeaders)
	}
	received := time.UnixMilli(receivedMs).UTC()
	// The receiver writes milliseconds. A seconds value would decode to 1970.
	if received.Before(minPlausible) {
		return reject(ReasonReceivedUnit)
	}
	vehicleID, err := n.Allow.Lookup(key)
	if err != nil {
		return reject(ReasonUnregistered)
	}
	if len(r.Value) == 0 {
		return reject(ReasonEmpty)
	}

	m := &Message{
		VehicleID:     vehicleID,
		TxType:        tx,
		TxID:          r.Headers["txid"],
		ReceivedAt:    received,
		ClientVersion: r.Headers["device_client_version"],
		Raw:           r.Value,
		Topic:         r.Topic,
		Partition:     r.Partition,
		Offset:        r.Offset,
	}

	switch tx {
	case TxVehicleData:
		var p protos.Payload
		if err := proto.Unmarshal(r.Value, &p); err != nil {
			return reject(ReasonDecode)
		}
		if p.GetVin() != key {
			return reject(ReasonVINMismatch)
		}
		if p.GetCreatedAt() == nil {
			return reject(ReasonTimestampMissing)
		}
		if rej := n.checkSource(p.GetCreatedAt().AsTime(), received); rej != "" {
			return reject(rej)
		}
		m.SourceTS = p.GetCreatedAt().AsTime().UTC()
		m.IsResend = p.GetIsResend()
		if m.PayloadID = payloadID(&p); m.PayloadID == "" {
			m.PayloadID = rawID(r.Value)
		}
		for _, d := range p.GetData() {
			spec, ok := fields.ByField(d.GetKey())
			if !ok {
				m.IgnoredFields++
				continue
			}
			m.Samples = append(m.Samples, decodeDatum(spec, d.GetValue()))
		}
		if m.SignalCount() == 0 {
			return reject(ReasonEmpty)
		}
	case TxConnectivity:
		var c protos.VehicleConnectivity
		if err := proto.Unmarshal(r.Value, &c); err != nil {
			return reject(ReasonDecode)
		}
		if c.GetVin() != key {
			return reject(ReasonVINMismatch)
		}
		if c.GetCreatedAt() == nil {
			return reject(ReasonTimestampMissing)
		}
		if rej := n.checkSource(c.GetCreatedAt().AsTime(), received); rej != "" {
			return reject(rej)
		}
		m.SourceTS = c.GetCreatedAt().AsTime().UTC()
		m.PayloadID = rawID(r.Value)
		m.Connectivity = &Connectivity{
			ConnectionID:     c.GetConnectionId(),
			Status:           strings.ToUpper(c.GetStatus().String()),
			NetworkInterface: c.GetNetworkInterface(),
		}
	}
	return m, nil
}

// Receipt is the billing view of one record, computed before (and
// independent of) validation, so rejected records are still billed.
type Receipt struct {
	// Billable is false only for connectivity records. Records on any other
	// topic are treated as billed vehicle data.
	Billable bool
	// Signals is the number of datums Tesla bills for the record, or nil when
	// the payload cannot be decoded (uncountable: the meter reports unknown).
	Signals *int
	// ReceivedAt dates the receipt: the receiver's receivedat header when it
	// is a plausible millisecond time, else the broker timestamp, else now.
	ReceivedAt time.Time
	// Dated is false when neither the header nor the broker supplied a time.
	Dated bool
}

// Receipt accounts one record for billing. It never inspects the VIN.
func (n *Normalizer) Receipt(r Record, now time.Time) Receipt {
	rc := Receipt{Billable: n.TxTypeOf(r.Topic) != TxConnectivity, ReceivedAt: now.UTC()}
	if ms, err := strconv.ParseInt(r.Headers["receivedat"], 10, 64); err == nil && !time.UnixMilli(ms).Before(minPlausible) {
		rc.ReceivedAt, rc.Dated = time.UnixMilli(ms).UTC(), true
	} else if !r.Timestamp.IsZero() && !r.Timestamp.Before(minPlausible) {
		rc.ReceivedAt, rc.Dated = r.Timestamp.UTC(), true
	}
	if !rc.Billable {
		zero := 0
		rc.Signals = &zero
		return rc
	}
	var p protos.Payload
	if len(r.Value) == 0 {
		zero := 0
		rc.Signals = &zero
		return rc
	}
	if err := proto.Unmarshal(r.Value, &p); err == nil {
		c := len(p.GetData())
		rc.Signals = &c
	}
	return rc
}

// payloadID hashes the deterministic encoding of the payload with is_resend
// cleared: a resend of the same payload has the same identity.
func payloadID(p *protos.Payload) string {
	c := proto.Clone(p).(*protos.Payload)
	c.IsResend = false
	b, err := proto.MarshalOptions{Deterministic: true}.Marshal(c)
	if err != nil {
		return ""
	}
	return rawID(b)
}

func rawID(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:16])
}

func (n *Normalizer) checkSource(src, received time.Time) string {
	if src.Before(minPlausible) || src.After(received.Add(n.MaxFutureSkew)) {
		return ReasonTimestampRange
	}
	if received.Sub(src) > n.MaxAge {
		return ReasonTooOld
	}
	return ""
}

func decodeDatum(spec fields.Spec, v *protos.Value) Sample {
	s := Sample{Field: spec.Name, SourceUnit: spec.SourceUnit}
	if v == nil || v.GetValue() == nil {
		s.Invalid, s.Quality = true, QualityVehicleInvalid
		return s
	}
	if _, ok := v.GetValue().(*protos.Value_Invalid); ok {
		s.Invalid, s.Quality = true, QualityVehicleInvalid
		return s
	}
	// Strict per-field typing: only the oneof members the registry kind
	// allows are decoded. Anything else (a boolean for a numeric field, the
	// wrong enum type, text for a bool) is a malformed sample: kept as
	// explicit unknown, never coerced and never written as a value.
	ok := false
	switch spec.Kind {
	case fields.KindNumber:
		var f float64
		switch x := v.GetValue().(type) {
		case *protos.Value_DoubleValue:
			f, ok = x.DoubleValue, true
		case *protos.Value_FloatValue:
			f, ok = float64(x.FloatValue), true
		case *protos.Value_IntValue:
			f, ok = float64(x.IntValue), true
		case *protos.Value_LongValue:
			f, ok = float64(x.LongValue), true
		case *protos.Value_StringValue:
			// Clients before 1.1 sent numbers as strings. Typed clients (Volta
			// targets 1.3) do not; a parseable numeric string is accepted,
			// anything else is malformed.
			var err error
			f, err = strconv.ParseFloat(strings.TrimSpace(x.StringValue), 64)
			ok = err == nil
		}
		if ok {
			if s.Num = finite(f); s.Num == nil {
				ok = false
			}
		}
	case fields.KindBool:
		if x, isBool := v.GetValue().(*protos.Value_BooleanValue); isBool {
			b := x.BooleanValue
			s.Bool, ok = &b, true
		}
	case fields.KindLocation:
		if x, isLoc := v.GetValue().(*protos.Value_LocationValue); isLoc {
			lat, lon := x.LocationValue.GetLatitude(), x.LocationValue.GetLongitude()
			if validCoord(lat, lon) {
				s.Lat, s.Lon, ok = &lat, &lon, true
			} else {
				// No fix: the vehicle sent a location it could not resolve.
				s.Invalid, s.Quality = true, QualityVehicleInvalid
				return s
			}
		}
	case fields.KindString:
		if x, isText := v.GetValue().(*protos.Value_StringValue); isText {
			text := x.StringValue
			s.Text, ok = &text, true
		}
	case fields.KindEnum:
		// Use the proto's own enum value name so semantics come from
		// upstream, not from a copy. The member must be the field's own enum.
		if name, num, isEnum := enumOf(v, spec.EnumOneof); isEnum {
			f := float64(num)
			s.Text, s.Num, ok = &name, &f, true
		}
	}
	if !ok {
		return Sample{Field: spec.Name, SourceUnit: spec.SourceUnit, Invalid: true, Quality: QualityMalformed}
	}
	s.Quality = QualityOK
	return s
}

// enumOf returns the enum value name and number when v carries exactly the
// expected oneof member and the number is a declared value of its enum.
func enumOf(v *protos.Value, oneof string) (string, int32, bool) {
	m := v.ProtoReflect()
	od := m.Descriptor().Oneofs().ByName("value")
	if od == nil {
		return "", 0, false
	}
	fd := m.WhichOneof(od)
	if fd == nil || fd.Kind() != protoreflect.EnumKind || string(fd.Name()) != oneof {
		return "", 0, false
	}
	num := m.Get(fd).Enum()
	ev := fd.Enum().Values().ByNumber(num)
	if ev == nil {
		return "", 0, false
	}
	return string(ev.Name()), int32(num), true
}

func finite(f float64) *float64 {
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return nil
	}
	return &f
}

func validCoord(lat, lon float64) bool {
	if math.IsNaN(lat) || math.IsNaN(lon) || lat < -90 || lat > 90 || lon < -180 || lon > 180 {
		return false
	}
	// 0,0 is what an unset LocationValue decodes to; treat it as no fix.
	return !(lat == 0 && lon == 0)
}

// IsRejection reports whether err is a Rejection and returns its reason.
func IsRejection(err error) (string, bool) {
	var r *Rejection
	if errors.As(err, &r) {
		return r.Reason, true
	}
	return "", false
}
