# volta-api v1 contract

Base URL: `https://<ubuntu-node>.<tailnet>.ts.net` (via `tailscale serve`).
JSON, camelCase keys, ISO-8601 UTC timestamps, metric units. Every endpoint
except `/v1/health` and `/v1/auth/pair` requires `Authorization: Bearer <token>`.
Errors: `{ "error": { "code": "not_found", "message": "…" } }` with matching
HTTP status. `null` means "unknown / not recorded", never zero.

The Swift mirror of these shapes is `ios/Volta/Core/Models.swift`. Keep both in
sync; change additively.

## Fleet Telemetry detail (operator opt-in)

`FLEET_TELEMETRY_ENABLED=true` adds `telemetry` to drive/charge detail; null means
no exact-bound recorded history in that session window. Disabled APIs omit it.

```text
FleetTelemetrySeries {source:"fleet_telemetry",samples:[FleetTelemetrySample],
                      gaps:[{start,end,reason}],coverage:FleetTelemetryCoverage,
                      downsampled:boolean,truncated:boolean}
FleetTelemetrySample {t,latitude,longitude,speedKph,powerKw,elevationM,batteryLevel,
                      energyRemainingKwh,batteryTempMinC,batteryTempMaxC,insideTempC,
                      outsideTempC,voltage,currentA,ratedRangeKm,routeBreakBefore,
                      longitudinalAccelerationMps2,lateralAccelerationMps2,invalidFields}
FleetTelemetryCoverage {sessionStart,sessionEnd,sampleStart,sampleEnd,
                        sourceSampleCount,returnedSampleCount,
                        metrics:{sampleField:FleetMetricCoverage}}
FleetMetricCoverage {start,end,sourceSampleCount,returnedSampleCount,
                     densityPerMinute,maxIntervalSeconds,returnedMaxIntervalSeconds,
                     gapCount,receiverGapCount,invalidGapCount,downsampled,truncated}
```

Measurements are nullable metric numbers with no carry-forward. Signal-only rows
need no GPS. `invalidFields` names Tesla fields explicitly invalid/malformed or
conflicting, distinct from absent observations; `Power` marks unusable electrical
power. Known gaps forbid interpolation. A receiver gap is real data loss: a
disconnected/silence span of at least 90s (shorter cadence rows are ignored,
seams <=1s coalesced); invalid gear/charge spans pass through. Drive
`interrupted`, route breaks (>120s or real loss) and energy nulling use only
real loss. Telemetry drives join across a stop <10 min that follows an observed
Park (the resume may start `gear`, `first_observed` or `speed`), or a <60s seam with
speed >5 km/h within 15s on both sides, never across real loss or invalid gear. At most 2,000 samples cover the complete
session: each metric's first, last, minimum and maximum valid observations are
retained. Explicit invalid observations and the neighboring metric observations
that delimit their unknown spans take priority. Time buckets retain one row per
metric with observations in that bucket, plus a generic row; unused slots receive
an additional even time selection. This preserves slow metrics whose fields
arrive separately from fast signals while respecting the total row bound. `downsampled`
distinguishes this bounded whole-session representation from source data. Coverage
counts, bounds, density and intervals are calculated from the complete source
series; `densityPerMinute` is a nullable number and is null when the session
duration is zero (undefined density). `maxIntervalSeconds` and
`returnedMaxIntervalSeconds` are null when fewer than two valid observations
exist; the latter describes the points actually returned.
`receiverGapCount` uses the complete receiver gap set, `invalidGapCount` counts
runs of explicit invalid observations, and `gapCount` is their sum. At most 2,000 gaps are returned; envelope
`truncated` means gaps were omitted, while a metric's `truncated` means an omitted
gap intersects that metric's coverage or its invalid break boundaries could not
fit in the sample budget. Clients must fail closed when required
coverage is downsampled or truncated beyond what their presentation can support.

Legacy path/samples remain unchanged. Clients treat the telemetry block as
optional: malformed or incompatible telemetry decodes as absent while valid
legacy drive/charge detail remains available. A Fleet Telemetry query failure also preserves
the legacy detail and returns `telemetry:null`; the server logs only a fixed error
code, without query text, values or database error data. Pack power requires operator sign calibration;
charge power is AC/DC input power. Invalid PackCurrent/PackVoltage makes drive power
unknown. Charge power prefers valid positive DC power, then valid positive AC
power; zero is reported only when both inputs are known zero. Invalid/null DC
paired with zero/unavailable AC stays unknown. An invalid unused input keeps its
raw field flag without erasing valid power; `Power` flags an unknown chosen power
when an electrical input is invalid.
Telemetry sample/path `elevationM` reuses only nearby private TeslaMate
SRTM observations (same drive, 60 seconds, 50 metres), otherwise null; drive
detail charts use the optional DEM described under drive rows. Module
temperature units are inferred and need live confirmation. See
[capture](TELEMETRY_CAPTURE.md) and [runbook](TELEMETRY_RUNBOOK.md).

## Health and auth

| Method | Path | Body / query | Response |
|---|---|---|---|
| GET | `/v1/health` | – | `{ ok, version, teslamate: { reachable, lastDataAt } }` |
| POST | `/v1/auth/pair` | `{ code, deviceName }` | `{ token, device: Device }` |
| GET | `/v1/me` | – | `Device` |
| DELETE | `/v1/me` | – | 204 (revokes this token) |

`Device`: `{ id, name, createdAt, lastSeenAt }`

## Vehicles

| Method | Path | Query | Response |
|---|---|---|---|
| GET | `/v1/vehicles` | – | `[Vehicle]` |
| GET | `/v1/vehicles/{id}/status` | – | `VehicleStatus` |
| GET | `/v1/vehicles/{id}/summary` | `range=today\|7d\|30d,tz=UTC` | `ActivitySummary` |
| GET | `/v1/vehicles/{id}/timeline` | `hours=48` | `[TimelineSegment]` |
| GET | `/v1/vehicles/{id}/drives` | `from,to,limit(≤100),cursor` | `Page<DriveSummary>` |
| GET | `/v1/drives/{id}` | – | `DriveDetail` |
| GET | `/v1/vehicles/{id}/charges` | `from,to,limit,cursor` | `Page<ChargeSummary>` |
| GET | `/v1/charges/{id}` | – | `ChargeDetail` |
| GET | `/v1/vehicles/{id}/idles` | `from,to,limit,cursor,minMinutes=10` | `Page<IdleSummary>` |
| GET | `/v1/vehicles/{id}/battery` | – | `BatteryHealth` |
| GET | `/v1/vehicles/{id}/mileage` | `bucket=day\|week\|month` | `[MileageBucket]` |
| GET | `/v1/vehicles/{id}/firmware` | – | `[FirmwareUpdate]` |
| GET | `/v1/vehicles/{id}/places` | – | `[Place]` (TeslaMate geofences) |
| POST | `/v1/vehicles/{id}/commands/{name}` | `{ …params }` | phase 1: 501 `commands_unavailable` |

`Page<T>`: `{ items: [T], nextCursor: string|null }`. Lists are newest first.

### Shapes

```
Vehicle        { id, name, model, trim, exteriorColor, vinSuffix, firmware, hasData }
VehicleStatus  { vehicleId, state: online|asleep|offline|driving|charging|updating,
                 updatedAt, batteryLevel, usableBatteryLevel, ratedRangeKm, estRangeKm,
                 chargeLimit, chargingState: disconnected|stopped|charging|complete|null,
                 chargerPowerKw, minutesToFull, insideTempC, outsideTempC, climateOn,
                 driverTempSettingC, locked, sentryMode, odometerKm,
                 location: Location|null, firmware,
                 packTempMaxC, packTempMinC, energyRemainingKwh, chargePortDoorOpen,
                 chargePortLatch, tpms: { fl, fr, rl, rr }, telemetryFreshness }
TireReading    { pressureBar: number|null, updatedAt: timestamp|null }
TelemetryFreshness { connected: boolean, lastSeenAt: timestamp|null,
                     recordedAt: { telemetryField: timestamp } }
Location       { latitude, longitude, heading, address, placeName }
ActivitySummary{ range, distanceKm, driveCount, chargeCount, energyUsedKwh,
                 efficiencyWhPerKm, energyAddedKwh, chargeCost, currency,
                 periodStart, periodEnd, timeZone }
TimelineSegment{ kind: drive|charge|idle|asleep|offline, start, end }
DriveSummary   { id, start, end, startAddress, endAddress, distanceKm, durationMin,
                 startBatteryLevel, endBatteryLevel, energyUsedKwh, efficiencyWhPerKm,
                 maxSpeedKph, avgSpeedKph, outsideTempAvgC, regenKwh?, drivingMin? }
DriveDetail    DriveSummary + { path: [DrivePoint], elevationGainM, elevationLossM?,
                 charts?: DriveCharts | null }
DriveCharts    { start, end, series: { energyRemainingKwh?, batteryLevel?,
                 batteryTempMinC?, batteryTempMaxC?, insideTempC?, outsideTempC?,
                 ratedRangeKm?, speedKph?, elevationM?, powerKw?: [ChartPoint] } }
ChartPoint     { t, v }
DrivePoint     { t, latitude, longitude, speedKph, powerKw, elevationM, batteryLevel }
ChargeSummary  { id, start, end, address, placeName, energyAddedKwh, energyUsedKwh,
                 startBatteryLevel, endBatteryLevel, durationMin, maxPowerKw,
                 fastCharger, cost, currency, outsideTempAvgC,
                 latitude?, longitude?, source?, avgPowerKw?, city?, street?,
                 energyFromGridKwh?, fastChargerBrand? }
ChargeDetail   ChargeSummary + { samples: [ChargeSample], efficiency }
ChargeSample   { t, batteryLevel, powerKw, voltage, currentA, ratedRangeKm }
IdleSummary    { id, start, end, address, placeName, durationMin, startBatteryLevel,
                 endBatteryLevel, rangeLostKm, energyLostKwh, sentryMinutes,
                 climateMinutes, asleepMinutes, latitude?, longitude? }
BatteryHealth  { capacityNewKwh, capacityNowKwh, healthPercent, ratedRangeAt100Km,
                 history: [{ date, ratedRangeAt100Km, capacityKwh }],
                 avgIdleDrainPctPerDay }
MileageBucket  { start, distanceKm, driveCount, energyUsedKwh }
FirmwareUpdate { version, installedAt, previousVersion }
Place          { id, name, latitude, longitude, radiusM, costPerKwh }
```

Telemetry drive rows (`source:"fleet_telemetry"`, list and detail) follow these
rules. A joined trip spans its first start to its last end, stop included:
`durationMin` and `avgSpeedKph` (= distance / full duration) include the stop;
energy, battery levels, score and efficiency are computed across the whole
window, falling back to the sum of each joined session's measurement when the
whole window cannot be measured. `distanceKm` = end odometer minus the latest
odometer reading at or before the start (change-only: no earlier than 30 min
before the start or the previous trip's start, never across real loss), else
the first reading inside the trip; when the trip (or a joined session) ended in
an observed Park, the end may use a delayed report up to 120s after the end
(before the next trip or session, never across real loss); an open or
gap-ended trip never borrows a later reading. GPS distance remains the fallback; it sums only consecutive positions at most
120s apart that one joined session contains entirely (touching sessions share
their boundary instant), so it never bridges a parked stop (however short) or
other position gap; with no such pair it is unknown, never 0 km. A joined trip whose positions have a gap
at the stop is measured per session, each with its own coverage rules, in list,
detail, summary and mileage alike. List,
summary and mileage use the same distance and energy rules (energy: whole-window
EnergyRemaining, then whole-window pack power, then the sum over joined sessions). `route` is a preview simplified with
Ramer–Douglas–Peucker (5 m tolerance, at most 300 points; the tolerance doubles
over the cap, and even thinning is the last resort); each continuous run is
simplified separately, endpoints are kept and the first point after a break
keeps `routeBreakBefore`, so a parked stop without positions is a break.
`startCity`/`endCity` fall back to the city of the nearest local TeslaMate
address within 3 km when no geofence or address within 150 m matches (the
address stays null). `regenKwh` (number|null, positive kWh) integrates the
negative part of calibrated pack power (positive = discharge) between
consecutive samples at most 30s apart, clipped to the joined sessions (a parked
stop, where the car may even charge, never counts; clipped edges are linearly
interpolated); it is null unless those intervals cover
>=80% of the trip's moving time, with no real loss or invalid pack
voltage/current. TeslaMate rows omit `regenKwh`; clients treat a missing key as unknown.
`drivingMin` (telemetry rows) is the time inside the joined drive sessions,
i.e. `durationMin` minus joined parked stops.

Drive detail adds `charts`, `elevationGainM` and `elevationLossM` (detail only,
never in lists). TeslaMate drives return `charts:null`, `elevationGainM` from
`drives.ascent` and `elevationLossM` from `drives.descent` (null when absent).
For telemetry drives `charts` covers exactly the drive's (joined) window,
`start`..`end` equal to the detail's (an open drive's window may advance while
the detail is built; the charts still cover the detail's own span), and each series is a forward-filled step
line for the client to draw without breaks:
- the first point is at `start` holding the last value observed at or before
  it, looked up to 12 h back (change-only signals such as temperatures or
  range may hold for hours; a newer value always supersedes an older one, so
  bounding the lookup by the previous drive would only lose seeds). A seed is
  discarded when that observation was reported invalid or a real data loss
  separates it from the start (the car resends every field when the stream
  resumes). Without a seed the series starts at the first observation inside
  the drive;
- one point per change (values are rounded first: kWh to 0.01, everything else
  to 0.1), then a final point at `end` holding the last value;
- gaps, data loss and parked stops never break or end a series; observations
  reported invalid are skipped (the step holds), and `powerKw` is unknown
  while PackVoltage/PackCurrent is invalid;
- a metric with no values is omitted entirely; `series` may be `{}`;
- `speedKph`, `powerKw` and `elevationM` are bounded to 600 points: first and
  last points plus the minimum and maximum of each of 299 equal-time buckets.
`ratedRangeKm` is Fleet Telemetry `RatedRange` (miles x 1.609344), the only
range field exposed to the API's read-only views (EstBatteryRange and
IdealBatteryRange are recorded by the normal profile but not exposed; the
economy profile records no range). `batteryLevel` is `BatteryLevel`;
`batteryTempMinC`/`MaxC` are `ModuleTempMin`/`ModuleTempMax`; `powerKw` is
calibrated pack power (positive = discharge).

Fleet Telemetry has no elevation field, and TeslaMate `positions.elevation`
is too sparse to reuse for a profile (positions arrive minutes apart when
TeslaMate is not streaming). Telemetry elevation therefore
comes from an optional offline DEM: set `ELEVATION_DEM_DIR` to a directory of
SRTM/Skadi `.hgt` tiles (`N37/N37W123.hgt` or flat `N37W123.hgt`, `.hgt.gz`
accepted; 1201x1201 or 3601x3601 big-endian int16, -32768 = void, bilinear
interpolation, void posts dropped). The path is sampled every 50 m within
continuous runs (never across a route break; a position jump implying more than
70 m/s is treated as a break; longitude interpolation takes the short way across
the antimeridian) to fill `series.elevationM`; a drive that would need more than
100000 samples (counted exactly, before sampling) gets no `elevationM` and null gain/loss;
`elevationGainM`/`elevationLossM` come from a 5-point median followed by 2 m
hysteresis (the final residual is settled), computed separately for each
continuous run (split at route breaks and terrain voids, so a level change
across a break or void is never counted) and summed, rounded to 0.1 m, and are null unless at least 80% of samples have terrain
data. `elevationMinM`/`elevationMaxM` are the extrema of the full DEM profile,
before chart thinning, or null without terrain data. Without `ELEVATION_DEM_DIR` (or tiles) they are null and `elevationM`
is omitted. The API never downloads tiles. `server/scripts/fetch-elevation-tiles.sh
<dir> --tiles-file <private-manifest>` fetches named public Skadi tiles from
the AWS Open Data `elevation-tiles-prod` bucket. Select tile names on the private
database host, keep the manifest outside git, and send only tile names upstream.
The legacy four bounding-box arguments remain supported; conversion to tile names
is local. There is no default region, and each run accepts at most 400 unique tiles.

With Fleet Telemetry enabled and bound, charge lists merge derived telemetry
charge sessions (`source:"fleet_telemetry"`, negative `id`, accepted by
`/v1/charges/{id}` and cursors) with TeslaMate processes (`source:"teslamate"`).
Telemetry windows and TeslaMate processes linked by overlap resolve as one
group. Telemetry replaces the group's TeslaMate processes only when every
member was read (a failed query keeps the group on TeslaMate), no process is
still open, every measured telemetry charge has a measurable `energyAddedKwh`,
a stop with positive evidence (explicit zero power, a charge-state close or the
next drive; an open or gap-split session without one is unsettled) and no lost
data (gap >=90s), and no lost data or uncovered seam >=90s between fragments
falls inside any process's covered span (earliest overlapping window start to
latest end); otherwise TeslaMate stays and the overlapping partial telemetry is
dropped from lists and totals. An open TeslaMate process groups only up to its
last recorded sample and is never hidden. TeslaMate also remains where
telemetry has no coverage or no reported charge power. Telemetry `start`/`end`
are trimmed to reported AC/DC power >0 and never reach the next drive; the end
is the charging source's first explicit non-positive power, never an invalid or
missing reading (that leaves the stop uncertain). Order, `from/to` and cursors
use the untrimmed session start. Battery levels are rounded BatteryLevel at the
edges; `energyAddedKwh` is the EnergyRemaining delta, else held-power
integration (null across lost data or unknown power). Edge values hold
change-only readings but never across an invalid observation or lost data.
`maxPowerKw` and energy-weighted `avgPowerKw` use the charge power rule below.
`address/placeName/city/street` come from TeslaMate's nearest address (<=150m)
and containing geofence, never an external geocoder. Each replaced TeslaMate
receipt counts once: `cost` sums the receipts assigned to that charge (largest
overlap, then more energy, then earlier), null when it has none or any is
unpriced; summary `chargeCost` counts a charge whose overlapping receipts are
all priced but carried by a sibling. `energyUsedKwh`, `efficiency` and
`energyFromGridKwh` are null (no measured grid energy is exposed). Detail
`samples` hold at most 2,000 thinned points.
Summary charge totals use the merged list; charger locations and timeline remain
TeslaMate-only. `street` is house number plus road, else null.

`ChargeSummary.latitude/longitude` and `IdleSummary.latitude/longitude` are
additive optional fields, returned as numbers or null. Charge list/detail use
the charging process's linked TeslaMate position, falling back to the recorded
address coordinates. Idle list uses the preceding activity's end position (the
drive endpoint or charge position); when absent, it uses the nearest position
for that vehicle within 15 minutes of idle start, with ties resolved by earlier
timestamp then position ID. No observation in that window means null. These
lookups use recorded data and do not call a geocoder. Clients must accept the
fields being absent or null and must not geocode addresses as a substitute; without coordinates a
session is mapped only via a matching `Place` (geofence) name.

`/summary` accepts optional `tz`, an IANA zone name validated with `Intl`
(for example `America/New_York`); omitted means `UTC`. Invalid or empty names
and numeric offsets return 400 `invalid_input` in the standard error envelope.
`today` starts at midnight in that zone. `7d` and `30d` retain their rolling-window
meaning: the same local wall time seven or thirty calendar days earlier, rather
than the start of a calendar week/month. DST can change the elapsed hours in a
window. The additive `periodStart` and `periodEnd` fields are ISO-8601 UTC bounds;
`timeZone` is the resolved zone name. Totals include sessions whose start is
`>= periodStart` and `< periodEnd` (the single request instant), without prorating
sessions spanning a boundary. The default UTC calculation remains unchanged.

Idles are derived: gaps between consecutive drives/charges longer than
`minMinutes`, using TeslaMate `positions`/`states` for battery and state.
Health is derived from TeslaMate's rated range at 100% trend (same approach as
TeslaMate's "Battery Health" Grafana dashboard).

## Tesla-billed charging (preview, off by default)

Sessions Tesla billed to the linked account, stored by the operator CLI; see
[Tesla-billed charging history](CHARGING_HISTORY.md). Separate from TeslaMate
`charges` and never merged with them. Reads never call Tesla.

| Method | Path | Query | Response |
|---|---|---|---|
| GET | `/v1/tesla/charging-history` | – | `BilledChargingStatus` |
| GET | `/v1/vehicles/{id}/tesla-charging-sessions` | `limit(≤50, default 25),cursor` | `Page<BilledChargingSession>` |

```
BilledChargingStatus  { available, enabled, connected, sessions, unmatched,
                        lastSync: { finishedAt, windowStart, windowEnd,
                                    windowComplete, outcome } | null }
BilledChargingSession { id, source: "tesla_billed", site, countryCode, startedAt,
                        endedAt, unlatchedAt, billingType, billedEnergyKwh,
                        currency, totalDue, netDue, fees: [BilledFee], invoiceCount }
BilledFee             { type, currency, pricingType, unit, isPaid, status,
                        totalDue, netDue }
```

`id` is Tesla's session ID as a string. Every other field may be null.
`billedEnergyKwh` is the kWh Tesla billed, not energy added to the battery.
`totalDue`/`netDue` are null unless every fee shares one currency and carries
the amount; a null `currency` means unknown. `sessions` counts the current
link's stored rows and `unmatched` those with no exact-VIN TeslaMate car; they
are not listed under any vehicle. `windowComplete` refers only to that sync's
window, never the whole account history, and is true only with `outcome:
"total_reached"`; any other outcome (for example `total_conflict` or
`page_limit`) leaves coverage of the window unknown. `lastSync` is the latest
run; its `outcome` is `in_progress` while that run is running or if it
stopped before recording why, and `finishedAt` is then its latest checkpoint. No VINs, invoice IDs or file names are
returned. Rows from an earlier or replaced Tesla link are hidden.

Errors: 501 `tesla_link_unavailable` (sign-in not set up), 503
`tesla_unavailable` (commander unreachable), 409 `tesla_not_connected` (list
only; the status reports `connected: false`), 409 `tesla_link_changed` (the
Tesla link was disconnected or replaced while the read was in flight, or the
`cursor` was issued under an earlier link; nothing from the earlier link is
returned, restart from the first page without a cursor), 404 `not_found`
(vehicle), 400 `invalid_input` (limit or cursor, including a cursor for another
vehicle or an older unbound cursor format). A car without a valid VIN returns an
empty page.

`nextCursor` is opaque. It is bound to the vehicle and to the Tesla link that
issued it, through a one-way digest that reveals no account, namespace or VIN.
After a disconnect the list answers `409 tesla_not_connected`; after a relink an
old cursor answers `409 tesla_link_changed` instead of continuing in the new
account's rows.

## Recording availability (v1 implementation notes)

TeslaMate populates drive endpoint IDs and distance when a drive closes. Open
drives derive distance from their first/latest recorded odometer positions. A
drive without any measurable distance is omitted from history pages and
summary/mileage calculations until observations arrive; requesting its detail
returns 409 `data_unavailable`. Existing JSON shapes remain unchanged. A vehicle
without a recorded SOC observation also returns 409 for status. `Vehicle.hasData`
is evaluated over the same rows status reads (the latest position from the last 24
hours or within 15 minutes of the latest full poll, and the newest sample of an
open charging session), plus exact-bound Fleet Telemetry BatteryLevel when enabled: it is false exactly when status for that vehicle would
return 409 at that moment. Clients prefer a vehicle with data as the default
selection. True only means status has a battery reading, not that recording is
recent or densely sampled. Servers predating the field omit it
(treat as unknown).

Idle asleep minutes require logger-state coverage of the entire gap (known awake
coverage returns zero). Climate minutes are an estimate from recorded booleans
carried forward at most five minutes per sample: recorded off time can yield an
estimated zero; no recorded climate boolean yields null. Stale, unfinished
activity rows have unknown end times and extend to now in status/timeline/idle
derivation; confirm TeslaMate collection before treating these as complete
history.

Live Fleet Telemetry additions are gated by `FLEET_TELEMETRY_ENABLED=true` and an exact VIN-digest binding. TPMS corners contain `TireReading`; temperatures are Celsius, odometer and ranges kilometres, energy kWh, pressures bar. `SentryModeStateOff` is false, known active sentry states are true, unknown/invalid is null. `chargePortLatch` preserves the upstream enum name. A change-only field can remain current for hours: freshness comes from connectivity and receiver/consumer health, not per-field expiry. Disconnected streams retain observations and their timestamps. New clients accept older responses without these optional fields.

## Service log and recorded charging locations (placeholder-screens branch)

All routes require device pairing and validate the TeslaMate vehicle ID. Volta
is single-owner: service records belong to the vehicle, shared across paired
phones, not to a phone installation. The API writes only its own `volta` schema.

- `GET /v1/vehicles/{id}/service`: `{odometerKm, recordedAt, source, items, events}`.
  Items have `id`, `name`, nullable `intervalKm/intervalMonths`, `nextDate`,
  `nextOdometerKm`, `remainingKm`, `remainingDays`, `progress` (0–1 or null).
  Events have `id`, `itemId`, `completedAt`, nullable `odometerKm`.
- `POST /v1/vehicles/{id}/service`: `{name, intervalKm?, intervalMonths?}` → 201
  item. At least one positive interval required; name ≤100 characters,
  distance ≤1,000,000 km, whole months 1–1,200.
- `POST /v1/vehicles/{id}/service/{item}/events`: `{completedAt, odometerKm?}`
  → 201 event. UTC timestamp must be valid, with a nonfuture UTC calendar date and year ≥1970. The UI submits the start of the chosen local day. Odometer
  0–10,000,000 km or null. Backdated events remain in history; only the latest
  dated event (latest recorded/edited when dates tie) anchors due calculations. Calendar months clamp month-end dates.
  A current odometer below the completion reading makes distance due unknown.
- `GET /v1/vehicles/{id}/charger-locations`: array of `{id, name, latitude,
  longitude, sessionCount, lastVisit, energyAddedKwh, avgPowerKw,
  powerSessionCount, cost, currency}`. IDs are `g:<geofence>`, `a:<address>` or
  `s:<session>` when no named location exists. Unknown coordinates stay null.
  Total energy/cost requires every session to have that field. Average power is
  mean recorded energy-used / duration-hours, not sample peak or rated power.
- `GET /v1/vehicles/{id}/charger-locations/{location}/sessions`: normal
  `Page<ChargeSummary>`, supporting limit/from/to/cursor; cursor scope binds
  vehicle, location and filters. No geocoding/search/directions/Tesla calls.

Before rolling out, an administrator applies `service-schema.sql` then
`auth-grants.sql` in the database (bootstrap/auth recovery include both).
Fleet odometer is optional behind FLEET_TELEMETRY_ENABLED and requires
`deploy/telemetry/sql/003_service_odometer.sql` after migrations 001/002.
A verified vehicle binding and a newer valid nonconflicting observation are
required; otherwise the API uses the latest TeslaMate position/drive end reading.
No deployment has been performed for this branch.

Service corrections: `PATCH /v1/vehicles/{id}/service/{item}` takes the same
name/interval body as creation; `DELETE` on that path removes the item and all
its events atomically. `PATCH /v1/vehicles/{id}/service-events/{event}` takes the
completion body; `DELETE` removes that completion and recalculates due from the
remaining history. Every mutation scopes the item/event to its vehicle. iOS
exposes these via row menus and asks before deleting history.
