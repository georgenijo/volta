-- Synthetic local evening: July 1 in New York spans UTC July 1 04:00 to July 2 04:00.
INSERT INTO drives (id, car_id, start_date, end_date, distance, duration_min)
VALUES (100,2,'2026-07-01 03:59:59','2026-07-01 04:00:00',1,1),
       (101,2,'2026-07-01 04:00:00','2026-07-01 04:01:00',10,1),
       (102,2,'2026-07-02 00:00:00','2026-07-02 00:01:00',20,1),
       (103,2,'2026-07-02 03:59:58','2026-07-02 03:59:59',30,1),
       (104,2,'2026-07-02 04:00:00','2026-07-02 04:01:00',100,1);
INSERT INTO positions (id, car_id, date, latitude, longitude)
SELECT id, car_id, start_date, 40, -74 FROM drives WHERE car_id=2;
INSERT INTO charging_processes (id, car_id, position_id, start_date, end_date, duration_min, charge_energy_added, cost)
VALUES (100,2,100,'2026-07-01 03:59:59','2026-07-01 04:00:00',1,1,1),
       (101,2,101,'2026-07-01 04:00:00','2026-07-01 04:01:00',1,10,1),
       (102,2,102,'2026-07-02 00:00:00','2026-07-02 00:01:00',1,20,2),
       (103,2,103,'2026-07-02 03:59:58','2026-07-02 03:59:59',1,30,3),
       (104,2,104,'2026-07-02 04:00:00','2026-07-02 04:01:00',1,100,10);
