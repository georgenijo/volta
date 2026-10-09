-- Two years of synthetic driving volume; upstream indexes plus the production
-- route-seek index installed by bootstrap. All prior charges have known prices.
INSERT INTO drives (id, car_id, start_date, end_date, distance, duration_min, start_rated_range_km, end_rated_range_km, start_km, end_km)
SELECT 10000+n, 1, timestamp '2020-01-01' + n * interval '6 hours', timestamp '2020-01-01' + n * interval '6 hours' + interval '1 hour',
  30, 60, 400, 370, 10000+n*30, 10030+n*30 FROM generate_series(1,2500) n;
INSERT INTO positions (id, car_id, drive_id, date, latitude, longitude, odometer, battery_level, usable_battery_level, rated_battery_range_km, ideal_battery_range_km, is_climate_on)
SELECT 100000+(n-1)*600+j, 1, 10000+n, timestamp '2020-01-01' + n*interval '6 hours' + j*interval '6 seconds',
  40, -74, 10000+n*30+j*0.05, 80-(j/100), CASE WHEN j%15=0 OR j=1 THEN 80-(j/100) ELSE NULL END,
  CASE WHEN j%15=0 OR j=1 THEN 400-j*0.05 ELSE NULL END,
  CASE WHEN j%15=0 OR j=1 THEN 400-j*0.05 ELSE NULL END,
  CASE WHEN j%15=0 OR j=1 THEN false ELSE NULL END
FROM generate_series(1,2500) n CROSS JOIN generate_series(1,600) j;
UPDATE drives SET start_position_id = 100000+(id-10001)*600+1, end_position_id = 100000+(id-10001)*600+600 WHERE id > 10000;
INSERT INTO charging_processes (id, car_id, position_id, start_date, end_date, duration_min, charge_energy_added, charge_energy_used, start_battery_level, end_battery_level, start_rated_range_km, end_rated_range_km, cost)
SELECT 10000+n, 1, 100000+(n-1)*600+600, timestamp '2020-01-01' + n*interval '6 hours' + interval '90 minutes',
  timestamp '2020-01-01' + n*interval '6 hours' + interval '150 minutes', 60, 18, 20, 69, 93, 345, 465, 4.50 FROM generate_series(1,1000) n;
INSERT INTO charges (id, charging_process_id, date, battery_level, usable_battery_level, charge_energy_added, charger_power, ideal_battery_range_km, rated_battery_range_km)
SELECT 100000+(n-1)*100+j, 10000+n, timestamp '2020-01-01' + n*interval '6 hours' + interval '90 minutes' + (j-1)*interval '36 seconds',
  69+(j-1)*24/99, 69+(j-1)*24/99, (j-1)*18.0/99, 11, 345+(j-1)*120.0/99, 345+(j-1)*120.0/99
FROM generate_series(1,1000) n CROSS JOIN generate_series(1,100) j;
-- Final sample at the process's recorded finish for idle/battery boundaries.
UPDATE charges SET date = date + interval '36 seconds' WHERE id%100 = 0 AND id > 100000;
ANALYZE public.drives;
ANALYZE public.positions;
ANALYZE public.charging_processes;
ANALYZE public.charges;
-- 7,500 actual logger transitions: online while driving/charging, asleep while parked.
INSERT INTO states (id,car_id,state,start_date,end_date)
SELECT 100000+(n-1)*3+k, 1, state::states_status,
  timestamp '2020-01-01'+n*interval '6 hours'+start_min*interval '1 minute',
  timestamp '2020-01-01'+n*interval '6 hours'+end_min*interval '1 minute'
FROM generate_series(1,2500) n CROSS JOIN LATERAL (
  VALUES (1,'online',0,CASE WHEN n<=1000 THEN 150 ELSE 90 END),
         (2,'asleep',CASE WHEN n<=1000 THEN 150 ELSE 90 END,300), (3,'online',300,360)
) s(k,state,start_min,end_min);
-- Parked readings during recorded awake periods, with climate warm-up before departure.
INSERT INTO positions (id,car_id,date,latitude,longitude,odometer,battery_level,usable_battery_level,rated_battery_range_km,ideal_battery_range_km,is_climate_on)
SELECT 2000000+(n-1)*400+j,1,timestamp '2020-01-01'+n*interval '6 hours'+j*interval '1 minute',
  40,-74,10030+n*30,CASE WHEN n<=1000 AND j>=300 THEN 93 ELSE 74 END,CASE WHEN n<=1000 AND j>=300 THEN 93 ELSE 74 END,
  CASE WHEN n<=1000 AND j>=300 THEN 465 ELSE 370 END,CASE WHEN n<=1000 AND j>=300 THEN 465 ELSE 370 END,j>=355
FROM generate_series(1,2500) n CROSS JOIN (SELECT generate_series(61,89) AS j UNION ALL SELECT generate_series(300,359)) parked;
ANALYZE public.states;
ANALYZE public.positions;
