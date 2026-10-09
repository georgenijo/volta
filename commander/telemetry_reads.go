package commander

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"github.com/jackc/pgx/v5/pgxpool"
	"math"
	"strings"
	"time"
)

// Bounds the newest valid source observation and stream liveness. Older
// change-only values are current only within the same uninterrupted connection.
const telemetryReadMaxAge = 90 * time.Second

type telemetrySample struct {
	Field     string    `json:"field"`
	At        time.Time `json:"source_ts"`
	Num       *float64  `json:"value_num"`
	Text      *string   `json:"value_text"`
	Bool      *bool     `json:"value_bool"`
	Latitude  *float64  `json:"latitude"`
	Longitude *float64  `json:"longitude"`
	Invalid   bool      `json:"invalid"`
	Quality   string    `json:"quality"`
	Unit      string    `json:"source_unit"`
	Payload   string    `json:"payload_id"`
}
type telemetrySnapshot struct {
	VIN         string            `json:"vin"`
	Digest      string            `json:"digest"`
	APIDigest   string            `json:"api_digest"`
	Generation  string            `json:"generation"`
	Started     time.Time         `json:"started"`
	Seen        time.Time         `json:"seen"`
	CaughtUp    time.Time         `json:"caught_up"`
	LagRecords  *int64            `json:"lag_records"`
	Status      string            `json:"status"`
	ConnectedAt time.Time         `json:"connected_at"`
	ReceivedAt  time.Time         `json:"received_at"`
	GapEnd      time.Time         `json:"gap_end"`
	ChargeStart time.Time         `json:"charge_start"`
	Sign        string            `json:"sign"`
	Samples     []telemetrySample `json:"samples"`
}
type telemetryReader interface {
	Read(context.Context, string) (telemetrySnapshot, error)
}
type telemetryDB struct{ pool *pgxpool.Pool }

func newTelemetryDB(dsn string) (*telemetryDB, error) {
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	config.MaxConns = 2
	config.ConnConfig.ConnectTimeout = time.Second
	config.ConnConfig.RuntimeParams["default_transaction_read_only"] = "on"
	config.ConnConfig.RuntimeParams["statement_timeout"] = "1000"
	pool, err := pgxpool.NewWithConfig(context.Background(), config)
	if err != nil {
		return nil, err
	}
	return &telemetryDB{pool: pool}, nil
}

// One statement gives bindings, generation, connectivity and fields one MVCC
// snapshot. latest_samples' (vehicle_id,field) primary key bounds the hot read.
// No raw history or write. Ambiguous car identities fail closed.
func (db *telemetryDB) Read(ctx context.Context, vin string) (telemetrySnapshot, error) {
	var raw []byte
	err := db.pool.QueryRow(ctx, `WITH binding AS (
 SELECT c.id,c.vin,b.vin_digest,a.vin_digest AS api_digest
 FROM public.cars c JOIN volta_telemetry.vehicle_bindings b ON b.vehicle_id=c.id
 JOIN volta_telemetry.api_vehicle_bindings a ON a.vehicle_id=c.id WHERE c.vin=$1
 ) SELECT jsonb_build_object(
 'vin',b.vin,'digest',b.vin_digest,'api_digest',b.api_digest,
 'generation',h.receiver_generation,'started',h.receiver_started_at,
 'seen',h.receiver_seen_at,'caught_up',h.caught_up_at,'lag_records',h.lag_records,
 'status',link.status,'connected_at',link.source_ts,'received_at',link.received_at,
 'gap_end',(SELECT max(end_ts) FROM volta_telemetry.gaps WHERE vehicle_id=b.id AND reason IN ('disconnected','silence')),
 'sign',(SELECT sign FROM volta_telemetry.power_calibration WHERE vehicle_id=b.id),
 'charge_start',(SELECT start_ts FROM volta_telemetry.sessions
 WHERE vehicle_id=b.id AND kind='charge'
 AND start_ts <= (SELECT source_ts FROM volta_telemetry.latest_samples WHERE vehicle_id=b.id AND field='DetailedChargeState')
 AND end_ts >= (SELECT source_ts FROM volta_telemetry.latest_samples WHERE vehicle_id=b.id AND field='DetailedChargeState')
 ORDER BY start_ts DESC LIMIT 1),
 'samples',coalesce((SELECT jsonb_agg(to_jsonb(l)) FROM volta_telemetry.latest_samples l WHERE l.vehicle_id=b.id),'[]'::jsonb))
 FROM binding b CROSS JOIN volta_telemetry.stream_health h
 CROSS JOIN LATERAL (SELECT status,source_ts,received_at FROM volta_telemetry.connectivity
 WHERE vehicle_id=b.id ORDER BY source_ts DESC,received_at DESC,status DESC LIMIT 1) link
 WHERE h.id=1 AND (SELECT count(*) FROM binding)=1`, vin).Scan(&raw)
	if err != nil {
		return telemetrySnapshot{}, err
	}
	var out telemetrySnapshot
	err = json.Unmarshal(raw, &out)
	return out, err
}
func telemetryDigest(vin string) string {
	sum := sha256.Sum256([]byte("volta-telemetry-vin-binding-v1\x00" + vin))
	return hex.EncodeToString(sum[:])
}
func recent(at, now time.Time) bool {
	return !at.IsZero() && !at.After(now) && now.Sub(at) <= telemetryReadMaxAge
}
func (s telemetrySnapshot) fields(vin string, now time.Time) (map[string]telemetrySample, bool) {
	if !vinPattern.MatchString(vin) || s.VIN != vin || s.Digest != telemetryDigest(vin) || s.APIDigest != s.Digest ||
		s.Generation == "" || s.Started.IsZero() || s.Started.After(now) || !recent(s.Seen, now) || !recent(s.CaughtUp, now) ||
		(s.LagRecords == nil || *s.LagRecords != 0) || s.Status != "CONNECTED" || s.ReceivedAt.Before(s.Started) || s.ReceivedAt.After(now) || s.ConnectedAt.IsZero() || s.ConnectedAt.After(now) {
		return nil, false
	}
	since := s.ConnectedAt
	if s.Started.After(since) {
		since = s.Started
	}
	if s.GapEnd.After(since) {
		since = s.GapEnd
	}
	fields := map[string]telemetrySample{}
	var newest time.Time
	for _, v := range s.Samples {
		if v.Invalid || v.Quality != "ok" || v.At.IsZero() || v.At.After(now) || v.At.Before(since) {
			continue
		}
		fields[v.Field] = v
		if v.At.After(newest) {
			newest = v.At
		}
	}
	return fields, recent(newest, now)
}

// UseNumber keeps opaque Tesla IDs lossless (they can exceed 2^53).
func telemetryTemplate(body []byte, vehicle string) (map[string]any, string, bool) {
	var envelope map[string]any
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	if dec.Decode(&envelope) != nil {
		return nil, "", false
	}
	r, ok := envelope["response"].(map[string]any)
	if !ok {
		return nil, "", false
	}
	vin, _ := r["vin"].(string)
	if !vinPattern.MatchString(vin) {
		return nil, "", false
	}
	identity := vehicle == vin
	for _, field := range []string{"id", "id_s", "vehicle_id"} {
		switch id := r[field].(type) {
		case json.Number:
			identity = identity || string(id) == vehicle
		case string:
			identity = identity || id == vehicle
		}
	}
	if !identity {
		return nil, "", false
	}
	for _, section := range []string{"drive_state", "charge_state", "climate_state", "vehicle_state", "vehicle_config", "gui_settings"} {
		if _, ok := r[section].(map[string]any); !ok {
			return nil, "", false
		}
	}
	return envelope, vin, true
}
func (s *Service) telemetryReply(ctx context.Context, key, vehicle string, now time.Time) ([]byte, bool) {
	template, ok := s.collector.data[vehicle]
	if !ok {
		return nil, false
	}
	envelope, vin, ok := telemetryTemplate(template.body, vehicle)
	if !ok {
		return nil, false
	}
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	snap, err := s.telemetryReader.Read(ctx, vin)
	if err != nil {
		return nil, false
	} // Never log DB errors/DSNs or vehicle values.
	fields, ok := snap.fields(vin, now)
	if !ok {
		return nil, false
	}
	if !overlayTelemetry(envelope, fields, snap.Sign, snap.ChargeStart) {
		return nil, false
	}
	if !strings.Contains(key, "/vehicle_data") {
		r := envelope["response"].(map[string]any)
		for _, g := range dataGroups {
			delete(r, g)
		}
		r["state"] = "online"
		body, err := json.Marshal(envelope)
		return body, err == nil
	}
	body, err := json.Marshal(envelope)
	return body, err == nil
}

type telemetryMapping struct {
	field, section, key, unit string
	integer                   bool
}

var telemetryMappings = []telemetryMapping{
	{"VehicleSpeed", "drive_state", "speed", "mph", true}, {"GpsHeading", "drive_state", "heading", "deg", true},
	{"Odometer", "vehicle_state", "odometer", "mi", false},
	{"BatteryLevel", "charge_state", "battery_level", "%", true}, {"Soc", "charge_state", "usable_battery_level", "%", true},
	{"RatedRange", "charge_state", "battery_range", "mi", false}, {"IdealBatteryRange", "charge_state", "ideal_battery_range", "mi", false},
	{"EstBatteryRange", "charge_state", "est_battery_range", "mi", false},
	{"ChargeLimitSoc", "charge_state", "charge_limit_soc", "%", true}, {"TimeToFullCharge", "charge_state", "time_to_full_charge", "h", false},
	{"ChargerVoltage", "charge_state", "charger_voltage", "V", true}, {"ChargeAmps", "charge_state", "charger_actual_current", "A", true},
	{"TpmsPressureFl", "vehicle_state", "tpms_pressure_fl", "bar", false},
	{"TpmsPressureFr", "vehicle_state", "tpms_pressure_fr", "bar", false},
	{"TpmsPressureRl", "vehicle_state", "tpms_pressure_rl", "bar", false},
	{"TpmsPressureRr", "vehicle_state", "tpms_pressure_rr", "bar", false},
	{"InsideTemp", "climate_state", "inside_temp", "C", false}, {"OutsideTemp", "climate_state", "outside_temp", "C", false},
}

func telemetryNumber(v telemetrySample, unit string) (float64, bool) {
	if v.Num == nil || math.IsNaN(*v.Num) || math.IsInf(*v.Num, 0) {
		return 0, false
	}
	n := *v.Num
	if v.Unit == unit {
		return n, true
	}
	switch {
	case unit == "mi" && v.Unit == "km", unit == "mph" && v.Unit == "km/h":
		return n / 1.609344, true
	case unit == "C" && v.Unit == "F":
		return (n - 32) * 5 / 9, true
	case unit == "h" && v.Unit == "min":
		return n / 60, true
	}
	return 0, false
}
func overlayTelemetry(envelope map[string]any, fields map[string]telemetrySample, sign string, chargeStart time.Time) bool {
	r := envelope["response"].(map[string]any)
	drive := r["drive_state"].(map[string]any)
	charge := r["charge_state"].(map[string]any)
	gear := fields["Gear"]
	if gear.Text == nil {
		return false
	}
	shift := strings.TrimPrefix(*gear.Text, "ShiftState")
	if shift != "D" && shift != "R" && shift != "N" && shift != "P" {
		return false
	}
	state := fields["DetailedChargeState"]
	charging := ""
	if state.Text != nil {
		switch *state.Text {
		case "DetailedChargeStateDisconnected":
			charging = "Disconnected"
		case "DetailedChargeStateNoPower":
			charging = "NoPower"
		case "DetailedChargeStateStarting":
			charging = "Starting"
		case "DetailedChargeStateCharging":
			charging = "Charging"
		case "DetailedChargeStateComplete":
			charging = "Complete"
		case "DetailedChargeStateStopped":
			charging = "Stopped"
		}
	}
	if charging == "" {
		return false
	}
	loc := fields["Location"]
	if loc.Latitude == nil || loc.Longitude == nil || loc.Unit != "deg" || math.IsNaN(*loc.Latitude) || math.IsNaN(*loc.Longitude) ||
		math.Abs(*loc.Latitude) > 90 || math.Abs(*loc.Longitude) > 180 {
		return false
	}
	// Keep only parser scaffolding and static identity/version metadata.
	// Every unsupported dynamic value is unknown, rather than timestamped anew.
	vehicleState := r["vehicle_state"].(map[string]any)
	if update, ok := vehicleState["software_update"].(map[string]any); ok {
		if status, _ := update["status"].(string); status != "" {
			return false
		}
	}
	// Neither shipped profile requests door/trunk/window signals. TeslaMate
	// VehicleState.result reads these keys directly and tolerates nil; its
	// suspension guards test is_number before comparing closure values.
	// Do not retain even a closed value from an old real snapshot.
	keep := map[string]bool{"api_version": true, "car_version": true, "vehicle_name": true}
	for _, section := range []string{"drive_state", "charge_state", "climate_state", "vehicle_state"} {
		for key := range r[section].(map[string]any) {
			if section != "vehicle_state" || !keep[key] {
				r[section].(map[string]any)[key] = nil
			}
		}
	}
	// TeslaMate expects a software_update object. An empty status is its
	// parser's no-update sentinel; active update templates use normal polling.
	vehicleState["software_update"] = map[string]any{"status": ""}
	drive["latitude"], drive["longitude"], drive["gps_as_of"] = *loc.Latitude, *loc.Longitude, loc.At.Unix()
	drive["shift_state"] = shift

	charge["charging_state"] = nil
	if charging != "" {
		charge["charging_state"] = charging
	}
	for _, m := range telemetryMappings {
		v, ok := fields[m.field]
		if !ok {
			continue
		}
		n, ok := telemetryNumber(v, m.unit)
		if !ok {
			continue
		}
		if m.integer {
			r[m.section].(map[string]any)[m.key] = int64(math.Round(n))
		} else {
			r[m.section].(map[string]any)[m.key] = n
		}

	}
	// Same payload and verified polarity, as in drive_points; never infer sign.
	voltage, current := fields["PackVoltage"], fields["PackCurrent"]
	v, vok := telemetryNumber(voltage, "V")
	a, aok := telemetryNumber(current, "A")
	if vok && aok && v > 0 && voltage.Payload != "" && voltage.Payload == current.Payload && voltage.At.Equal(current.At) && (sign == "discharge_positive" || sign == "discharge_negative") {
		power := v * a / 1000
		if sign == "discharge_negative" {
			power = -power
		}
		drive["power"] = int64(math.Round(power))

	}
	// Battery-side energy is valid for AC and DC. AC input energy is not the
	// legacy battery-added counter and is deliberately not substituted.
	sessionValue := func(field string) telemetrySample {
		value := fields[field]
		floor := chargeStart
		if charging == "Starting" || charging == "Charging" {
			if floor.IsZero() {
				floor = state.At
			}
		}
		// Inactive states need a derived session covering their transition,
		// otherwise a counter from any earlier session would be ambiguous.
		if floor.IsZero() || value.At.Before(floor) {
			return telemetrySample{}
		}
		return value
	}
	if n, ok := telemetryNumber(sessionValue("DCChargingEnergyIn"), "kWh"); ok {
		charge["charge_energy_added"] = n

	}
	for _, f := range []string{"ACChargingPower", "DCChargingPower"} {
		if n, ok := telemetryNumber(sessionValue(f), "kW"); ok && n >= 0 {
			old, exists := charge["charger_power"].(int64)
			if !exists || int64(math.Round(n)) > old {
				charge["charger_power"] = int64(math.Round(n))

			}
		}
	}
	for field, key := range map[string]string{"FastChargerPresent": "fast_charger_present", "ChargePortDoorOpen": "charge_port_door_open"} {
		if v := fields[field]; v.Bool != nil {
			charge[key] = *v.Bool

		}
	}
	for field, key := range map[string]string{"Locked": "locked"} {
		if v := fields[field]; v.Bool != nil {
			vehicleState[key] = *v.Bool
		}
	}
	if sentry := fields["SentryMode"]; sentry.Text != nil {
		switch *sentry.Text {
		case "SentryModeStateOff":
			vehicleState["sentry_mode"] = false
		case "SentryModeStateIdle", "SentryModeStateArmed", "SentryModeStateAware", "SentryModeStatePanic", "SentryModeStateQuiet":
			vehicleState["sentry_mode"] = true
		}
	}
	if charging == "Starting" || charging == "Charging" {
		// These fields are required by TeslaMate.Log.Charge's changeset.
		for _, key := range []string{"battery_level", "usable_battery_level", "ideal_battery_range", "charge_energy_added", "charger_power"} {
			if charge[key] == nil {
				return false
			}
		}
	}
	if version := fields["Version"]; version.Text != nil {
		vehicleState["car_version"] = *version.Text
	}
	// Fields emit on change. Date the coherent current snapshot with its
	// newest source observation, never with wall-clock time.
	var snapshotAt time.Time
	for _, value := range fields {
		if value.At.After(snapshotAt) {
			snapshotAt = value.At
		}
	}
	for _, section := range []string{"drive_state", "charge_state", "climate_state", "vehicle_state"} {
		r[section].(map[string]any)["timestamp"] = snapshotAt.UnixMilli()
	}
	r["state"] = "online"
	return true
}

// Close releases the optional database pool after HTTP requests have drained.
func (s *Service) Close() {
	if db, ok := s.telemetryReader.(*telemetryDB); ok {
		db.pool.Close()
	}
}

func collectorDataTimestamp(body []byte) (int64, bool) {
	var envelope struct {
		Response struct {
			Drive struct {
				Timestamp json.Number `json:"timestamp"`
			} `json:"drive_state"`
		} `json:"response"`
	}
	if json.Unmarshal(body, &envelope) != nil {
		return 0, false
	}
	ts, err := envelope.Response.Drive.Timestamp.Int64()
	return ts, err == nil && ts > 0
}
