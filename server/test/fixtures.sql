-- Synthetic Tesla and trips; no personal vehicle data.
INSERT INTO car_settings (id) VALUES (1), (2), (3);
INSERT INTO cars (id, eid, vid, vin, name, model, efficiency, trim_badging, exterior_color, settings_id, inserted_at, updated_at)
VALUES (1, 1001, 2001, 'SYNTHETIC000000001', 'Synthetic Model 3', '3', 0.15, 'LR', 'White', 1, now(), now()),
       (2, 1002, 2002, 'SYNTHETIC000000002', 'Empty Tesla', 'Y', NULL, NULL, NULL, 2, now(), now()),
       (3, 1003, 2003, 'SYNTHETIC000000003', 'Derived efficiency Tesla', 'S', NULL, NULL, NULL, 3, now(), now());
INSERT INTO geofences (id, name, latitude, longitude, radius, billing_type, cost_per_unit, inserted_at, updated_at)
VALUES (1, 'Synthetic Home', 40.000000, -74.000000, 100, 'per_kwh', 0.20, now(), now()),
       (2, 'Per minute', 41.000000, -75.000000, 50, 'per_minute', 0.50, now(), now());
INSERT INTO addresses (id, display_name, latitude, longitude, raw, inserted_at, updated_at)
VALUES (1, '1 Synthetic Street', 40.000000, -74.000000, '{}', now(), now()), (2, '2 Synthetic Street', 40.010000, -74.010000, '{}', now(), now());
-- All times relative to UTC midnight for deterministic today/7d/30d queries.
INSERT INTO drives (id, car_id, start_date, end_date, distance, duration_min, start_rated_range_km, end_rated_range_km, speed_max, outside_temp_avg, start_address_id, end_address_id, start_geofence_id, ascent)
VALUES (1, 1, (now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '8 hours', (now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '9 hours', 40, 60, 400, 360, 100, 15, 1, 2, 1, 120),
       (2, 1, (now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '11 hours', (now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '12 hours', 20, 60, 350, 330, 70, 16, 2, 1, NULL, 50),
       (3, 1, (now() AT TIME ZONE 'UTC')::date - interval '1 day' + interval '8 hours', (now() AT TIME ZONE 'UTC')::date - interval '1 day' + interval '9 hours', 30, 60, 450, 420, 80, 12, 1, 2, 1, NULL),
       (4, 1, (now() AT TIME ZONE 'UTC')::date - interval '1 day' + interval '8 hours', (now() AT TIME ZONE 'UTC')::date - interval '1 day' + interval '8 hours 30 minutes', 15, 30, 450, 435, 60, 12, 1, 2, 1, NULL);
INSERT INTO positions (id, car_id, drive_id, date, latitude, longitude, battery_level, usable_battery_level, rated_battery_range_km, ideal_battery_range_km, est_battery_range_km, odometer, speed, power, elevation, inside_temp, outside_temp, is_climate_on, driver_temp_setting)
VALUES (1,1,1,(now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '8 hours',40,-74,80,80,400,400,380,10000,0,0,10,21,15,false,21),
       (2,1,1,(now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '8 hours 30 minutes',40.005,-74.005,76,76,380,380,360,10020,90,20,80,21,15,false,21),
       (3,1,1,(now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '9 hours',40.01,-74.01,72,72,360,360,340,10040,0,0,20,21,15,false,21),
       (4,1,2,(now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '11 hours',40.01,-74.01,70,70,350,350,330,10040,0,0,20,21,16,true,21),
       (5,1,2,(now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '12 hours',40,-74,66,66,330,330,310,10060,0,0,10,21,16,false,21),
       (6,1,NULL,(now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '13 hours',40,-74,65,65,325,325,305,10060,0,0,10,21,16,false,21),
       (7,1,3,(now() AT TIME ZONE 'UTC')::date - interval '1 day' + interval '8 hours',40,-74,90,90,450,450,430,10060,0,0,10,21,12,false,21),
       (8,1,3,(now() AT TIME ZONE 'UTC')::date - interval '1 day' + interval '9 hours',40.01,-74.01,84,84,420,420,400,10090,0,0,20,21,12,false,21),
       (9,1,NULL,(now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '9 hours 30 minutes',40.01,-74.01,72,72,360,360,340,10040,0,0,20,21,15,true,21),
       (10,1,NULL,(now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '9 hours 35 minutes',40.01,-74.01,72,72,360,360,340,10040,0,0,20,21,15,false,21);
UPDATE drives SET start_position_id = CASE id WHEN 1 THEN 1 WHEN 2 THEN 4 WHEN 3 THEN 7 WHEN 4 THEN 7 END,
                  end_position_id = CASE id WHEN 1 THEN 3 WHEN 2 THEN 5 WHEN 3 THEN 8 WHEN 4 THEN 8 END;
INSERT INTO positions (id, car_id, date, latitude, longitude, battery_level, usable_battery_level, rated_battery_range_km, ideal_battery_range_km)
VALUES (11,3,(now() AT TIME ZONE 'UTC')::date - interval '3 days',40,-74,40,40,200,200);
INSERT INTO charging_processes (id, car_id, position_id, address_id, geofence_id, start_date, end_date, duration_min, charge_energy_added, charge_energy_used, start_battery_level, end_battery_level, start_rated_range_km, end_rated_range_km, cost, outside_temp_avg)
VALUES (1,1,6,1,1,(now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '13 hours', (now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '14 hours',60,21,24,65,93,325,465,4.8,16),
       (2,3,11,NULL,NULL,(now() AT TIME ZONE 'UTC')::date - interval '3 days', (now() AT TIME ZONE 'UTC')::date - interval '3 days' + interval '1 hour',60,20,23,40,80,200,300,NULL,NULL);
INSERT INTO charges (id, charging_process_id, date, battery_level, usable_battery_level, charge_energy_added, charger_power, charger_voltage, charger_actual_current, charger_phases, ideal_battery_range_km, rated_battery_range_km, fast_charger_present)
VALUES (1,1,(now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '13 hours',65,65,0,11,230,16,3,325,325,false),
       (2,1,(now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '14 hours',93,93,21,0,230,0,3,465,465,false),
       (3,2,(now() AT TIME ZONE 'UTC')::date - interval '3 days' + interval '1 hour',80,80,20,20,400,50,NULL,300,300,true);
INSERT INTO states (id, car_id, state, start_date, end_date)
VALUES (1,1,'online',(now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '8 hours',(now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '9 hours 40 minutes'),
       (2,1,'asleep',(now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '9 hours 40 minutes',(now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '10 hours 40 minutes'),
       (3,1,'online',(now() AT TIME ZONE 'UTC')::date - interval '2 days' + interval '10 hours 40 minutes',(now() AT TIME ZONE 'UTC')::date - interval '1 day' + interval '10 hours'),
       (4,1,'asleep',(now() AT TIME ZONE 'UTC')::date - interval '1 day' + interval '10 hours',NULL);
INSERT INTO updates (id, car_id, start_date, end_date, version)
VALUES (1,1,(now() AT TIME ZONE 'UTC')::date - interval '20 days',(now() AT TIME ZONE 'UTC')::date - interval '20 days' + interval '20 minutes','2026.1'),
       (2,1,(now() AT TIME ZONE 'UTC')::date - interval '5 days',(now() AT TIME ZONE 'UTC')::date - interval '5 days' + interval '20 minutes','2026.2');
