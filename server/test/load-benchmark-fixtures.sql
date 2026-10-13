\set ON_ERROR_STOP on

-- Deterministic, synthetic Bay Area history for server/scripts/benchmark-loads.sh.
-- The fixed clock used by the runner is 2026-10-13T06:00:00Z.
BEGIN;
SET LOCAL synchronous_commit = off;

INSERT INTO public.car_settings (id) VALUES (1);
INSERT INTO public.cars
  (id, eid, vid, vin, name, model, efficiency, trim_badging, exterior_color,
   settings_id, inserted_at, updated_at)
VALUES
  (1, 1001, 2001, 'SYNTHETIC000000001', 'Synthetic Bay Runner', '3', 0.150,
   'LR', 'Blue', 1, timestamp '2026-09-01', timestamp '2026-10-13');

INSERT INTO public.geofences
  (id, name, latitude, longitude, radius, billing_type, cost_per_unit,
   inserted_at, updated_at)
VALUES
  (1, 'Synthetic SF Garage', 37.774900, -122.419400, 120, 'per_kwh', 0.24,
   timestamp '2026-09-01', timestamp '2026-09-01'),
  (2, 'Synthetic Oakland Charger', 37.804400, -122.271200, 120, 'per_kwh', 0.31,
   timestamp '2026-09-01', timestamp '2026-09-01');

INSERT INTO public.addresses
  (id, display_name, latitude, longitude, name, house_number, road, city, state,
   postcode, country, raw, inserted_at, updated_at)
VALUES
  (1, '1 Synthetic Market Street', 37.774900, -122.419400, 'Synthetic Garage',
   '1', 'Synthetic Market Street', 'San Francisco', 'California', '94103',
   'United States', '{}', timestamp '2026-09-01', timestamp '2026-09-01'),
  (2, '2 Synthetic Broadway', 37.804400, -122.271200, 'Synthetic Charger',
   '2', 'Synthetic Broadway', 'Oakland', 'California', '94607',
   'United States', '{}', timestamp '2026-09-01', timestamp '2026-09-01');

-- Six twenty-minute TeslaMate drives per day for thirty days. Each has 241
-- five-second GPS points, enough to make route projection costs visible.
INSERT INTO public.drives
  (id, car_id, start_date, end_date, distance, duration_min, start_km, end_km,
   start_rated_range_km, end_rated_range_km, speed_max, outside_temp_avg,
   start_address_id, end_address_id, start_geofence_id, end_geofence_id,
   ascent, descent)
SELECT
  10000 + n, 1, started, started + interval '20 minutes', 18.0, 20,
  20000 + n * 18.0, 20018 + n * 18.0, 430, 406, 105,
  14 + (n % 9), CASE WHEN n % 2 = 0 THEN 1 ELSE 2 END,
  CASE WHEN n % 2 = 0 THEN 2 ELSE 1 END,
  CASE WHEN n % 2 = 0 THEN 1 ELSE 2 END,
  CASE WHEN n % 2 = 0 THEN 2 ELSE 1 END,
  95, 88
FROM generate_series(0, 179) AS n
CROSS JOIN LATERAL (
  SELECT timestamp '2026-09-13 06:30:00' + n * interval '4 hours' AS started
) AS schedule;

INSERT INTO public.positions
  (id, car_id, drive_id, date, latitude, longitude, speed, power, odometer,
   ideal_battery_range_km, rated_battery_range_km, est_battery_range_km,
   battery_level, usable_battery_level, outside_temp, inside_temp, elevation,
   is_climate_on, driver_temp_setting)
SELECT
  1000000 + n * 1000 + point, 1, 10000 + n,
  timestamp '2026-09-13 06:30:00' + n * interval '4 hours' + point * interval '5 seconds',
  CASE WHEN n % 2 = 0 THEN 37.774900 + point * 0.000122
       ELSE 37.804400 - point * 0.000122 END,
  CASE WHEN n % 2 = 0 THEN -122.419400 + point * 0.000618
       ELSE -122.271200 - point * 0.000618 END,
  CASE WHEN point IN (0, 240) THEN 0 ELSE 54 + ((point + n) % 26) END,
  CASE WHEN point IN (0, 240) THEN 0 ELSE 18 + ((point + n) % 12) END,
  20000 + n * 18.0 + point * 18.0 / 240,
  430 - point * 24.0 / 240, 430 - point * 24.0 / 240,
  414 - point * 24.0 / 240,
  82 - floor(point * 5.0 / 240)::integer,
  82 - floor(point * 5.0 / 240)::integer,
  14 + (n % 9), 21, 8 + ((point + n) % 35), false, 21
FROM generate_series(0, 179) AS n
CROSS JOIN generate_series(0, 240) AS point;

UPDATE public.drives
SET start_position_id = 1000000 + (id - 10000) * 1000,
    end_position_id = 1000000 + (id - 10000) * 1000 + 240;

-- Daily TeslaMate charging history with dense two-minute samples.
INSERT INTO public.positions
  (id, car_id, date, latitude, longitude, odometer, ideal_battery_range_km,
   rated_battery_range_km, battery_level, usable_battery_level, outside_temp,
   inside_temp, elevation, is_climate_on)
SELECT
  2000000 + day, 1,
  timestamp '2026-09-13 03:15:00' + day * interval '1 day',
  37.774900, -122.419400, 20000 + day * 108 + 108,
  325, 325, 62, 62, 16 + (day % 6), 21, 12, false
FROM generate_series(0, 30) AS day;

INSERT INTO public.charging_processes
  (id, car_id, position_id, address_id, geofence_id, start_date, end_date,
   duration_min, charge_energy_added, charge_energy_used, start_battery_level,
   end_battery_level, start_rated_range_km, end_rated_range_km, cost,
   outside_temp_avg)
SELECT
  20000 + day, 1, 2000000 + day, 1, 1,
  timestamp '2026-09-13 03:15:00' + day * interval '1 day',
  timestamp '2026-09-13 04:15:00' + day * interval '1 day',
  60, 22, 24, 62, 91, 325, 460, 5.28, 16 + (day % 6)
FROM generate_series(0, 30) AS day;

INSERT INTO public.charges
  (id, charging_process_id, date, battery_level, usable_battery_level,
   charge_energy_added, charger_power, charger_voltage, charger_actual_current,
   charger_phases, ideal_battery_range_km, rated_battery_range_km,
   fast_charger_present, fast_charger_brand)
SELECT
  2000000 + day * 100 + point, 20000 + day,
  timestamp '2026-09-13 03:15:00' + day * interval '1 day' + point * interval '2 minutes',
  62 + floor(point * 29.0 / 30)::integer,
  62 + floor(point * 29.0 / 30)::integer,
  point * 22.0 / 30,
  CASE WHEN point = 30 THEN 0 ELSE 11 END, 230,
  CASE WHEN point = 30 THEN 0 ELSE 16 END, 3,
  325 + point * 135.0 / 30, 325 + point * 135.0 / 30, false, NULL
FROM generate_series(0, 30) AS day
CROSS JOIN generate_series(0, 30) AS point;

-- Logger states and unlinked parked observations exercise realistic history
-- cardinality without depending on any external location service.
INSERT INTO public.states (id, car_id, state, start_date, end_date)
SELECT 3000000 + n * 2, 1, 'online'::public.states_status,
       started, started + interval '25 minutes'
FROM generate_series(0, 179) AS n
CROSS JOIN LATERAL (
  SELECT timestamp '2026-09-13 06:30:00' + n * interval '4 hours' AS started
) AS schedule
UNION ALL
SELECT 3000000 + n * 2 + 1, 1, 'asleep'::public.states_status,
       started + interval '25 minutes', started + interval '4 hours'
FROM generate_series(0, 179) AS n
CROSS JOIN LATERAL (
  SELECT timestamp '2026-09-13 06:30:00' + n * interval '4 hours' AS started
) AS schedule;

INSERT INTO public.positions
  (id, car_id, date, latitude, longitude, odometer, ideal_battery_range_km,
   rated_battery_range_km, battery_level, usable_battery_level, outside_temp,
   inside_temp, elevation, is_climate_on)
SELECT
  4000000 + tick, 1,
  timestamp '2026-09-13 06:00:00' + tick * interval '5 minutes',
  37.774900, -122.419400,
  20000 + floor(tick / 48.0) * 18,
  410, 410, 78, 78, 15 + (tick % 8), 21, 12,
  (tick % 48) >= 45
FROM generate_series(0, 8639) AS tick;

-- Fleet Telemetry covers the newest seven days. Its drive sessions mirror the
-- corresponding logger drives, while sub-second timestamp jitter prevents an
-- unrealistically perfect cadence.
INSERT INTO volta_telemetry.vehicle_bindings (vehicle_id, vin_digest)
VALUES (1, :'vin_digest');

INSERT INTO volta_telemetry.connectivity
  (vehicle_id, connection_id, status, source_ts, network_interface, received_at)
VALUES
  (1, 'synthetic-benchmark', 'CONNECTED', timestamptz '2026-10-06 06:00:00+00',
   'wifi', timestamptz '2026-10-06 06:00:00+00');

INSERT INTO volta_telemetry.sessions
  (vehicle_id, kind, start_ts, end_ts, start_reason, end_reason, membership,
   gaps, payloads, derived_at)
SELECT
  1, 'drive', start_date AT TIME ZONE 'UTC', end_date AT TIME ZONE 'UTC',
  'gear', 'gear', 'complete', '[]'::jsonb, 241, timestamptz '2026-10-13 06:00:00+00'
FROM public.drives
WHERE start_date >= timestamp '2026-10-06 06:00:00'
UNION ALL
SELECT
  1, 'charge', start_date AT TIME ZONE 'UTC', end_date AT TIME ZONE 'UTC',
  'charge_state', 'charge_state', 'complete', '[]'::jsonb, 31,
  timestamptz '2026-10-13 06:00:00+00'
FROM public.charging_processes
WHERE start_date >= timestamp '2026-10-06 06:00:00';

INSERT INTO volta_telemetry.power_calibration
  (vehicle_id, sign, source, evidence_note, recorded_at)
VALUES
  (1, 'discharge_positive', 'operator_live_gate',
   'Synthetic benchmark calibration', timestamptz '2026-10-06 06:00:00+00');

WITH drive_samples AS (
  SELECT d.id, d.start_date,
    CASE WHEN point = 240 THEN d.end_date
         ELSE d.start_date + point * interval '5 seconds'
              + ((point % 7) * 13) * interval '1 millisecond' END AS t,
    point,
    CASE WHEN d.id % 2 = 0 THEN 37.774900 + point * 0.000122
         ELSE 37.804400 - point * 0.000122 END AS latitude,
    CASE WHEN d.id % 2 = 0 THEN -122.419400 + point * 0.000618
         ELSE -122.271200 - point * 0.000618 END AS longitude
  FROM public.drives d CROSS JOIN generate_series(0, 240) AS point
  WHERE d.start_date >= timestamp '2026-10-06 06:00:00'
), expanded AS (
  SELECT s.*, f.field, f.value_num, f.latitude AS sample_latitude,
         f.longitude AS sample_longitude
  FROM drive_samples s
  CROSS JOIN LATERAL (VALUES
    ('Location'::text, NULL::double precision, s.latitude, s.longitude),
    ('VehicleSpeed', CASE WHEN s.point IN (0,240) THEN 0 ELSE 39 + ((s.point+s.id)%13) END, NULL, NULL),
    ('PackVoltage', 390 + ((s.point+s.id)%9), NULL, NULL),
    ('PackCurrent', CASE WHEN s.point IN (0,240) THEN 0 ELSE 48 + ((s.point+s.id)%12) END, NULL, NULL),
    ('BatteryLevel', 82 - s.point * 5.0 / 240, NULL, NULL),
    ('Soc', 82 - s.point * 5.0 / 240, NULL, NULL),
    ('Odometer', (20000 + (s.id-10000)*18 + s.point*18.0/240) / 1.609344, NULL, NULL),
    ('EnergyRemaining', 61.5 - s.point * 3.8 / 240, NULL, NULL),
    ('OutsideTemp', 17 + (s.id % 7), NULL, NULL),
    ('InsideTemp', 21, NULL, NULL),
    ('LongitudinalAcceleration', ((s.point%9)-4)*0.12, NULL, NULL),
    ('LateralAcceleration', ((s.point%7)-3)*0.09, NULL, NULL)
  ) AS f(field, value_num, latitude, longitude)
)
INSERT INTO volta_telemetry.samples
  (vehicle_id, field, source_ts, received_at, value_num, latitude, longitude,
   invalid, quality, source_unit, is_resend, payload_id)
SELECT
  1, field, t AT TIME ZONE 'UTC',
  (t + interval '180 milliseconds') AT TIME ZONE 'UTC', value_num,
  sample_latitude, sample_longitude, false, 'ok', '', false,
  'drive-' || id || '-' || point
FROM expanded;

WITH charge_samples AS (
  SELECT cp.id, cp.start_date + point * interval '2 minutes' AS t, point
  FROM public.charging_processes cp CROSS JOIN generate_series(0, 30) AS point
  WHERE cp.start_date >= timestamp '2026-10-06 06:00:00'
), expanded AS (
  SELECT s.*, f.field, f.value_num
  FROM charge_samples s
  CROSS JOIN LATERAL (VALUES
    ('ACChargingPower'::text, CASE WHEN s.point = 30 THEN 0 ELSE 11 END::double precision),
    ('BatteryLevel', 62 + s.point*29.0/30),
    ('Soc', 62 + s.point*29.0/30),
    ('EnergyRemaining', 46.5 + s.point*22.0/30),
    ('ChargerVoltage', 230),
    ('ChargeAmps', CASE WHEN s.point = 30 THEN 0 ELSE 16 END),
    ('OutsideTemp', 18 + (s.id%5))
  ) AS f(field, value_num)
)
INSERT INTO volta_telemetry.samples
  (vehicle_id, field, source_ts, received_at, value_num, invalid, quality,
   source_unit, is_resend, payload_id)
SELECT
  1, field, t AT TIME ZONE 'UTC', (t + interval '220 milliseconds') AT TIME ZONE 'UTC',
  value_num, false, 'ok', '', false, 'charge-' || id || '-' || point
FROM expanded;

-- Change-only parked observations: numerous sparse per-field samples outside
-- sessions, representative of a continuously connected vehicle.
WITH parked AS (
  SELECT tick, t
  FROM (
    SELECT tick,
      timestamp '2026-10-06 06:00:00' + tick * interval '2 minutes'
        + ((tick % 5) * 17) * interval '1 millisecond' AS t
    FROM generate_series(0, 5039) AS tick
  ) p
  WHERE NOT EXISTS (
    SELECT 1 FROM volta_telemetry.sessions s
    WHERE p.t AT TIME ZONE 'UTC' BETWEEN s.start_ts AND s.end_ts
  )
), expanded AS (
  SELECT p.*, f.field, f.value_num, f.latitude, f.longitude
  FROM parked p
  CROSS JOIN LATERAL (VALUES
    ('Location'::text, NULL::double precision, 37.774900::double precision, -122.419400::double precision),
    ('BatteryLevel', 78::double precision, NULL, NULL),
    ('Soc', 78::double precision, NULL, NULL),
    ('Odometer', (23240 + p.tick*0.0002)/1.609344, NULL, NULL),
    ('EnergyRemaining', 58.5::double precision, NULL, NULL),
    ('OutsideTemp', (15 + p.tick%8)::double precision, NULL, NULL)
  ) AS f(field, value_num, latitude, longitude)
)
INSERT INTO volta_telemetry.samples
  (vehicle_id, field, source_ts, received_at, value_num, latitude, longitude,
   invalid, quality, source_unit, is_resend, payload_id)
SELECT
  1, field, t AT TIME ZONE 'UTC', (t + interval '200 milliseconds') AT TIME ZONE 'UTC',
  value_num, latitude, longitude, false, 'ok', '', false, 'park-' || tick
FROM expanded;

-- Short disconnect jitter is intentionally below the 90-second loss threshold:
-- it must not alter API semantics, but it makes the baseline drive_points view
-- perform its correlated gap/predecessor work for every dense location point.
INSERT INTO volta_telemetry.gaps (vehicle_id, start_ts, end_ts, reason)
SELECT
  1, t, t + interval '1 second', 'disconnected'
FROM generate_series(
  timestamptz '2026-10-06 06:01:00+00',
  timestamptz '2026-10-13 05:56:00+00',
  interval '5 minutes'
) AS t;

INSERT INTO volta_telemetry.latest_samples
  (vehicle_id, field, source_ts, received_at, value_num, value_text, value_bool,
   latitude, longitude, invalid, quality, source_unit, payload_id)
SELECT DISTINCT ON (vehicle_id, field)
  vehicle_id, field, source_ts, received_at, value_num, value_text, value_bool,
  latitude, longitude, invalid, quality, source_unit, payload_id
FROM volta_telemetry.samples
ORDER BY vehicle_id, field, source_ts DESC, payload_id DESC;

COMMIT;

ANALYZE public.cars;
ANALYZE public.drives;
ANALYZE public.positions;
ANALYZE public.charging_processes;
ANALYZE public.charges;
ANALYZE public.states;
ANALYZE volta_telemetry.samples;
ANALYZE volta_telemetry.latest_samples;
ANALYZE volta_telemetry.sessions;
ANALYZE volta_telemetry.gaps;
