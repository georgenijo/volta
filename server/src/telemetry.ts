import { createHash } from 'node:crypto';
import type { DB, Row } from './db';
import { ApiError, missing } from './errors';
import type { ListInput } from './validation';
import { summaryPeriod } from './period';
import { FleetSeries } from './fleet-series';

export class Telemetry {
  constructor(private sql: DB, private currency: string | null = null, private clock: () => Date = () => new Date(), private fleetEnabled = false,
    private log: (entry: object) => void = () => {}) {}
  private async fleetSession(kind: 'drive' | 'charge', id: number) {
    try { return await new FleetSeries(this.sql).session(kind,id); }
    catch {
      // Database errors may contain query text and values. Emit only a stable,
      // non-sensitive code while preserving the TeslaMate detail response.
      this.log({event:'fleet_series_failed',code:'telemetry_query_failed'});
      return null;
    }
  }
  async vehicle(id: number) {
    const [car] = await this.sql`SELECT id, efficiency FROM public.cars WHERE id = ${id}`;
    if (!car) throw missing();
    return car;
  }
  // Same modal, 0.001 kWh/km precision derivation as TeslaMate Battery Health.
  private efficiency() {
    const s = this.sql;
    return s`COALESCE((SELECT mode() WITHIN GROUP (ORDER BY round((cp.charge_energy_added / NULLIF(cp.end_rated_range_km - cp.start_rated_range_km, 0))::numeric, 3))
      FROM public.charging_processes cp WHERE cp.car_id = car.id AND cp.duration_min > 10 AND cp.end_battery_level <= 95
      AND cp.end_rated_range_km > cp.start_rated_range_km AND cp.charge_energy_added > 0), car.efficiency)`;
  }
  /** The rows status reads its battery reading from, joined per `car`: latest full poll, latest position
   * (last 24h, or within 15 minutes of that poll), and the newest sample of the open charging process.
   * Shared with `vehicles` so `hasData` can never disagree with status. */
  private batterySources() {
    return this.sql`LEFT JOIN LATERAL (SELECT * FROM public.positions WHERE car_id = car.id AND ideal_battery_range_km IS NOT NULL ORDER BY date DESC, id DESC LIMIT 1) poll ON true
      LEFT JOIN LATERAL (
        (SELECT * FROM public.positions WHERE car_id=car.id AND date >= now() AT TIME ZONE 'UTC'-interval '24 hours' ORDER BY date DESC,id DESC LIMIT 1)
        UNION ALL (SELECT * FROM public.positions WHERE poll.date IS NOT NULL AND car_id=car.id AND date BETWEEN poll.date AND poll.date+interval '15 minutes' ORDER BY date DESC,id DESC LIMIT 1)
        ORDER BY date DESC,id DESC LIMIT 1
      ) p ON true
      LEFT JOIN LATERAL (SELECT * FROM public.charging_processes WHERE car_id = car.id AND end_date IS NULL ORDER BY start_date DESC, id DESC LIMIT 1) cp ON true
      LEFT JOIN LATERAL (SELECT * FROM public.charges WHERE charging_process_id = cp.id ORDER BY date DESC, id DESC LIMIT 1) ch ON true`;
  }
  async vehicles() {
    return this.sql`SELECT car.id, COALESCE(car.name, 'Tesla') AS name, car.model, car.trim_badging AS trim,
      car.exterior_color AS "exteriorColor", right(car.vin, 6) AS "vinSuffix",
      (SELECT version FROM public.updates WHERE car_id = car.id AND end_date IS NOT NULL ORDER BY end_date DESC, id DESC LIMIT 1) AS firmware,
      -- Exactly status's 409 condition over the same rows: says whether status has a battery reading now, not how fresh it is.
      (p.battery_level IS NOT NULL OR ch.battery_level IS NOT NULL) AS "hasData"
      FROM public.cars car JOIN public.car_settings cs ON cs.id = car.settings_id ${this.batterySources()} ORDER BY car.display_priority, car.id`;
  }
  async health() {
    try {
      const [row] = await this.sql`WITH polled AS MATERIALIZED (
        SELECT car.id, p.date FROM public.cars car LEFT JOIN LATERAL (
          SELECT date FROM public.positions WHERE car_id=car.id AND ideal_battery_range_km IS NOT NULL ORDER BY date DESC LIMIT 1
        ) p ON true), latest AS (
          SELECT p.date FROM polled car LEFT JOIN LATERAL (
            (SELECT date FROM public.positions WHERE car_id=car.id AND date >= now() AT TIME ZONE 'UTC'-interval '24 hours' ORDER BY date DESC LIMIT 1)
            UNION ALL (SELECT date FROM public.positions WHERE car.date IS NOT NULL AND car_id=car.id AND date BETWEEN car.date AND car.date+interval '15 minutes' ORDER BY date DESC LIMIT 1)
            ORDER BY date DESC LIMIT 1
          ) p ON true
        ) SELECT max(t) AS "lastDataAt" FROM (
          SELECT date AS t FROM latest UNION ALL (SELECT date FROM public.charges ORDER BY date DESC LIMIT 1)
          UNION ALL SELECT max(start_date) FROM public.states
        ) data`;
      return { ok: true, version: '0.1.0', teslamate: { reachable: true, lastDataAt: row?.lastDataAt ?? null } };
    } catch { return { ok: false, version: '0.1.0', teslamate: { reachable: false, lastDataAt: null } }; }
  }
  async status(id: number) {
    await this.vehicle(id);
    const s = this.sql;
    const [row] = await s`SELECT p.*, poll.usable_battery_level AS polled_usable, poll.rated_battery_range_km AS polled_rated,
      poll.est_battery_range_km AS polled_est, poll.inside_temp AS polled_inside, poll.outside_temp AS polled_outside,
      poll.is_climate_on AS polled_climate, poll.driver_temp_setting AS polled_driver_temp, st.state, st.start_date AS state_at,
      d.id AS active_drive_id, d.start_date AS drive_at, cp.id AS charge_id, cp.start_date AS charge_at,
      u.id AS update_id, u.start_date AS update_at, ch.date AS charge_sample_at, ch.battery_level AS charge_battery,
      ch.usable_battery_level AS charge_usable, ch.rated_battery_range_km AS charge_range, ch.charger_power,
      (SELECT version FROM public.updates WHERE car_id = ${id} AND end_date IS NOT NULL ORDER BY end_date DESC, id DESC LIMIT 1) AS firmware,
      a.display_name AS address, g.name AS place_name
      FROM public.cars car
      ${this.batterySources()}
      LEFT JOIN LATERAL (SELECT * FROM public.states WHERE car_id = car.id ORDER BY start_date DESC, id DESC LIMIT 1) st ON true
      LEFT JOIN LATERAL (SELECT * FROM public.drives WHERE car_id = car.id AND end_date IS NULL ORDER BY start_date DESC, id DESC LIMIT 1) d ON true
      LEFT JOIN LATERAL (SELECT * FROM public.updates WHERE car_id = car.id AND end_date IS NULL ORDER BY start_date DESC, id DESC LIMIT 1) u ON true
      LEFT JOIN LATERAL (SELECT address_id, geofence_id FROM public.charging_processes WHERE car_id = car.id AND position_id = p.id ORDER BY start_date DESC LIMIT 1) loc ON true
      LEFT JOIN public.addresses a ON a.id = loc.address_id
      LEFT JOIN LATERAL (SELECT name FROM public.geofences WHERE
        6371000 * 2 * asin(least(1.0, sqrt(power(sin(radians((latitude-p.latitude)/2)),2) + cos(radians(p.latitude))*cos(radians(latitude))*power(sin(radians((longitude-p.longitude)/2)),2)))) <= radius
        ORDER BY radius, id LIMIT 1) g ON true
      WHERE car.id = ${id}`;
    if (!row || (row.battery_level == null && row.charge_battery == null)) throw new ApiError(409, 'data_unavailable', 'TeslaMate has not recorded a battery observation for this vehicle');
    const chargeNewer = row.charge_sample_at && (!row.date || row.charge_sample_at >= row.date);
    const updatedAt = [row.date, row.state_at, row.drive_at, row.charge_at, row.charge_sample_at, row.update_at].filter(Boolean).sort((a, b) => +b - +a)[0];
    // Historical fields remain timestamped; logger reachability cannot prove live Tesla connectivity.
    const state = row.update_id ? 'updating' : row.active_drive_id ? 'driving' : row.charge_id ? 'charging' : row.state ?? 'offline';
    return { vehicleId: id, state, updatedAt,
      batteryLevel: chargeNewer ? row.charge_battery ?? row.battery_level : row.battery_level ?? row.charge_battery,
      usableBatteryLevel: chargeNewer ? row.charge_usable : row.polled_usable ?? null,
      ratedRangeKm: chargeNewer ? row.charge_range : row.polled_rated ?? null,
      estRangeKm: row.polled_est ?? null, chargeLimit: null, chargingState: row.charge_id ? 'charging' : null,
      chargerPowerKw: row.charge_id ? row.charger_power ?? null : null, minutesToFull: null,
      insideTempC: row.polled_inside ?? null, outsideTempC: row.polled_outside ?? null, climateOn: row.polled_climate ?? null,
      driverTempSettingC: row.polled_driver_temp ?? null, locked: null, sentryMode: null, odometerKm: row.odometer ?? null,
      location: row.latitude == null ? null : { latitude: row.latitude, longitude: row.longitude, heading: null, address: row.address ?? null, placeName: row.place_name ?? null }, firmware: row.firmware ?? null };
  }
  private driveSelect(source = this.sql`public.drives`) {
    const s = this.sql, efficiency = s`eff.value`;
    return s`WITH rated_efficiency AS MATERIALIZED (SELECT car.id, ${this.efficiency()} AS value FROM public.cars car)
      SELECT d.id, to_char(d.start_date, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS "_cursorStart", d.start_date AS start, d.end_date AS end,
      COALESCE(sg.name, sa.display_name) AS "startAddress", COALESCE(eg.name, ea.display_name) AS "endAddress",
      COALESCE(d.distance, COALESCE(d.end_km, ep.odometer) - COALESCE(d.start_km, sp.odometer)) AS "distanceKm",
      COALESCE(d.duration_min, extract(epoch FROM (COALESCE(d.end_date, now() AT TIME ZONE 'UTC') - d.start_date))/60) AS "durationMin",
      sp.battery_level AS "startBatteryLevel", ep.battery_level AS "endBatteryLevel",
      (COALESCE(d.start_rated_range_km, first_range.rated_battery_range_km) - COALESCE(d.end_rated_range_km, last_range.rated_battery_range_km)) * ${efficiency} AS "energyUsedKwh",
      (COALESCE(d.start_rated_range_km, first_range.rated_battery_range_km) - COALESCE(d.end_rated_range_km, last_range.rated_battery_range_km)) * ${efficiency} * 1000 / NULLIF(COALESCE(d.distance, COALESCE(d.end_km, ep.odometer) - COALESCE(d.start_km, sp.odometer)), 0) AS "efficiencyWhPerKm",
      d.speed_max AS "maxSpeedKph", COALESCE(d.distance, COALESCE(d.end_km, ep.odometer) - COALESCE(d.start_km, sp.odometer)) * 60 / NULLIF(COALESCE(d.duration_min, extract(epoch FROM(COALESCE(d.end_date, now() AT TIME ZONE 'UTC')-d.start_date))/60),0) AS "avgSpeedKph", d.outside_temp_avg AS "outsideTempAvgC"
      FROM ${source} d JOIN rated_efficiency eff ON eff.id = d.car_id
      LEFT JOIN public.positions startpoint ON startpoint.id = d.start_position_id
      LEFT JOIN LATERAL (SELECT * FROM public.positions WHERE d.start_position_id IS NULL AND drive_id = d.id AND odometer IS NOT NULL ORDER BY date, id LIMIT 1) live_start ON true
      LEFT JOIN LATERAL (SELECT COALESCE(startpoint.odometer, live_start.odometer) AS odometer, COALESCE(startpoint.battery_level, live_start.battery_level) AS battery_level,
        COALESCE(startpoint.rated_battery_range_km, live_start.rated_battery_range_km) AS rated_battery_range_km) sp ON true
      LEFT JOIN public.positions endpoint ON endpoint.id = d.end_position_id
      LEFT JOIN LATERAL (SELECT * FROM public.positions WHERE d.end_position_id IS NULL AND drive_id = d.id ORDER BY date DESC, id DESC LIMIT 1) live ON true
      LEFT JOIN LATERAL (SELECT COALESCE(endpoint.odometer, live.odometer) AS odometer, COALESCE(endpoint.battery_level, live.battery_level) AS battery_level, COALESCE(endpoint.rated_battery_range_km, live.rated_battery_range_km) AS rated_battery_range_km) ep ON true
      LEFT JOIN LATERAL (SELECT rated_battery_range_km FROM public.positions WHERE d.start_rated_range_km IS NULL AND drive_id = d.id AND ideal_battery_range_km IS NOT NULL AND odometer IS NOT NULL ORDER BY date, id LIMIT 1) first_range ON true
      LEFT JOIN LATERAL (SELECT rated_battery_range_km FROM public.positions WHERE d.end_rated_range_km IS NULL AND drive_id = d.id AND ideal_battery_range_km IS NOT NULL AND odometer IS NOT NULL ORDER BY date DESC, id DESC LIMIT 1) last_range ON true
      LEFT JOIN public.addresses sa ON sa.id = d.start_address_id LEFT JOIN public.addresses ea ON ea.id = d.end_address_id
      LEFT JOIN public.geofences sg ON sg.id = d.start_geofence_id LEFT JOIN public.geofences eg ON eg.id = d.end_geofence_id`;
  }
  requireDrive(row: Row) {
    if (row.distanceKm == null || row.durationMin == null) throw new ApiError(409, 'data_unavailable', 'TeslaMate has not recorded distance or duration for this drive');
  }
  private measurableDrive() {
    return this.sql`CASE WHEN d.distance IS NOT NULL THEN true ELSE
      COALESCE(d.start_km, (SELECT odometer FROM public.positions WHERE id = d.start_position_id),
        (SELECT odometer FROM public.positions WHERE d.start_position_id IS NULL AND drive_id = d.id AND odometer IS NOT NULL ORDER BY date, id LIMIT 1)) IS NOT NULL
      AND COALESCE(d.end_km, (SELECT odometer FROM public.positions WHERE id = d.end_position_id),
        (SELECT odometer FROM public.positions WHERE d.end_position_id IS NULL AND drive_id = d.id ORDER BY date DESC, id DESC LIMIT 1)) IS NOT NULL END`;
  }
  async drives(id: number, q: ListInput) {
    const source = this.sql`(SELECT d.* FROM public.drives d WHERE car_id = ${id} AND ${this.measurableDrive()}
      AND (${q.from}::timestamp IS NULL OR start_date >= ${q.from}::timestamp)
      AND (${q.to}::timestamp IS NULL OR start_date < ${q.to}::timestamp)
      AND (${q.before}::timestamp IS NULL OR (start_date, id) < (${q.before}::timestamp, ${q.beforeId}::integer))
      ORDER BY start_date DESC, id DESC LIMIT ${q.limit + 1})`;
    const rows = await this.sql`${this.driveSelect(source)} ORDER BY d.start_date DESC, d.id DESC`;
        return rows;
  }
  async drive(id: number) {
    const [summary] = await this.sql`${this.driveSelect()} WHERE d.id = ${id}`;
    if (!summary) throw missing();
    const path = await this.sql`SELECT date AS t, latitude, longitude, speed AS "speedKph", power AS "powerKw", elevation AS "elevationM", battery_level AS "batteryLevel" FROM public.positions WHERE drive_id = ${id} ORDER BY date, id`;
    const [elevation] = await this.sql`SELECT ascent AS "elevationGainM" FROM public.drives WHERE id = ${id}`;
    const { _cursorStart, ...fields } = summary;
    this.requireDrive(fields);
    return { ...fields, path, elevationGainM: elevation?.elevationGainM ?? null,
      ...(this.fleetEnabled ? {telemetry:await this.fleetSession('drive',id)} : {}) };
  }
  async serviceOdometer(id: number) {
    const [tm] = await this.sql`SELECT km AS "odometerKm",t AS "recordedAt" FROM (
      (SELECT odometer AS km,date AS t FROM public.positions WHERE car_id=${id} AND odometer>=0 AND date<=now() AT TIME ZONE 'UTC' ORDER BY date DESC,id DESC LIMIT 1)
      UNION ALL
      (SELECT end_km,end_date FROM public.drives WHERE car_id=${id} AND end_km>=0 AND end_date<=now() AT TIME ZONE 'UTC' ORDER BY end_date DESC,id DESC LIMIT 1)
    ) observations ORDER BY t DESC LIMIT 1`;
    let result = { odometerKm: tm?.odometerKm ?? null, recordedAt: tm?.recordedAt ?? null, source: tm ? 'teslamate' : null };
    if (this.fleetEnabled) {
      try {
        const [binding] = await this.sql`SELECT b.vin_digest,c.vin FROM volta_telemetry.api_vehicle_bindings b JOIN public.cars c ON c.id=b.vehicle_id WHERE b.vehicle_id=${id}`;
        if (binding?.vin && /^[A-HJ-NPR-Z0-9]{17}$/.test(binding.vin) && binding.vin_digest === createHash('sha256').update('volta-telemetry-vin-binding-v1\0').update(binding.vin).digest('hex')) {
          const [live] = await this.sql`SELECT odometer_km AS "odometerKm",source_ts AS "recordedAt" FROM volta_telemetry.service_odometer WHERE vehicle_id=${id} AND source_ts<=now() ORDER BY source_ts DESC LIMIT 1`;
          if (live?.odometerKm != null && live.odometerKm >= 0 && (!result.recordedAt || new Date(live.recordedAt)>new Date(result.recordedAt))) result = { odometerKm: live.odometerKm, recordedAt: live.recordedAt, source: 'fleet_telemetry' };
        }
      } catch { this.log({event:'service_odometer_unavailable',category:'optional_telemetry'}); }
    }
    return result;
  }
  private chargeLocationKey() {
    return this.sql`CASE WHEN cp.geofence_id IS NOT NULL THEN 'g:'||cp.geofence_id
      WHEN cp.address_id IS NOT NULL THEN 'a:'||cp.address_id ELSE 's:'||cp.id END`;
  }
  async chargerLocations(id: number) {
    return this.sql`WITH sessions AS (
      SELECT ${this.chargeLocationKey()} AS id,cp.start_date,cp.cost,cp.charge_energy_added AS energy,
        COALESCE(g.name,a.display_name,'Recorded charging location') AS name,
        COALESCE(g.latitude,p.latitude,a.latitude) AS latitude,COALESCE(g.longitude,p.longitude,a.longitude) AS longitude,
        cp.charge_energy_used/NULLIF(cp.duration_min/60.0,0) AS power
      FROM public.charging_processes cp LEFT JOIN public.geofences g ON g.id=cp.geofence_id
      LEFT JOIN public.addresses a ON a.id=cp.address_id LEFT JOIN public.positions p ON p.id=cp.position_id WHERE cp.car_id=${id}
    ) SELECT id,max(name) AS name,
      (array_agg(latitude ORDER BY start_date DESC) FILTER(WHERE latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180))[1] AS latitude,
      (array_agg(longitude ORDER BY start_date DESC) FILTER(WHERE latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180))[1] AS longitude,
      count(*)::integer AS "sessionCount",max(start_date) AS "lastVisit",
      CASE WHEN count(energy)=count(*) THEN sum(energy) END AS "energyAddedKwh",
      avg(power) AS "avgPowerKw",count(power)::integer AS "powerSessionCount",
      CASE WHEN count(cost)=count(*) THEN sum(cost) END AS cost,${this.currency}::text AS currency
      FROM sessions GROUP BY id ORDER BY "lastVisit" DESC,id`;
  }
  async chargerSessions(id: number, location: string, q: ListInput) {
    return this.sql`${this.chargeSelect()} WHERE cp.car_id=${id} AND ${this.chargeLocationKey()}=${location}
      AND (${q.from}::timestamp IS NULL OR cp.start_date>=${q.from}::timestamp)
      AND (${q.to}::timestamp IS NULL OR cp.start_date<${q.to}::timestamp)
      AND (${q.before}::timestamp IS NULL OR (cp.start_date,cp.id)<(${q.before}::timestamp,${q.beforeId}::integer))
      ORDER BY cp.start_date DESC,cp.id DESC LIMIT ${q.limit+1}`;
  }
  private chargeSelect() {
    const s = this.sql;
    return s`SELECT cp.id, to_char(cp.start_date, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS "_cursorStart", cp.start_date AS start, cp.end_date AS end, a.display_name AS address, g.name AS "placeName",
      cp.charge_energy_added AS "energyAddedKwh", cp.charge_energy_used AS "energyUsedKwh", cp.start_battery_level AS "startBatteryLevel", cp.end_battery_level AS "endBatteryLevel",
      COALESCE(p.latitude, a.latitude) AS latitude, COALESCE(p.longitude, a.longitude) AS longitude,
      COALESCE(cp.duration_min, extract(epoch FROM (COALESCE(cp.end_date, now() AT TIME ZONE 'UTC') - cp.start_date))/60) AS "durationMin",
      stats.max_power AS "maxPowerKw", COALESCE(stats.fast, false) AS "fastCharger", cp.cost, ${this.currency}::text AS currency, cp.outside_temp_avg AS "outsideTempAvgC"
      FROM public.charging_processes cp LEFT JOIN public.addresses a ON a.id = cp.address_id LEFT JOIN public.geofences g ON g.id = cp.geofence_id
      LEFT JOIN public.positions p ON p.id = cp.position_id
      LEFT JOIN LATERAL (SELECT max(charger_power) AS max_power, bool_or(fast_charger_present) AS fast FROM public.charges WHERE charging_process_id = cp.id) stats ON true`;
  }
  async charges(id: number, q: ListInput) {
    return this.sql`${this.chargeSelect()} WHERE cp.car_id = ${id}
      AND (${q.from}::timestamp IS NULL OR cp.start_date >= ${q.from}::timestamp)
      AND (${q.to}::timestamp IS NULL OR cp.start_date < ${q.to}::timestamp)
      AND (${q.before}::timestamp IS NULL OR (cp.start_date, cp.id) < (${q.before}::timestamp, ${q.beforeId}::integer))
      ORDER BY cp.start_date DESC, cp.id DESC LIMIT ${q.limit + 1}`;
  }
  async charge(id: number) {
    const [summary] = await this.sql`${this.chargeSelect()} WHERE cp.id = ${id}`;
    if (!summary) throw missing();
    const samples = await this.sql`SELECT date AS t, battery_level AS "batteryLevel", charger_power AS "powerKw", charger_voltage AS voltage, charger_actual_current AS "currentA", rated_battery_range_km AS "ratedRangeKm" FROM public.charges WHERE charging_process_id = ${id} ORDER BY date, id`;
    const { _cursorStart, ...fields } = summary;
    return { ...fields, samples, efficiency: summary.energyUsedKwh > 0 && summary.energyAddedKwh != null ? summary.energyAddedKwh / summary.energyUsedKwh : null,
      ...(this.fleetEnabled ? {telemetry:await this.fleetSession('charge',id)} : {}) };
  }
  private idleCTE(id: number) {
    const s = this.sql;
    return s`WITH rates AS MATERIALIZED (SELECT car.id, ${this.efficiency()} AS value FROM public.cars car WHERE car.id = ${id}),
    activities AS (
      SELECT id::bigint * 2 AS key, start_date AS start, COALESCE(end_date, now() AT TIME ZONE 'UTC') AS finish,
        start_position_id, end_position_id, start_rated_range_km, NULL::integer AS charge_id, end_address_id AS address_id, end_geofence_id AS geofence_id
      FROM public.drives WHERE car_id = ${id}
      UNION ALL SELECT id::bigint * 2 + 1, start_date, COALESCE(end_date, now() AT TIME ZONE 'UTC'),
        position_id, position_id, NULL::numeric, id, address_id, geofence_id FROM public.charging_processes WHERE car_id = ${id}
    ), running AS (
      SELECT *, max(finish) OVER (ORDER BY start, key ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prior_end FROM activities
    ), grouped AS (
      SELECT *, sum(CASE WHEN prior_end IS NULL OR start > prior_end THEN 1 ELSE 0 END) OVER (ORDER BY start, key) AS grp FROM running
    ), islands AS (
      SELECT min(start) AS start, max(finish) AS finish,
        (array_agg(key ORDER BY start, key))[1] AS first_key,
        (array_agg(key ORDER BY finish DESC, key DESC))[1] AS id FROM grouped GROUP BY grp
    ), gaps AS (
      SELECT id, finish AS start, lead(start) OVER (ORDER BY start, id) AS finish,
        lead(first_key) OVER (ORDER BY start, id) AS next_key FROM islands
    ), boundaries AS (
      SELECT gap.*, prev.address_id, prev.geofence_id, prev.end_position_id AS location_position_id,
        CASE WHEN prev.charge_id IS NOT NULL THEN last_charge.battery_level ELSE ep.battery_level END AS start_battery,
        CASE WHEN upcoming.charge_id IS NOT NULL THEN first_charge.battery_level ELSE COALESCE(sp.battery_level, live_start.battery_level) END AS end_battery,
        CASE WHEN prev.charge_id IS NOT NULL THEN last_charge.rated_battery_range_km ELSE ep.rated_battery_range_km END AS start_range,
        CASE WHEN upcoming.charge_id IS NOT NULL THEN first_charge.rated_battery_range_km ELSE COALESCE(upcoming.start_rated_range_km, first_poll.rated_battery_range_km) END AS end_range
      FROM gaps gap JOIN activities prev ON prev.key = gap.id JOIN activities upcoming ON upcoming.key = gap.next_key
      LEFT JOIN public.positions ep ON ep.id = prev.end_position_id AND ep.date BETWEEN gap.start - interval '15 minutes' AND gap.start
      LEFT JOIN public.positions sp ON sp.id = upcoming.start_position_id AND sp.date BETWEEN gap.finish - interval '15 minutes' AND gap.finish + interval '15 minutes'
      LEFT JOIN LATERAL (SELECT battery_level, rated_battery_range_km FROM public.positions
        WHERE upcoming.charge_id IS NULL AND upcoming.start_position_id IS NULL AND drive_id = upcoming.key/2
        AND date BETWEEN gap.finish-interval '15 minutes' AND gap.finish+interval '15 minutes' ORDER BY date,id LIMIT 1) live_start ON true
      LEFT JOIN LATERAL (SELECT rated_battery_range_km FROM public.positions
        WHERE upcoming.charge_id IS NULL AND upcoming.start_rated_range_km IS NULL AND drive_id = upcoming.key/2
        AND ideal_battery_range_km IS NOT NULL AND odometer IS NOT NULL
        AND date BETWEEN gap.finish-interval '15 minutes' AND gap.finish+interval '15 minutes' ORDER BY date,id LIMIT 1) first_poll ON true
      LEFT JOIN LATERAL (SELECT battery_level, rated_battery_range_km FROM public.charges WHERE prev.charge_id IS NOT NULL AND charging_process_id = prev.charge_id
        AND date BETWEEN gap.start - interval '15 minutes' AND gap.start ORDER BY date DESC, id DESC LIMIT 1) last_charge ON true
      LEFT JOIN LATERAL (SELECT battery_level, rated_battery_range_km FROM public.charges WHERE upcoming.charge_id IS NOT NULL AND charging_process_id = upcoming.charge_id
        AND date BETWEEN gap.finish AND gap.finish + interval '15 minutes' ORDER BY date, id LIMIT 1) first_charge ON true
      WHERE gap.finish IS NOT NULL AND gap.finish > gap.start
    ), idles AS (
      SELECT gap.id::float8 AS id, to_char(gap.start, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS "_cursorStart", gap.start, gap.finish AS end,
        a.display_name AS address, geo.name AS "placeName", extract(epoch FROM (gap.finish-gap.start))/60 AS "durationMin",
        gap.location_position_id AS "_locationPositionId",
        gap.start_battery AS "startBatteryLevel", gap.end_battery AS "endBatteryLevel",
        CASE WHEN gap.start_range IS NULL OR gap.end_range IS NULL THEN NULL ELSE greatest(gap.start_range-gap.end_range,0) END AS "rangeLostKm",
        CASE WHEN gap.start_range IS NULL OR gap.end_range IS NULL THEN NULL ELSE greatest(gap.start_range-gap.end_range,0)*rates.value END AS "energyLostKwh",
        NULL::float8 AS "sentryMinutes", NULL::float8 AS "climateMinutes", NULL::float8 AS "asleepMinutes"
      FROM boundaries gap CROSS JOIN rates
      LEFT JOIN public.addresses a ON a.id = gap.address_id LEFT JOIN public.geofences geo ON geo.id = gap.geofence_id
    )`;
  }
  async idles(id: number, q: ListInput) {
    const rows = await this.sql`${this.idleCTE(id)} SELECT * FROM idles WHERE "durationMin" > ${q.minMinutes}
      AND (${q.from}::timestamp IS NULL OR start >= ${q.from}::timestamp)
      AND (${q.to}::timestamp IS NULL OR start < ${q.to}::timestamp)
      AND (${q.before}::timestamp IS NULL OR (start, id) < (${q.before}::timestamp, ${q.beforeId}::bigint))
      ORDER BY start DESC, id DESC LIMIT ${q.limit + 1}`;
    // One bounded chronological sweep for the visible page, not a position scan per idle.
    if (!rows.length) return rows;
    const selected = rows.slice(0, q.limit);
    // Hydrate only the visible page. Read the missing endpoints' position window
    // once: per-gap BRIN probes repeatedly recheck the same lossy heap ranges.
    const locations = selected.map(r => ({ id: r.id, start: r._cursorStart, position_id: r._locationPositionId }));
    const coordinates = await this.sql`WITH gaps AS (SELECT * FROM jsonb_to_recordset(${this.sql.json(locations)}) AS g(id float8, start timestamp, position_id integer)),
      anchored AS MATERIALIZED (SELECT g.id, g.start, p.latitude, p.longitude
        FROM gaps g LEFT JOIN public.positions p ON p.id = g.position_id AND p.car_id = ${id}),
      missing AS MATERIALIZED (SELECT id, start FROM anchored WHERE latitude IS NULL),
      candidates AS MATERIALIZED (SELECT p.id, p.date, p.latitude, p.longitude FROM public.positions p WHERE p.car_id = ${id}
        AND p.date >= (SELECT min(start)-interval '15 minutes' FROM missing)
        AND p.date <= (SELECT max(start)+interval '15 minutes' FROM missing)),
      nearest AS (SELECT DISTINCT ON (g.id) g.id, p.latitude, p.longitude FROM missing g JOIN candidates p
        ON p.date BETWEEN g.start-interval '15 minutes' AND g.start+interval '15 minutes'
        ORDER BY g.id, abs(extract(epoch FROM (p.date-g.start))), p.date, p.id)
      SELECT a.id, COALESCE(a.latitude, nearest.latitude) AS latitude, COALESCE(a.longitude, nearest.longitude) AS longitude
      FROM anchored a LEFT JOIN nearest USING (id)`;
    const coordinateById = new Map(coordinates.map(r => [r.id, r]));
    for (const row of rows) {
      const location = coordinateById.get(row.id);
      row.latitude = location?.latitude ?? null; row.longitude = location?.longitude ?? null;
      delete row._locationPositionId;
    }
    const from = new Date(Math.min(...selected.map(r => +r.start))-300000), to = new Date(Math.max(...selected.map(r => +r.end)));
    const gaps = selected.map(r => ({ id: r.id, start: r._cursorStart, end: new Date(r.end).toISOString() }));
    const sleep = await this.sql`WITH gaps AS (SELECT * FROM jsonb_to_recordset(${this.sql.json(gaps)}) AS g(id float8, start timestamp, "end" timestamp)),
      coverage AS (SELECT g.id, g.start, g.end, st.state, extract(epoch FROM(least(COALESCE(st.end_date,now() AT TIME ZONE 'UTC'),g.end)-greatest(st.start_date,g.start))) AS seconds
        FROM gaps g LEFT JOIN public.states st ON st.car_id = ${id} AND st.start_date < g.end AND COALESCE(st.end_date,now() AT TIME ZONE 'UTC') > g.start)
      SELECT id, CASE WHEN sum(seconds) >= extract(epoch FROM("end"-start)) THEN COALESCE(sum(seconds) FILTER(WHERE state='asleep'),0)/60 ELSE NULL END AS value
      FROM coverage GROUP BY id,start,"end"`;
    const sleepById = new Map(sleep.map(r => [r.id,r.value]));
    for (const row of selected) row.asleepMinutes = sleepById.get(row.id) ?? null;
    const climate = await this.sql`WITH gaps AS (SELECT *, row_number() OVER (ORDER BY start, id) AS seq FROM jsonb_to_recordset(${this.sql.json(gaps)}) AS g(id float8, start timestamp, "end" timestamp)),
      points AS (SELECT date, is_climate_on, lead(date) OVER (ORDER BY date, id) AS next_date FROM public.positions WHERE car_id = ${id} AND date >= ${from} AND date < ${to}),
      spans AS (SELECT is_climate_on, date AS start, least(COALESCE(next_date, date+interval '5 minutes'), date+interval '5 minutes', ${to}::timestamp) AS finish FROM points WHERE is_climate_on IS NOT NULL),
      events AS (SELECT start AS t, 1 AS gap_delta, 1 AS seq_delta, 0 AS climate_delta, 0 AS known_delta FROM gaps
        UNION ALL SELECT "end", -1, 0, 0, 0 FROM gaps
        UNION ALL SELECT start, 0, 0, CASE WHEN is_climate_on THEN 1 ELSE 0 END, 1 FROM spans WHERE finish > start
        UNION ALL SELECT finish, 0, 0, CASE WHEN is_climate_on THEN -1 ELSE 0 END, -1 FROM spans WHERE finish > start),
      edges AS (SELECT t, sum(gap_delta) AS gd, sum(seq_delta) AS sd, sum(climate_delta) AS cd, sum(known_delta) AS kd FROM events GROUP BY t),
      sweep AS (SELECT t, lead(t) OVER (ORDER BY t) AS next_t, sum(gd) OVER (ORDER BY t) AS active_gap,
        sum(sd) OVER (ORDER BY t) AS seq, sum(cd) OVER (ORDER BY t) AS active_climate, sum(kd) OVER (ORDER BY t) AS active_known FROM edges),
      minutes AS (SELECT seq, COALESCE(sum(extract(epoch FROM(next_t-t))) FILTER(WHERE active_climate>0),0)/60 AS value FROM sweep WHERE active_gap>0 AND active_known>0 GROUP BY seq)
      SELECT gaps.id, minutes.value FROM gaps LEFT JOIN minutes USING(seq)`;
    const byId = new Map(climate.map(r => [r.id, r.value]));
    for (const row of selected) row.climateMinutes = byId.get(row.id) ?? null;
    return rows;
  }
  async summary(id: number, range: 'today' | '7d' | '30d', timeZone = 'UTC') {
    const s = this.sql;
    // Resolve once so reported bounds and both aggregates use the same instant.
    // Use Bun's IANA rules, matching Intl validation and avoiding Postgres
    // abbreviation precedence or an older database's time-zone catalog.
    const period = summaryPeriod(this.clock(), range, timeZone);
    const [row] = await s`WITH bounds AS MATERIALIZED (SELECT ${period.periodStart}::timestamp AS start, ${period.periodEnd}::timestamp AS finish),
      drives AS (${this.driveSelect()} WHERE d.car_id = ${id} AND d.start_date >= (SELECT start FROM bounds) AND d.start_date < (SELECT finish FROM bounds) AND ${this.measurableDrive()}),
      charges AS (SELECT * FROM public.charging_processes WHERE car_id = ${id} AND start_date >= (SELECT start FROM bounds) AND start_date < (SELECT finish FROM bounds))
      SELECT ${range}::text AS range, (SELECT start FROM bounds) AS "periodStart", (SELECT finish FROM bounds) AS "periodEnd", ${timeZone}::text AS "timeZone",
      COALESCE((SELECT sum("distanceKm") FROM drives), 0) AS "distanceKm",
      (SELECT count(*)::integer FROM drives WHERE "distanceKm" IS NULL) AS "_missingDistance", (SELECT count(*)::integer FROM drives) AS "driveCount",
      (SELECT count(*)::integer FROM charges) AS "chargeCount", (SELECT CASE WHEN count(*) FILTER (WHERE "energyUsedKwh" IS NULL) > 0 THEN NULL ELSE sum("energyUsedKwh") END FROM drives) AS "energyUsedKwh",
      (SELECT CASE WHEN count(*) FILTER (WHERE "energyUsedKwh" IS NULL) > 0 THEN NULL ELSE sum("energyUsedKwh") * 1000 / NULLIF(sum("distanceKm"), 0) END FROM drives) AS "efficiencyWhPerKm",
      (SELECT CASE WHEN count(*) FILTER (WHERE charge_energy_added IS NULL) > 0 THEN NULL ELSE sum(charge_energy_added) END FROM charges) AS "energyAddedKwh", (SELECT CASE WHEN count(*) FILTER (WHERE cost IS NULL) > 0 THEN NULL ELSE sum(cost) END FROM charges) AS "chargeCost", ${this.currency}::text AS currency`;
    if (row?._missingDistance) throw new ApiError(409, 'data_unavailable', 'TeslaMate has incomplete drive distance for this summary');
    const { _missingDistance, ...fields } = row!;
    return fields;
  }
  async mileage(id: number, bucket: 'day' | 'week' | 'month') {
    const rows = await this.sql`WITH drives AS (${this.driveSelect()} WHERE d.car_id = ${id} AND ${this.measurableDrive()})
      SELECT date_trunc(${bucket}, start) AS start, sum("distanceKm") AS "distanceKm", count(*)::integer AS "driveCount", CASE WHEN count(*) FILTER (WHERE "energyUsedKwh" IS NULL) > 0 THEN NULL ELSE sum("energyUsedKwh") END AS "energyUsedKwh",
      count(*) FILTER (WHERE "distanceKm" IS NULL)::integer AS "_missingDistance"
      FROM drives GROUP BY 1 ORDER BY 1 DESC`;
    if (rows.some(row => row._missingDistance)) throw new ApiError(409, 'data_unavailable', 'TeslaMate has incomplete drive distance for these mileage buckets');
    return rows.map(({ _missingDistance, ...fields }) => fields);
  }
  async firmware(id: number) {
    return this.sql`SELECT version, end_date AS "installedAt", lag(version) OVER (ORDER BY end_date, id) AS "previousVersion" FROM public.updates
      WHERE car_id = ${id} AND end_date IS NOT NULL AND version IS NOT NULL ORDER BY end_date DESC, id DESC`;
  }
  async places() {
    return this.sql`SELECT id, name, latitude, longitude, radius AS "radiusM", CASE WHEN billing_type = 'per_kwh' THEN cost_per_unit ELSE NULL END AS "costPerKwh" FROM public.geofences ORDER BY name, id`;
  }
  async timeline(id: number, hours: number) {
    const s = this.sql;
    const rows = await s`SELECT 'drive' AS kind, start_date AS start, end_date AS end FROM public.drives WHERE car_id = ${id} AND start_date < now() AT TIME ZONE 'UTC' AND COALESCE(end_date, now() AT TIME ZONE 'UTC') > now() AT TIME ZONE 'UTC' - ${hours} * interval '1 hour'
      UNION ALL SELECT 'charge', start_date, end_date FROM public.charging_processes WHERE car_id = ${id} AND start_date < now() AT TIME ZONE 'UTC' AND COALESCE(end_date, now() AT TIME ZONE 'UTC') > now() AT TIME ZONE 'UTC' - ${hours} * interval '1 hour'
      UNION ALL SELECT CASE WHEN state = 'online' THEN 'idle' ELSE state::text END, start_date, end_date FROM public.states WHERE car_id = ${id} AND start_date < now() AT TIME ZONE 'UTC' AND COALESCE(end_date, now() AT TIME ZONE 'UTC') > now() AT TIME ZONE 'UTC' - ${hours} * interval '1 hour'`;
    // Split on all boundaries, with activity taking priority over logger state. No overlapping segments.
    const end = Date.now(), start = end - hours * 3600000;
    const spans = rows.map(r => ({ kind: r.kind as string, start: Math.max(start, +r.start), end: Math.min(end, r.end ? +r.end : end) })).filter(r => r.end > r.start);
    const edges = [...new Set(spans.flatMap(r => [r.start, r.end]))].sort((a, b) => a-b);
    const result: { kind: string; start: Date; end: Date }[] = [];
    const priority: Record<string, number> = { drive: 5, charge: 4, asleep: 3, offline: 2, idle: 1 };
    for (let i=0; i<edges.length-1; i++) {
      const a = edges[i]!, b = edges[i+1]!;
      const active = spans.filter(r => r.start <= a && r.end >= b).sort((x,y) => priority[y.kind]! - priority[x.kind]!)[0];
      if (!active) continue;
      const last = result.at(-1);
      if (last && last.kind === active.kind && +last.end === a) last.end = new Date(b);
      else result.push({ kind: active.kind, start: new Date(a), end: new Date(b) });
    }
    return result.reverse();
  }
  async battery(id: number) {
    const s = this.sql;
    const [stats] = await s`WITH efficiency AS MATERIALIZED (SELECT ${this.efficiency()} AS kwh_km FROM public.cars car WHERE car.id = ${id}),
      eligible AS MATERIALIZED (SELECT cp.id, cp.end_date, efficiency.kwh_km FROM public.charging_processes cp CROSS JOIN efficiency
        WHERE cp.car_id = ${id} AND cp.end_date IS NOT NULL AND cp.charge_energy_added >= efficiency.kwh_km * 100
        AND EXISTS(SELECT 1 FROM public.charges WHERE charging_process_id = cp.id AND usable_battery_level > 0)),
      last_samples AS (SELECT ch.rated_battery_range_km, ch.usable_battery_level, cp.kwh_km FROM eligible cp
        CROSS JOIN LATERAL (SELECT rated_battery_range_km, usable_battery_level FROM (
          SELECT id, date, rated_battery_range_km, usable_battery_level FROM public.charges WHERE charging_process_id = cp.id AND usable_battery_level > 0 OFFSET 0
        ) samples ORDER BY date DESC, id DESC LIMIT 1) ch),
      recent AS (SELECT * FROM eligible ORDER BY end_date DESC FETCH FIRST 100 ROWS WITH TIES),
      current AS (SELECT ch.rated_battery_range_km * cp.kwh_km * 100 / ch.usable_battery_level AS capacity
        FROM recent cp JOIN public.charges ch ON ch.charging_process_id = cp.id WHERE ch.usable_battery_level > 0 ORDER BY cp.end_date DESC, ch.date DESC, ch.id DESC LIMIT 100),
      observations AS ((SELECT date, rated_battery_range_km, usable_battery_level FROM public.positions WHERE car_id = ${id} AND usable_battery_level > 0 AND rated_battery_range_km IS NOT NULL ORDER BY date DESC, id DESC LIMIT 1)
        UNION ALL (SELECT ch.date, ch.rated_battery_range_km, ch.usable_battery_level FROM public.charges ch JOIN public.charging_processes cp ON cp.id = ch.charging_process_id WHERE cp.car_id = ${id} AND ch.usable_battery_level > 0 AND ch.rated_battery_range_km IS NOT NULL ORDER BY ch.date DESC, ch.id DESC LIMIT 1))
      SELECT (SELECT max(rated_battery_range_km * kwh_km * 100 / usable_battery_level) FROM last_samples) AS "capacityNewKwh",
        (SELECT avg(capacity) FROM current) AS "capacityNowKwh",
        (SELECT rated_battery_range_km * 100 / usable_battery_level FROM observations ORDER BY date DESC LIMIT 1) AS "ratedRangeAt100Km"`;
    const history = await s`WITH efficiency AS MATERIALIZED (SELECT ${this.efficiency()} AS value FROM public.cars car WHERE car.id = ${id}),
      daily AS (SELECT date_trunc('day', ch.date) AS date, sum(ch.rated_battery_range_km) * 100 / NULLIF(sum(ch.usable_battery_level), 0) AS range
        FROM public.charges ch JOIN public.charging_processes cp ON cp.id = ch.charging_process_id
        WHERE cp.car_id = ${id} AND ch.usable_battery_level > 0 AND ch.rated_battery_range_km IS NOT NULL GROUP BY 1)
      SELECT daily.date, daily.range AS "ratedRangeAt100Km", daily.range * efficiency.value AS "capacityKwh" FROM daily CROSS JOIN efficiency ORDER BY 1 DESC`;
    const [drain] = await s`${this.idleCTE(id)} SELECT sum(greatest("startBatteryLevel" - "endBatteryLevel", 0)) / NULLIF(sum("durationMin") / 1440, 0) AS value FROM idles
      WHERE "startBatteryLevel" IS NOT NULL AND "endBatteryLevel" IS NOT NULL AND "durationMin" > 10`;
    return { ...stats, healthPercent: stats?.capacityNewKwh > 0 && stats?.capacityNowKwh != null ? Math.min(100, stats.capacityNowKwh / stats.capacityNewKwh * 100) : null,
      history, avgIdleDrainPctPerDay: drain?.value ?? null };
  }
}
