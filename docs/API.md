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
power. Known gaps forbid interpolation. At most 2,000 samples cover the complete
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
Elevation reuses only nearby private TeslaMate
SRTM observations (same drive, 60 seconds, 50 metres), otherwise null. Module
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
                 location: Location|null, firmware }
Location       { latitude, longitude, heading, address, placeName }
ActivitySummary{ range, distanceKm, driveCount, chargeCount, energyUsedKwh,
                 efficiencyWhPerKm, energyAddedKwh, chargeCost, currency,
                 periodStart, periodEnd, timeZone }
TimelineSegment{ kind: drive|charge|idle|asleep|offline, start, end }
DriveSummary   { id, start, end, startAddress, endAddress, distanceKm, durationMin,
                 startBatteryLevel, endBatteryLevel, energyUsedKwh, efficiencyWhPerKm,
                 maxSpeedKph, avgSpeedKph, outsideTempAvgC }
DriveDetail    DriveSummary + { path: [DrivePoint], elevationGainM }
DrivePoint     { t, latitude, longitude, speedKph, powerKw, elevationM, batteryLevel }
ChargeSummary  { id, start, end, address, placeName, energyAddedKwh, energyUsedKwh,
                 startBatteryLevel, endBatteryLevel, durationMin, maxPowerKw,
                 fastCharger, cost, currency, outsideTempAvgC,
                 latitude?, longitude? }
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
open charging session): it is false exactly when status for that vehicle would
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
  → 201 event. UTC timestamp must be valid, nonfuture and ≥1970. Odometer
  0–10,000,000 km or null. Backdated events remain in history; only the latest
  dated event anchors due calculations. Calendar months clamp month-end dates.
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
