-- Administrator-managed Volta data only; never writes TeslaMate history.
CREATE TABLE IF NOT EXISTS volta.service_items (
  id uuid PRIMARY KEY,
  vehicle_id integer NOT NULL,
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  interval_km double precision CHECK (interval_km > 0 AND interval_km <= 1000000),
  interval_months integer CHECK (interval_months BETWEEN 1 AND 1200),
  CHECK (interval_km IS NOT NULL OR interval_months IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS service_items_vehicle ON volta.service_items(vehicle_id);
CREATE TABLE IF NOT EXISTS volta.service_events (
  id uuid PRIMARY KEY,
  item_id uuid NOT NULL REFERENCES volta.service_items(id),
  completed_at timestamptz NOT NULL,
  odometer_km double precision CHECK (odometer_km >= 0 AND odometer_km <= 10000000)
);
CREATE INDEX IF NOT EXISTS service_events_item ON volta.service_events(item_id, completed_at DESC);
