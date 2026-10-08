// Package contract is the JSON the Volta API returns for telemetry data.
// It extends the iOS DrivePoint (t, latitude, longitude, speedKph, powerKw,
// elevationM, batteryLevel) additively, so existing clients keep decoding
// it, and states unknowns explicitly:
//
//   - a nil value means "not reported in this payload", never "unchanged";
//   - powerKw stays nil until an operator records the PackCurrent sign
//     after the live gate (it is never inferred);
//   - routeBreakBefore marks a stream gap since the previous point: never
//     draw a line across it;
//   - every snapshot value carries its own source time, unit, unit status
//     and quality, and is "current" only while stream liveness is proven.
package contract

import (
	"math"
	"time"

	"github.com/georgenijo/volta/ingestion/fields"
)

// Source identifies telemetry-derived values next to polling data.
const Source = "fleet_telemetry"

// Time encodes as ISO-8601 UTC with milliseconds, which the iOS decoder
// accepts.
type Time time.Time

// MarshalJSON implements json.Marshaler.
func (t Time) MarshalJSON() ([]byte, error) {
	return []byte(`"` + time.Time(t).UTC().Format("2006-01-02T15:04:05.000Z") + `"`), nil
}

// DrivePoint is one same-payload trip sample.
type DrivePoint struct {
	T            Time     `json:"t"`
	Latitude     float64  `json:"latitude"`
	Longitude    float64  `json:"longitude"`
	SpeedKph     *float64 `json:"speedKph"`
	PowerKw      *float64 `json:"powerKw"`
	ElevationM   *float64 `json:"elevationM"` // telemetry has no elevation: always null
	BatteryLevel *int     `json:"batteryLevel"`
	// Additive fields.
	HeadingDeg     *float64 `json:"headingDeg"`
	PackVoltageV   *float64 `json:"packVoltageV"`
	PackCurrentA   *float64 `json:"packCurrentA"`
	PowerSign      string   `json:"powerSign"`      // unverified | discharge_positive | discharge_negative
	TripMembership string   `json:"tripMembership"` // member | partial | unknown
	// RouteBreakBefore is true when a stream gap lies between the previous
	// point and this one.
	RouteBreakBefore bool   `json:"routeBreakBefore"`
	Source           string `json:"source"`
}

// DrivePointRow is one drive_points view row.
type DrivePointRow struct {
	SourceTS        time.Time
	Latitude        float64
	Longitude       float64
	SpeedKph        *float64
	HeadingDeg      *float64
	PowerKw         *float64
	PowerSign       string
	PackVoltageV    *float64
	PackCurrentA    *float64
	BatteryLevelPct *float64
	TripMembership  string
	RouteBreak      bool
}

// FromRow maps a view row to the API point.
func FromRow(r DrivePointRow) DrivePoint {
	p := DrivePoint{
		T: Time(r.SourceTS), Latitude: r.Latitude, Longitude: r.Longitude,
		SpeedKph: round(r.SpeedKph, 2), HeadingDeg: round(r.HeadingDeg, 1),
		PackVoltageV: round(r.PackVoltageV, 2), PackCurrentA: round(r.PackCurrentA, 2),
		PowerSign: r.PowerSign, TripMembership: r.TripMembership, RouteBreakBefore: r.RouteBreak, Source: Source,
	}
	if r.PowerSign != "unverified" && r.PowerSign != "" {
		p.PowerKw = round(r.PowerKw, 3)
	}
	if p.PowerSign == "" {
		p.PowerSign = "unverified"
	}
	if p.TripMembership == "" {
		p.TripMembership = "unknown"
	}
	if r.BatteryLevelPct != nil && !math.IsNaN(*r.BatteryLevelPct) {
		b := int(math.Round(*r.BatteryLevelPct))
		p.BatteryLevel = &b
	}
	return p
}

// Freshness of a snapshot value. Fleet Telemetry sends a field only when it
// changes (by at least minimum_delta, at most once per interval), so a
// value's age alone says nothing about whether it is current. A value is
// current only while the stream has been continuously connected since the
// value was reported and that connection is proven live now (see Link);
// otherwise it is the last known value.
const (
	FreshCurrent   = "current"
	FreshLastKnown = "last_known"
)

// Value is one latest-known snapshot value. Exactly one of Num, Text,
// Bool, Lat/Lon is set unless Invalid.
type Value struct {
	Field      string   `json:"field"`
	Num        *float64 `json:"num,omitempty"`
	Text       *string  `json:"text,omitempty"`
	Bool       *bool    `json:"bool,omitempty"`
	Latitude   *float64 `json:"latitude,omitempty"`
	Longitude  *float64 `json:"longitude,omitempty"`
	Invalid    bool     `json:"invalid"`
	Quality    string   `json:"quality"`    // ok | invalid (vehicle) | malformed | conflict
	Unit       string   `json:"unit"`       // unit of Num after conversion
	UnitStatus string   `json:"unitStatus"` // doc | legacy_map | inferred | none
	SourceTs   Time     `json:"sourceTs"`
	AgeSeconds int64    `json:"ageSeconds"`
	Freshness  string   `json:"freshness"` // current | last_known
}

// LatestRow is one latest_samples row.
type LatestRow struct {
	Field     string
	SourceTS  time.Time
	Num       *float64
	Text      *string
	Bool      *bool
	Latitude  *float64
	Longitude *float64
	Invalid   bool
	Quality   string
}

// Link is the stream state used to judge freshness.
type Link struct {
	// Connected is true only when liveness is proven now: the newest
	// connectivity event is CONNECTED and belongs to the running receiver
	// generation, the receiver was observed alive recently, and the consumer
	// has caught up with the queue recently (so no newer DISCONNECTED event
	// can be waiting in it). Anything unconfirmed is not connected.
	Connected bool
	// Since is the start of the current uninterrupted connection (the end
	// of the newest gap or the newest CONNECTED event, whichever is later).
	Since time.Time
}

// Snapshot is the vehicle's latest telemetry values, each with its own time.
type Snapshot struct {
	VehicleID       int     `json:"vehicleId"`
	AsOf            Time    `json:"asOf"`
	StreamConnected bool    `json:"streamConnected"`
	Values          []Value `json:"values"`
	Source          string  `json:"source"`
}

// SnapshotFrom converts latest rows. Unknown fields are skipped; numbers are
// converted to their metric unit only when the registry declares a
// conversion.
func SnapshotFrom(vehicleID int, rows []LatestRow, link Link, now time.Time) Snapshot {
	s := Snapshot{VehicleID: vehicleID, AsOf: Time(now), StreamConnected: link.Connected, Values: []Value{}, Source: Source}
	for _, r := range rows {
		spec, ok := fields.ByName(r.Field)
		if !ok {
			continue
		}
		v := Value{
			Field: r.Field, Text: r.Text, Bool: r.Bool, Latitude: r.Latitude, Longitude: r.Longitude,
			Invalid: r.Invalid, Quality: r.Quality, Unit: spec.MetricUnit, UnitStatus: string(spec.UnitStatus),
			SourceTs: Time(r.SourceTS), AgeSeconds: int64(now.Sub(r.SourceTS) / time.Second),
			Freshness: FreshLastKnown,
		}
		if v.Quality == "" {
			v.Quality = "ok"
			if r.Invalid {
				v.Quality = "invalid"
			}
		}
		if r.Num != nil {
			n := spec.Metric(*r.Num)
			v.Num = &n
		}
		if link.Connected && !r.SourceTS.Before(link.Since) {
			v.Freshness = FreshCurrent
		}
		s.Values = append(s.Values, v)
	}
	return s
}

func round(v *float64, digits int) *float64 {
	if v == nil || math.IsNaN(*v) || math.IsInf(*v, 0) {
		return nil
	}
	p := math.Pow(10, float64(digits))
	r := math.Round(*v*p) / p
	return &r
}
