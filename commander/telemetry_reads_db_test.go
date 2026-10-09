package commander

import (
	"context"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Opt-in, disposable local database only. CI supplies its own Postgres service.
// Never point this test at TeslaMate or an operator database.
func TestTelemetryReadOnlyDatabase(t *testing.T) {
	dsn := os.Getenv("COMMANDER_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("disposable local Postgres not configured")
	}
	u, err := url.Parse(dsn)
	if err != nil || (u.Hostname() != "127.0.0.1" && u.Hostname() != "localhost") || u.Path != "/commander_telemetry_test" {
		t.Fatal("test requires the disposable loopback commander_telemetry_test database")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	admin, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal("fixture database unavailable")
	}
	defer admin.Close(ctx)
	// Apply actual migrations and the exact least-privilege operator script.
	_, err = admin.Exec(ctx, `CREATE TABLE public.cars (id integer PRIMARY KEY,vin text UNIQUE NOT NULL)`)
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"../deploy/telemetry/sql/001_volta_telemetry.sql", "../deploy/telemetry/sql/002_api_series.sql", "../deploy/commander/telemetry-reader.sql"} {
		sql, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = admin.Exec(ctx, string(sql)); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now().UTC().Truncate(time.Millisecond)
	start := now.Add(-time.Minute)
	if _, err = admin.Exec(ctx, `INSERT INTO public.cars VALUES (1,$1);`, testVIN); err != nil {
		t.Fatal("seed car")
	}
	if _, err = admin.Exec(ctx, `INSERT INTO volta_telemetry.vehicle_bindings VALUES (1,$1,now())`, telemetryDigest(testVIN)); err != nil {
		t.Fatal(err)
	}
	if _, err = admin.Exec(ctx, `INSERT INTO volta_telemetry.stream_health (id,receiver_generation,receiver_started_at,receiver_seen_at,consumer_started_at,caught_up_at,lag_records,updated_at) VALUES (1,'synthetic',$1,$2,$1,$2,0,$2)`, start, now); err != nil {
		t.Fatal(err)
	}
	if _, err = admin.Exec(ctx, `INSERT INTO volta_telemetry.connectivity VALUES (1,'synthetic','CONNECTED',$1,'',$1)`, start); err != nil {
		t.Fatal(err)
	}
	for _, sample := range readSnapshot(now).Samples {
		if sample.At.Before(start) {
			sample.At = start
		}
		if _, err = admin.Exec(ctx, `INSERT INTO volta_telemetry.latest_samples (vehicle_id,field,source_ts,received_at,value_text,latitude,longitude,invalid,quality,source_unit,payload_id) VALUES (1,$1,$2,$2,$3,$4,$5,false,'ok',$6,'synthetic')`, sample.Field, sample.At, sample.Text, sample.Latitude, sample.Longitude, sample.Unit); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = admin.Exec(ctx, `INSERT INTO volta_telemetry.sessions
	 (vehicle_id,kind,start_ts,end_ts,start_reason,end_reason,membership,payloads)
	 VALUES (1,'charge',$1,$2,'charge_state','charge_state','complete',3)`, start, now); err != nil {
		t.Fatal(err)
	}
	u.User = url.User("volta_commander_reader")
	db, err := newTelemetryDB(u.String())
	if err != nil {
		t.Fatal("reader configuration")
	}
	defer db.pool.Close()
	snap, err := db.Read(ctx, testVIN)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := snap.fields(testVIN, now); !ok {
		t.Fatal("real query rejected fixture")
	}
	if !snap.ChargeStart.Equal(start) {
		t.Fatal("derived session boundary missing")
	}
	if len(snap.Samples) != 3 {
		t.Fatal("latest query incomplete")
	}
	// Prove role grants, independently of default_transaction_read_only.
	conn, err := db.pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	if _, err = conn.Exec(ctx, `SET default_transaction_read_only=off`); err != nil {
		t.Fatal(err)
	}
	for _, query := range []string{`SELECT raw FROM volta_telemetry.records`, `UPDATE volta_telemetry.latest_samples SET invalid=true`, `UPDATE public.cars SET vin='synthetic'`} {
		if _, err = conn.Exec(ctx, query); err == nil {
			t.Fatal("reader role permits forbidden operation")
		}
	}
	if _, err = conn.Exec(ctx, `SET default_transaction_read_only=on`); err != nil {
		t.Fatal(err)
	}
	if _, err = admin.Exec(ctx, `UPDATE volta_telemetry.vehicle_bindings SET vin_digest=$1 WHERE vehicle_id=1`, telemetryDigest("synthetic")); err != nil {
		t.Fatal(err)
	}
	snap, err = db.Read(ctx, testVIN)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := snap.fields(testVIN, now); ok {
		t.Fatal("DB binding mismatch accepted")
	}
}
