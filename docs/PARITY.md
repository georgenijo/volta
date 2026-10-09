# Wattly parity tracking matrix

Last updated: 2026-10-08. Baseline: `origin/main` at commit `3ff2c7e`
("Add off-by-default Tesla-billed charging history retrieval (#16)", after
`61adc89`, "Fix dashboard vehicle selection and no-data state (#15)"), plus the open
workstreams listed below, which are NOT merged.

George's goal is full feature parity with Wattly. That supersedes the
defer/drop decisions in [ROADMAP.md](ROADMAP.md) (its per-area table is now
history; its phase acceptance checks, risks and Tesla/billing constraints still
apply). Parity must stay honest:

- No empty decoration counts as parity. A screen that renders a placeholder, a
  fixed illustration, or a value derived from something else is not the feature.
- No invented data. Unknown stays `null` / "unavailable" (API.md: `null` means
  unknown, never zero).
- No imitation of proprietary Wattly algorithms. Wattly's scoring, health and
  planning formulas are not public ([research notes](#inputs-and-confidence));
  where Volta ships a score or estimate it is Volta-defined, documented, and
  labelled as such.
- Mock-data UI is not implemented parity. `MockDataSource` and `-demo-mode`
  screens exist for previews and the simulator only.

## Status vocabulary

| Status | Meaning |
|---|---|
| implemented | Code exists on main and is wired into the app with a real (non-mock) data path. |
| source-verified | Implemented AND reviewed against the source or contract, but not yet seen on George's phone with live data. |
| native-verified | Observed working on a device or simulator with real data. Used only when a doc says so. |
| in-progress | An active workstream is building it (see below). Not claimed done. |
| need-data | UI is possible but the backend or collector lacks signals. The exact missing fields or endpoints are named. |
| need-consent | Needs George's approval first: Tesla virtual key pairing on the car, Fleet API scopes, public exposure or Tailscale Funnel, APNs and paid membership use, and similar. |
| not-started | Nothing exists and nothing blocks it except effort. |
| won't-build-as-is | Proprietary, community, or hardware gate. The honest alternative, if any, is described. |

A row may carry a primary status plus a qualifier (for example `implemented
(read-only)`). Where a feature has several parts, each part is its own row.

Current evidence level: no row below uses `native-verified` or
`source-verified`. The receipts in [Operational receipts](#operational-receipts)
cover specific PRs and builds, not matrix rows; a row is promoted only when a
receipt names it. `implemented` means "code on main with a real data path";
simulator screenshots in `docs/screens/` were rendered from demo data and prove
layout only.

## Operational receipts

State as of 2026-10-08. Receipts held outside Git are named, not copied.

| Item | State |
|---|---|
| `main` | `3ff2c7e` (PR #16 merged on 2026-10-08 after `61adc89`). |
| PR #15 (dashboard vehicle selection and no-data state) | Merged. Independent source review passed. API deployed. OTA Build 5 is built from it; verification on George's phone is pending. |
| Build 4 (before PR #15) | George's native observation on Friday with live data: 58% battery, 204 rated. The proof is stored outside Git. It predates PR #15, so it does not verify Build 5. |
| Live commander | Sign in with Tesla (OAuth) and the read-only collector are enabled; commands are disabled. It is not running in stub mode. |
| Tesla spend | Live gross budget is $10 (not $20). |
| Virtual key | Confirmed paired on the car. Vehicle firmware 2026.27.11; client 1.3.0. Pairing alone does not enable commands (see K1). |
| Fleet Telemetry capture | Public port 10000 is NOT enabled. Enabling it needs George's concrete approval of a reviewable deployment (`need-consent`). |
| PR #16 (Tesla-billed charging history) | Merged to `main` (`3ff2c7e`) and deployed privately: schema applied, tailnet health check 200, OAuth connected, commands disabled, monthly budget $10. Billed history stays disabled (`enabled: false`, 0 sessions). The deployment receipt is held outside Git. Expanded Tesla consent for charging history is pending; none has been granted or assumed. The native read and presentation are a separate billing workstream, not part of this file's trip work. |
| PR #17 (trip detail, WS1) | Not merged. Built, unit-tested, and checked on the iOS simulator with demo fixtures (layout, scrubbing, replay, share, rate editor). Fixtures are synthetic; nothing about it has been seen with live or real-car data. |

## Active workstreams

| # | Workstream | Scope | Branch / area | Rows affected |
|---|---|---|---|---|
| 1 | Trip and drive detail parity | Muted monochrome route map with speed, efficiency and elevation color modes; recorded-point replay with play/pause; privacy-safe share image; battery, power, speed and elevation charts with one shared scrub and map highlight; elapsed-minutes axis; sample normalization (duplicate or conflicting timestamps, gap splitting) and per-signal coverage captions; trip cost from a known rate only; transparent Volta-defined smoothness score gated on recorded-speed coverage; temps, range and energy remaining shown as unavailable until backend fields exist. | PR #17, `feat/trip-parity`, `ios/Volta/Features/History/**`; not merged | D1 to D9 |
| 2 | Dashboard data and telemetry availability | Make the dashboard honest about which vehicle signals are recorded, stale or missing; server-side telemetry availability reporting. | PR #15 merged (vehicle selection, no-data state); per-signal availability contract still open | L2 to L6 |
| 3 | Charging history | Commander charging history, server history endpoints, deploy history schema. | PR #16 merged (`3ff2c7e`) and deployed privately with billed history disabled; expanded consent pending; native read in a separate workstream | C1 to C4 |
| 4 | Fleet Telemetry history | Optional dense drive/charge series with explicit provenance and gaps; iOS route and fast charts prefer telemetry only when it contains a real GPS route, while slow energy/temperature signals keep their own cadence. Legacy TeslaMate details remain the fallback. | `feat/fleet-telemetry`; review and deployment pending | D1, D3, D6, D7, C3 |

Parent-arranged, not yet done: a fresh Fleet Telemetry capture and a backend
contract for streamed signals. A free Ubuntu port 10000 and a Tailscale Funnel
raw-TCP capability exist, but no exposure is enabled. Enabling any public
ingress needs a reviewable, concrete deployment approval from George
(`need-consent`). The virtual key is paired (see receipts); command scopes and
command enablement remain separate approvals.

## What exists today (code inventory)

| Layer | What is on main |
|---|---|
| iOS app | SwiftUI, iOS 26. Tabs: Dashboard, Charging, Drives, Idles, More. More hosts Stats, Battery Health, Battery Climate, Mileage, Firmware, Specs and Warranty, Switch Vehicle, Settings. On placeholder-screens, Maintenance and Charger Map have data-backed destinations; Automations and Plan a route are removed. Only Tires routes to `ComingLaterView`, a static placeholder. |
| iOS data path | `VoltaDataSource` protocol; `APIDataSource` for the real server, `MockDataSource` for previews and demo mode. Models in `ios/Volta/Core/Models.swift` mirror API.md. |
| Widgets | `ios/VoltaWidgets/`: Home Screen (small, medium, large) and Lock Screen widgets, charging and driving Live Activities, fed by `WidgetSync` through the App Group. Updates only when the app refreshes status; no push. |
| Server | `server/src/app.ts`: health, pair, me, vehicles, status, summary, timeline, drives, drive detail, charges, charge detail, idles, battery, mileage, firmware, places, Tesla link status/start/complete/cancel/disconnect. Commands route always returns `501 commands_unavailable`. Reads TeslaMate Postgres only. |
| Commander | `commander/` (Go): Sign in with Tesla OAuth (read scopes only), encrypted token store, budgeted read-only collector for TeslaMate, command validation and broker groundwork. No Tesla credentials in this repo; repo tests use local fakes (`commander/VERIFICATION.md`). Live deployment: OAuth and the collector are enabled, commands disabled (see receipts). |
| Deploy | `deploy/`: Dockerfile, SQL grants and schema, Ubuntu units, commander compose, Cloudflare Worker callback bounce. |

Known contract gaps found while writing this matrix:

- `locked` and `sentryMode` are hard-coded `null` in `server/src/telemetry.ts`
  status, so the lock, Sentry and quick-control state always render "Unknown".
- The Dashboard "Weather" tile is derived from `outsideTempC` and the phone's
  clock (icon and gauge); it is not weather data. The "Pack Temp" tile always
  shows an em dash. Neither counts as parity.
- iOS sends Tesla command names (`door_lock`, `charge_port_door_open`,
  `honk_horn`, `set_sentry_mode`), while commander's allowlist uses Volta names
  (`lock`, `open_charge_port`, `honk`, `sentry_on`/`sentry_off`), and the server
  does not forward commands to commander at all. A single command contract must
  be agreed before controls can work.
- `IdleSummary.sentryMinutes` and `asleepMinutes` are derived only where the
  logger covers the gap; `sentryMinutes` is selected as `NULL` in the idle query.

## Matrix

Columns: **ID**; **Wattly feature (area)** cites the numbered area in
`feature-map.json`; **Status**; **Evidence** (paths or "none"); **Gates**
(proprietary, hardware, data, consent); **Next step**.

### Live vehicle and dashboard (area 01)

| ID | Wattly feature | Status | Evidence | Gates | Next step |
|---|---|---|---|---|---|
| L1 | Last-recorded battery, range, charge state and limit, odometer, location with address, inside/outside temps, firmware (01) | implemented (last recorded, not live) | `ios/Volta/Features/Dashboard/*`; `server/src/telemetry.ts` `status()`; API.md `VehicleStatus` | Values come from the latest TeslaMate `positions` row; freshness is `updatedAt`, not streaming. Collector pacing in TESLA_SIGN_IN.md is stated for a $20 budget; the live gross budget is $10, so expect reads no more often than that. Build 4 native observation (58%, 204 rated) is held outside Git and predates PR #15. | Verify Build 5 on the phone; keep freshness/stale labelling under WS2. |
| L2 | Door lock state and Sentry state (01, 10) | need-data; WS2 in-progress | `server/src/telemetry.ts` returns `locked: null, sentryMode: null` | Missing fields: `vehicle_state.locked`, `vehicle_state.sentry_mode` from `vehicle_data` or Fleet Telemetry (`Locked`, `SentryMode`). TeslaMate does not store them in `positions`. | Define the backend field source in the telemetry contract; UI already renders unknown correctly. |
| L3 | Tire pressure / TPMS (01) | need-data | none (`VehicleStatus` has no tire fields; More "Tires" is `ComingLaterView`) | Missing fields: `tpms_pressure_fl/fr/rl/rr` (and soft-warning flags) via `vehicle_data` `vehicle_state` or Fleet Telemetry `TpmsPressureFl` etc.; a history table to store them. | Add fields to the telemetry contract and a `volta` schema table; then build the Tires screen. |
| L4 | Live speed, power, gear while driving (01) | need-data | none on the dashboard; Driving Live Activity exists but is fed by polled status | Needs Fleet Telemetry streaming (`VehicleSpeed`, `Gear`, power) which needs a public mTLS receiver (see N-gates below). | Wait for telemetry capture and contract; do not fake from the last position. |
| L5 | Pack/battery temperature (01, 05) | need-data | Dashboard "Pack Temp" tile shows "—" and "N/A" by design | Missing: `battery_heater`/pack temperature signals (`BatteryTemperature`-class telemetry fields; confirm names in the capture). TeslaMate does not record them. | Contract request after the telemetry capture. Keep the tile marked unavailable until then. |
| L6 | Weather at the car (01 hero, 09) | need-data; need-consent | Dashboard "Weather" tile is derived from `outsideTempC` plus clock time; it is decoration, not weather | Needs an external weather provider or `climate_state` outside temp history; a provider means sending the car's location off-server, which needs George's decision. Provider choice and key are undecided. | Either relabel the tile "Outside" (honest), or pick a provider with George's approval. |
| L7 | Dark 3D map with car marker and address pill (01) | implemented | `Features/Dashboard/DashboardMap.swift` | Needs a recorded location; shows "Location unavailable" otherwise. | None. |
| L8 | 48-hour activity strip, Today/7D/30D summaries (01, 04) | implemented | `Features/Dashboard/ActivityStrip.swift`, `server` `timeline()`/`summary()` | None. | None. |
| L9 | Multi-vehicle switching (21) | implemented | `Features/More/SwitchVehicleView.swift`, `AppModel.selectedVehicleID` | Only vehicles TeslaMate has recorded. | None. |

### Controls and commands (areas 10, 09, 11)

| ID | Wattly feature | Status | Evidence | Gates | Next step |
|---|---|---|---|---|---|
| K1 | Lock/unlock, frunk/trunk, windows, charge port, flash/honk, locate (10) | need-consent | UI: `Features/Controls/ControlsView.swift`, `ControlStates.swift` (disabled); server route returns 501; `commander/commands.go` validation only; no live path Virtual key is paired (receipt). Still needed: `vehicle_cmds` scope and fresh consent (current scopes are read-only), commands enabled in commander, billing cap, `fleet_status` check, signing proxy deployment. Command name mismatch iOS vs commander (see gaps). | George decision on pairing and scopes; unify command names; wire server to commander; add per-command authorization. UI is a shell until then. |
| K2 | Charging start/stop and charge limit (10, 06) | need-consent | `ControlsModel.setCharging`, `adjustChargeLimit` (disabled); commander has `charge_start`, `charge_stop`, `set_charge_limit` | `vehicle_charging_cmds` scope, virtual key, as K1. | As K1. |
| K3 | Sentry on/off (10, 08) | need-consent | `ControlsModel.setSentry` (disabled) | As K1; state read also needs L2. | As K1, plus L2. |
| K4 | Climate on/off, set temps, preconditioning, defrost, seat/steering heat, scheduled departure (09, 10) | need-consent | `setClimate` (disabled); commander has `climate_on/off`, `set_temps` only; climate read-only display exists (`climateOn`, inside/outside/driver setting) | As K1. Defrost, seat heaters, scheduled departure and charge schedules have no UI, no commander mapping and no contract. | After K1, add contract and commander mappings for the remaining commands one at a time. |
| K5 | Wake the car (10) | need-consent | commander `wake_up` mapping; no UI; app browsing never wakes the car (ROADMAP) | Wake billing ($0.02 per wake, 3 per minute) and George's decision on when a wake is acceptable. | Defer until K1. |
| K6 | HomeLink trigger, remote boombox (10) | not-started | commander has `trigger_homelink` validation; iOS constants exist; no UI wired | As K1. | Low priority; after K1. |
| K7 | Command audit and per-command authorization (10, 23) | not-started | ROADMAP Phase 2 describes it; commander has audit-receipt groundwork | Needs K1 done first. | Design with the K1 contract. |

### Charging (areas 06, 07)

| ID | Wattly feature | Status | Evidence | Gates | Next step |
|---|---|---|---|---|---|
| C1 | Charging history list, day groups, filters, map of sessions (06) | implemented (TeslaMate sessions); Tesla-billed history in-progress | `Features/History/ChargingHistoryView.swift`, `server` `charges()`. Tesla-billed retrieval: server source, PR #16 merged to `main` (`3ff2c7e`, `docs/API.md`, `docs/CHARGING_HISTORY.md`), deployed privately with billed history disabled (`enabled: false`), expanded consent pending | TeslaMate sessions: coordinates optional. Tesla-billed: need-consent (charging-history scope on Tesla's consent screen) and no native read or presentation yet. | Enable PR #16 after consent; then a UI worker builds the native read (see "Charging history (WS3)" requests). |
| C2 | Charge detail: charge curve, SOC curve, max power, DC fast badge, efficiency, losses (06) | implemented | `Features/History/ChargingDetailView.swift`, `ChargeDetail.samples` | `ChargeSample` fields (`powerKw`, `voltage`, `currentA`, `ratedRangeKm`) can be null; the UI shows what is recorded. | None. |
| C3 | Live charging session now (06) | implemented (polled, last recorded); streaming need-data | Dashboard charging state and ETA; `ChargingLiveActivity`; `WidgetSync` | True second-by-second live curve needs Fleet Telemetry (`ChargerPower`, `ACChargingPower`, `DCChargingPower`, `TimeToFullCharge`). Updates refresh only while the app runs. | Wait for the telemetry contract. Push updates are N6. |
| C4 | Charging curves compared across sessions or chargers (06, 04) | not-started | none | Data exists in `ChargeSample`; no comparison UI. | Add after C2 verification. |
| C5 | Tariffs per location (07) | implemented (read-only) | `Features/Settings/PlacesView.swift`, `Place.costPerKwh` from TeslaMate geofences; sessions priced by TeslaMate | Editing tariffs stays in TeslaMate (ROADMAP). The "home-rate fallback" is a "Coming later" card, not a feature. | Decide on a Volta-owned write contract for tariffs. |
| C6 | Time-of-use rates (07) | not-started | none | TeslaMate geofences hold one flat per-kWh rate (`billing_type = per_kwh`), so no TOU data exists. Needs a Volta `volta`-schema rate table with schedule windows and a recompute path. | Design a rate table and cost recompute that does not overwrite TeslaMate costs. |
| C7 | Currency display and conversion (07, 21) | implemented (display currency only) | `UnitPreferences.currency`, `VoltaFormat.money`, Stats multi-currency totals | Exchange-rate conversion would need a rate provider and a decision; multi-currency totals are shown separately instead of invented conversions. | Keep; conversion is optional and needs a data source choice. |
| C8 | Cost per session / per distance / totals with coverage notes (07) | implemented | `ChargingDetailView` cost breakdown, `StatsView` charging cost, `HistoryAggregates.swift` | Missing costs render as an em dash and are excluded with a stated qualifier, never zero. | None. |
| C9 | Receipts and invoices (07) | not-started | none | Needs a session-to-receipt model; any PDF would contain addresses, which is private data. | Design after C6. Export locally on the phone only. |
| C10 | Gasoline comparison (07) | won't-build-as-is | none | Requires a fuel-price source and an assumed comparison car; either is invented data. George's rule: no fake gasoline comparisons. | Honest alternative: cost per distance and cost per kWh from known rates only (already in C8). |
| C11 | Energy-mix / CO2 allocation (07) | need-data | none | Needs a grid-mix data source per location and time. | Park until a data source is chosen. |

### Drives and trip detail (areas 02, 03)

All D rows are owned by workstream 1 (PR #17, `feat/trip-parity`). Status here
describes `origin/main`; the branch is not merged and nothing is claimed done.
"Branch" notes describe `feat/trip-parity`: built, unit-tested, and exercised on
the iOS simulator with demo fixtures only (a dense synthetic drive, a drive with
long gaps in individual signals, a drive with speed and elevation recorded
only every 120 s and a single power reading, a drive whose speed, power and
elevation are recorded on only two of every eight samples, a drive with power
missing for its last 15%, and a sparse drive of 1,335 rows over 5
distinct timestamps with one conflicting row). Demo fixtures are not real data,
so no D row is `native-verified` or `source-verified`.

| ID | Wattly feature | Status | Evidence | Gates | Next step |
|---|---|---|---|---|---|
| D0 | Drive list, ranges, totals, map of drives (03) | implemented | `Features/History/DrivesHistoryView.swift`, `HistoryAggregates.swift`, `server` `drives()` | Open or zero-distance drives are omitted (API.md recording availability). | None. |
| D1 | Route map with speed/efficiency/elevation color modes (02) | in-progress (WS1 + Fleet Telemetry); partial on main | WS1 supplies the gap-aware native map. `feat/fleet-telemetry` decodes a separate optional telemetry series and uses it only with at least two recorded GPS samples; signal-only samples never receive fabricated coordinates. `routeBreakBefore` and declared receiver gaps split the route even when adjacent timestamps are close. | Elevation remains private TeslaMate-derived; telemetry does not call an external elevation or geocoding service. | Review both branches; verify with a real dense drive after deployment. |
| D2 | Replay along recorded points with play/pause (03) | in-progress (WS1) | Branch: `DriveDetailView` replay (~15 s per trip); marker snaps to the nearest recorded sample within 60 s and shows "No sample" inside longer gaps | Replay moves along recorded points only; no interpolated "live" positions. Sparse points are captioned. | WS1. |
| D3 | Charts: battery, power, speed, elevation, shared scrub with map highlight, elapsed-minutes axis (02) | in-progress (WS1 + Fleet Telemetry) | WS1 provides per-signal gap-aware charts and scrub. `feat/fleet-telemetry` prefers the dense GPS telemetry timeline for route/speed/power/elevation, uses telemetry battery at its independent cadence, and keeps TeslaMate charts when telemetry has fewer than two GPS samples. Declared gaps, a named `invalidFields` observation for that signal, and `routeBreakBefore` end telemetry chart segments; unrelated null rows do not break a slow signal's own cadence. Selection inside a declared gap or over 120 seconds from a recording shows no snapped value. Provenance captions name Fleet Telemetry and disclose gaps/truncation. | `truncated: true` prevents whole-trip coverage and score claims. | Review; run against receiver fixture and then real capture. |
| D4 | Privacy-safe share image (03) | in-progress (WS1) | Branch: `Trip/TripShare.swift` card (date, distance, efficiency, duration, energy, battery change; no map, coordinates, addresses or times) via the system share sheet | Image must omit addresses and exact start/end by default; George controls sharing. Video and postcard exports are not part of WS1. | WS1; video/postcard export remains not-started. |
| D5 | Trip cost (02, 07) | in-progress (WS1) | Branch: `TripRate` from a device-local manual rate (0 allowed) or the latest priced charge before the trip (a free charge counts as a rate of 0; its ISO currency is required and never filled from display preferences). The lookup pages through charge history up to a cap and reports "incomplete" rather than "none" when it stops early. Otherwise "Cost unknown" with the reason | Known rate only (geofence or session rate); no rate means unavailable, never zero, and no gasoline comparison. | WS1. |
| D6 | Driving / smoothness score (02) | in-progress (WS1 + Fleet Telemetry); proprietary algorithm won't-build | `SmoothnessScore` remains the transparent Volta Smoothness v1 derived from recorded speed. Fleet Telemetry can satisfy its cadence gate; the app still requires ≥ 70% whole-trip speed coverage at ≤ 6 s and ≥ 120 moving intervals. A truncated response is always withheld. A separate optional Acceleration chart renders recorded longitudinal/lateral sensor observations in m/s² and honors per-field invalid boundaries. | The raw sensor chart does not change or relabel the published speed-derived Volta Smoothness v1 formula. Wattly's formula remains unknown. | Review and verify with non-truncated real capture. |
| D7 | Outside temp, range used, energy remaining per drive (02) | in-progress (Fleet Telemetry) | `feat/fleet-telemetry` renders energy remaining, battery module min/max temperature, and inside/outside temperature at each signal's recorded cadence on drive and charge detail. Null values stay missing; the API's per-signal `invalidFields` evidence splits that signal's line. Demo fixtures exercise layout only. | Backend unit normalization must remain source-documented; real vehicle availability is unverified. | Review, then verify units and availability from George's own capture. |
| D8 | FSD distance / Autopilot share in a drive (02, 17) | need-data | none | Needs FSD/Autopilot engagement signals per point; see F-rows. | Park with FSD (X1). |
| D9 | Trip search, repeated-journey comparison, heatmaps, 3D replay (03) | not-started | none | Data exists in drive paths; needs route matching and a map-aggregation design. 3D replay is a visual layer on D2. | After WS1 merges; scope separately. |

### Idles, parked drain, Sentry (area 08)

| ID | Wattly feature | Status | Evidence | Gates | Next step |
|---|---|---|---|---|---|
| I1 | Idle sessions, duration, battery/range loss, vampire drain rate, map (08) | implemented | `Features/History/IdlesHistoryView.swift`, `IdleDetailView.swift`, `server` `idles()` | Idles are derived gaps between drives and charges; battery difference does not prove cause. | None. |
| I2 | Asleep/Sentry/climate time breakdown (08) | need-data | `IdleDetailView` shows "State breakdown wasn't recorded" when absent; server returns `sentryMinutes` NULL and `asleepMinutes` only with full logger coverage | Missing: recorded Sentry state history (same source as L2), full logger state coverage. | Add a Sentry-state signal to the telemetry contract. |
| I3 | Sentry events and clips (08, 19) | won't-build-as-is | none | Sentry clips live on the car's USB drive and Tesla does not expose them over the API. See X5. | None. |

### Stats and efficiency (area 04)

| ID | Wattly feature | Status | Evidence | Gates | Next step |
|---|---|---|---|---|---|
| S1 | Distance, energy, efficiency, charging cost charts by period (04) | implemented | `Features/Analytics/StatsView.swift`, `AnalyticsMath.swift` | Depends on summaries from TeslaMate. | None. |
| S2 | Efficiency versus outside temperature (04) | implemented | `Features/Analytics/BatteryClimateView.swift` | Needs `outsideTempAvgC` per drive; sparse buckets are shown as is. | None. |
| S3 | Efficiency versus speed comparison (04) | not-started | none | Data derivable from drive paths (`speedKph`, `powerKw`); no UI or aggregate endpoint. | Add an aggregate once D3 sample normalization lands. |
| S4 | Activity breakdown (driving/charging/idle/asleep share) (04) | implemented (partial) | 48h `timeline()` strip and Today/7D/30D totals | No longer-range time-in-state chart. | Optional. |

### Battery, climate, tires (areas 05, 09, 01)

| ID | Wattly feature | Status | Evidence | Gates | Next step |
|---|---|---|---|---|---|
| B1 | Battery health: rated range at 100% trend and estimated capacity (05) | implemented (estimated) | `Features/Analytics/BatteryHealthView.swift`, `server` `battery()` | TeslaMate method (rated range at full charge); labelled as an estimate; temperature and small samples bias it. Not a measured capacity. | None; keep the caveats visible. |
| B2 | Degradation over time chart (05) | implemented | `BatteryHealthView` history chart | As B1. | None. |
| B3 | Charge cycles (05) | need-data | none (`BatteryHealth` has no cycle field) | Derivable only as a rough sum of energy added divided by capacity; any figure would be an estimate. Wattly's method is unknown. | Optional: add a clearly labelled estimate from `energyAddedKwh` / capacity once WS3 history is trustworthy. |
| B4 | Thermal / battery temperature history (05) | need-data | none | Same signals as L5. | After the telemetry capture. |
| B5 | Range estimates at 100% and at the charge limit (05) | implemented | `ratedRangeAt100Km`, dashboard range bar | Rated range is not measured range. | None. |
| B6 | Climate read display: on/off, inside, outside, driver setting (09) | implemented (read-only) | Dashboard `climateCard`, `Features/Analytics/BatteryClimateView.swift` | Last-recorded values. Controls are K4. | None. |
| B7 | Tires: pressure, history, rotation reminders (01, 13) | need-data | More "Tires" is `ComingLaterView` only | See L3. | See L3 and M2. |

### Maintenance, firmware, mileage, warranty (areas 13, 14, 15)

| ID | Wattly feature | Status | Evidence | Gates | Next step |
|---|---|---|---|---|---|
| M1 | Service log with reminders and maintenance costs (13) | in-progress (placeholder-screens) | `MaintenanceView.swift`, `server/src/service.ts`, `deploy/service-schema.sql`: suggested/custom intervals, completion dates/odometers, persisted history and due progress | No maintenance costs or push reminders; displayed in-app. Administrator must apply the schema and grants before API rollout. | Review and merge; verify real data on device. |
| M2 | Tire rotation / service intervals driven by mileage (13) | in-progress (placeholder-screens) | Maintenance uses newest TeslaMate positions/drive end odometer; optional newer ownership-validated Fleet Odometer; default rotation 6,250 mi | Due remains unknown without a completion baseline or current odometer. | Review and merge; apply optional `003_service_odometer.sql` for telemetry. |
| M3 | 3D vehicle view and offline saved plan (13) | won't-build-as-is | none | Needs licensed 3D vehicle assets. Honest alternative: a 2D vehicle summary using Volta's own artwork. | None. |
| M4 | Firmware: own install history and timeline (14) | implemented | `Features/Analytics/FirmwareTrackerView.swift`, `server` `firmware()` | TeslaMate `updates` table. | None. |
| M5 | Firmware: fleet rollout statistics, release notes, filters (14) | won't-build-as-is | none | Rollout stats are Wattly's community data; release notes come from Tesla/third parties with no authoritative API. Honest alternative: link out to Tesla's release notes page and show only the user's own history. | Optional: static link to Tesla release notes. |
| M6 | Mileage buckets (day/week/month) (15) | implemented | `Features/Analytics/MileageTrackerView.swift`, `server` `mileage()` | None. | None. |
| M7 | Lease allowance tracker, remaining miles (15) | not-started | none | Pure client/server feature (lease start, term, allowance) using odometer; no external dependency. | Add local-first lease settings plus projection; Volta-defined, labelled. |
| M8 | Work trips and business mileage, expense PDFs (15, 16) | not-started | none | Needs trip classification (store per trip tags in the `volta` schema), report generation; tax rules are jurisdiction-specific and must not be asserted. | Spec after trip IDs are stable; export locally. |
| M9 | Warranty coverage (15, 13) | implemented (static, local) | `Features/Analytics/SpecsWarrantyView.swift` | Hard-coded standard Model 3/Y coverage and a purchase date stored only on the phone; not derived from Tesla data. Treat as a calculator, not account warranty status. | Mark clearly as user-entered; add editable coverage. |
| M10 | Professional mode: client logbook, cost/km, PDF invoices (16) | not-started | none | Depends on M8; invoicing and tax rules are jurisdiction-specific. | Out of scope until M8 exists. |

### Chargers, planning, weather (area 12)

| ID | Wattly feature | Status | Evidence | Gates | Next step |
|---|---|---|---|---|---|
| P1 | Nearby charger map with filters (12) | in-progress (own-history alternative) | `ChargerMapView.swift`, `Telemetry.chargerLocations/chargerSessions`: recorded TeslaMate charging places with per-place sessions | Own visited locations only; no nearby dataset, live stalls, geocoding, search or directions. Null coordinates remain list-only. | Review and merge; verify real TeslaMate history. |
| P2 | Live stall availability (12) | need-data | none | Needs a provider with live availability or Tesla's signals; not available from TeslaMate. | With P1. |
| P3 | Route planner with arrival charge estimate (12) | won't-build-as-is | Plan a route row removed on placeholder-screens | Sending coordinates to routing providers is forbidden. No local routing engine or reliable own-history range model exists on this branch. | No routing request or third-party location processing. |
| P4 | Community prices, photos, comments (12, 18) | won't-build-as-is | none | Requires a multi-user community backend; Volta is single-owner and private. | Honest alternative: private notes per place in the `volta` schema. |

### Notifications, automations, Apple surfaces (areas 11, 20)

| ID | Wattly feature | Status | Evidence | Gates | Next step |
|---|---|---|---|---|---|
| N1 | Home Screen widgets (20) | implemented (not seen on device in docs) | `ios/VoltaWidgets/Extension/HomeWidget.swift`, `WidgetSync.swift`; layouts in `docs/screens/widgets/` | Data refreshes when the app refreshes; widgets need the App Group registered on the team. Simulator renders used demo fixtures. | Install on the phone and observe with real data. |
| N2 | Lock Screen widgets (20) | implemented (same caveat) | `Extension/AccessoryWidget.swift` | As N1. | As N1. |
| N3 | Live Activities: charging, driving (20) | implemented (local only) | `ChargingLiveActivity.swift`, `DrivingActivityAttributes`, `LiveActivityPlanner.swift` | Start/update only while the app is active; remote updates need APNs and a push channel (paid membership is held, but push relays Apple-processed payloads; see N6). | Observe on device; push path is N6. |
| N4 | Shortcuts / App Intents / Siri (20) | not-started | none (no `AppIntent` types in the repo) | Read intents need only cached state. Command intents depend on K1. | Spec read-only intents (battery, range, charging state) first. |
| N5 | Apple Watch app and complications (20) | not-started | none | Needs a watchOS target and shared cached state; controls depend on K1. | Spec after N4. |
| N6 | Push notifications (charge complete, plugged-in reminder, alerts) (11, 20) | need-consent | none | Needs APNs (a push key on the paid team), a server sender, minimal payloads, and George's privacy decision (Apple processes payloads); needs reliable events (telemetry or collector). | George decision on APNs; minimal-payload design. |
| N7 | Automations: triggers x actions (11) | not-started; row removed | Removed on placeholder-screens: commander has manual sentry/climate/charging commands, but API forwarding returns 501, no scheduler/evaluator and no notification sender | A real unattended action requires an evaluator and functioning action/delivery path; scheduled departure/charging commands are absent. | Reintroduce only with tested server evaluation and authorized actions/delivery. |
| N8 | Shared lock-screen / Control Center controls (20) | not-started | none | Depends on K1. | After K1. |

### Personalization, data, security (areas 21, 22)

| ID | Wattly feature | Status | Evidence | Gates | Next step |
|---|---|---|---|---|---|
| Z1 | Units (distance, temperature, currency), language follows iOS (21) | implemented | `UnitPreferences`, `Features/Settings/AccountSettingsView.swift` | Local preferences only; not synced. | None. |
| Z2 | Biometric / passcode app lock (21) | implemented | `Core/Auth/AppLock.swift`, `SecuritySettingsView.swift` | None. | None. |
| Z3 | Themes, accent colors, app icons, movable dashboard widgets, navigation customization (21) | not-started | none (one dark theme; `DesignSystem/` is fixed) | None beyond effort. A theme layer must keep contrast accessible. | Scope a theme/appearance setting; dashboard card reorder as a local preference. |
| Z4 | Synced settings across devices (21) | not-started | none | Needs a settings store in the `volta` schema keyed by device-independent owner identity, or iCloud; privacy choice. | Prefer server-side `volta` schema. |
| Z5 | Two-vehicle histories (21) | implemented | Vehicle switcher; all endpoints are `vehicles/{id}` scoped | Depends on TeslaMate recording both cars. | None. |
| Z6 | Export drives and charges (22) | implemented (JSON, summaries only) | `Features/Settings/DataManagementView.swift` | Export is summary JSON; no GPX/CSV, no routes, no idles. | Add CSV and per-drive GPX, idles; keep local only. |
| Z7 | Import from TeslaMate (22) | implemented (reads TeslaMate DB directly) | architecture (SPEC.md); no import UI needed | History is read live from TeslaMate Postgres, not imported. | None. |
| Z8 | Import from TezLab or other providers (22) | not-started | none | Needs a stable import format and a mapping to TeslaMate/Volta tables; writes to history; format docs not verified. | Spec only if George has an export file. |
| Z9 | Sign in with Tesla (prerequisite for collection) | implemented (read-only) | `Features/Tesla/*`, `commander/oauth.go`, `docs/TESLA_SIGN_IN.md`; live commander has OAuth and the collector enabled (receipt) | Scopes `vehicle_device_data`, `vehicle_location`. Any added scope needs fresh consent. | None for read-only. |

### Community, dashcam, FSD, AI (areas 17, 18, 19, 23)

| ID | Wattly feature | Status | Evidence | Gates | Next step |
|---|---|---|---|---|---|
| X1 | FSD center: usage, version comparison, streaks, efficiency (17) | need-data | none | Needs FSD engagement signals (Fleet Telemetry fields, HW4 only per Wattly) and a vehicle that exposes them; none are in TeslaMate. Wattly's HW4 restriction is advertised, not verified for Volta. | Check telemetry capture for FSD-related fields before any UI. |
| X2 | Community: friends, competitions, awards, referrals (18) | won't-build-as-is | none | Multi-user social backend contradicts Volta's single-owner private design. | Honest alternative: private personal records and milestones (local). |
| X3 | Passport / visited regions map (18) | not-started | none | Derivable from the user's own drive and charge coordinates; reverse-geocoding by region would use a geocoder (not used today). | Spec using local region boundaries bundled in the app; no social features. |
| X4 | Awards / achievements (18) | not-started | none | Volta-defined milestones from own data; no leaderboard. | Low priority. |
| X5 | Dashcam Studio: USB import, telemetry overlays, multicamera/vertical export (19) | not-started | none | USB footage is imported by the user via Files; overlays need drive telemetry aligned by time (D3 data) and a video export pipeline (AVFoundation). Tesla's clips carry their own metadata; the alignment method is not verified. | Separate project; scope after D2/D3. |
| X6 | AI assistant over saved data (23) | not-started; need-consent | none | Any hosted model processes private location data; George must choose provider and data scope. Wattly's assistant internals are unknown. | Decision from George. Local-only summaries are an alternative. |
| X7 | MCP server with scoped control / wake permissions (23) | need-consent | none | Control scopes depend on K1; exposing an MCP endpoint is public or tailnet exposure. | After K1 and a security design. |

## Backend contract requests

Requests here are not yet implemented. Each entry names the exact field or
endpoint. Fields must be nullable and metric, per API.md.

### Telemetry availability and signals (WS2 and the parent telemetry capture)

| Request | Fields / endpoint | Used by |
|---|---|---|
| Lock and Sentry state | `VehicleStatus.locked`, `VehicleStatus.sentryMode` populated (currently always `null`), with a per-field recorded timestamp | L2, I2, K1 to K3 |
| Per-signal availability | `VehicleStatus.signals: { name: { available, recordedAt } }` or equivalent, so the UI can say "not recorded" versus "stale" | L1 to L6 |
| Tire pressures | `tpmsFl`, `tpmsFr`, `tpmsRl`, `tpmsRr` (bar), `tpmsSoftWarning*` flags; history endpoint `GET /v1/vehicles/{id}/tires` | L3, B7 |
| Pack temperature | `batteryTempC` (name to be confirmed from the capture) and history | L5, B4 |
| Live speed, gear, power | Streaming fields behind the telemetry receiver; contract after capture | L4, C3 |
| Weather | Either a stated provider contract or removal of the Weather tile | L6 |

### Charging history (WS3)

| Request | Fields / endpoint | Used by |
|---|---|---|
| Stable history shapes after the schema change | `ChargeSummary` / `ChargeDetail` unchanged unless noted; note any added fields here when WS3 merges | C1 to C4 |
| Native read of Tesla-billed charging (follow-up for a later UI worker; `Core` `DataSource` is not changed yet, matching the dashboard PR #15 pattern) | `GET /v1/tesla/charging-history` → `BilledChargingStatus`; `GET /v1/vehicles/{id}/tesla-charging-sessions?limit(≤50)&cursor` → `Page<BilledChargingSession>`, schema in `docs/API.md` at `c8b0c740`. Presentation rules: `billedEnergyKwh` is billed kWh, never shown as battery energy added; `currency: null` means unknown, never a default; `totalDue`/`netDue` null means not totalled; `windowComplete` covers only that sync's window, not all history; `available`/`enabled` false shows an off state, not an empty history | C1, C5, C8 |
| Rate source on a session | `rateKwh`, `rateSource` (geofence, manual, none) so the UI can show cost provenance | C5, C8, D5 |
| Time-of-use rate schedule | `volta` schema table of windows and rates per place; endpoint to read it | C6 |

### Other requests

| Request | Fields / endpoint | Used by |
|---|---|---|
| Command forwarding | `POST /v1/vehicles/{id}/commands/{name}` proxies to commander; one command-name list shared by iOS and commander | K1 to K6 |
| Service log | `GET/POST/PATCH /v1/vehicles/{id}/service` | M1, M2 |
| Lease and trip tags | `lease` settings object; `tags` on `DriveSummary` | M7, M8 |
| Export formats | CSV/GPX/idles export, generated on device from existing endpoints | Z6 |

### Trip detail (from trip-parity workstream)

Fields map to Tesla Fleet Telemetry v0.9.5 (`bd076fe1`, `protos/vehicle_data.proto`)
where a signal exists. The proto does not state units for speed, range or
energy fields, so each unit must be confirmed from a real capture before
ingestion converts it; nothing here assumes one. All fields nullable and metric
in the API, per API.md. Today `DrivePoint` carries only `t`, `lat`, `lon`,
`speedKph`, `powerKw`, `elevationM`, `batteryLevel`.

| Request | Fields / endpoint | Fleet Telemetry source | Used by |
|---|---|---|---|
| Collector de-duplication | Store one row per (drive, timestamp); a later identical row is a no-op, a conflicting row is logged. Seen live: 1,335 rows over 5 distinct timestamps. The app now normalizes and discloses this, but cannot recover missing samples. | n/a (collector) | D1 to D3, D6 |
| Sample provenance on a drive | `DriveDetail.sampling { rawRows, distinctTimestamps, conflictingTimestamps, source }` with `source` naming the collector (TeslaMate poll vs telemetry stream) | n/a | D3 sampling note |
| Speed unit | Keep `speedKph`; ingestion converts only after the unit of `VehicleSpeed` (4) is confirmed from capture (likely mph, unverified) | `VehicleSpeed` = 4 | D1, D3, D6 |
| Per-point temperatures | `DrivePoint.insideTempC`, `outsideTempC` | `InsideTemp` = 85, `OutsideTemp` = 86 | D7 |
| Per-point range | `DrivePoint.ratedRangeKm`, `estRangeKm`, `idealRangeKm` | `RatedRange` = 32, `EstBatteryRange` = 40, `IdealBatteryRange` = 41 (units unconfirmed) | D7 range efficiency |
| Per-point energy remaining | `DrivePoint.energyRemainingKwh`; `DrivePoint.soc` kept distinct from `batteryLevel` | `EnergyRemaining` = 158, `Soc` = 8, `BatteryLevel` = 42 | D7 |
| Pack electrical | `DrivePoint.packVoltageV`, `packCurrentA` so power can be derived where `powerKw` is missing | `PackVoltage` = 6, `PackCurrent` = 7 | D3 power |
| Measured regen per drive | `DriveSummary.regenKwh` from the delta of a lifetime counter across the drive; replaces the app's sample-derived estimate (over intervals with power at both ends, power assumed linear between readings and only the part below zero integrated, so a sign change counts just its negative triangle; always shown as ≈ with the power coverage when partial (80–99%), never as a bound; withheld below 80% or with one reading) | `LifetimeEnergyGainedRegen` = 134 (and `LifetimeEnergyUsed` = 102 for used) | D3, details |
| Range at start/end | `DriveSummary.startRatedRangeKm`, `endRatedRangeKm` | `RatedRange` = 32 | D7 |
| Gear per point | `DrivePoint.gear` so stops and reverse are not scored as braking | `Gear` = 10 | D6 |
| Odometer per drive | `DriveSummary.startOdometerKm`, `endOdometerKm` | `Odometer` = 5 | D0, M-rows |
| Elevation | Keep `elevationM` from the current source; Fleet Telemetry v0.9.5 has no elevation signal, so a telemetry-only drive must send `null`, not 0 | none | D1 elevation mode, D3 |
| Trip timezone | `DriveSummary.timeZone` (IANA) of the start location; the app shows device time and says so until then | n/a | D3 axis, header |
| Descent | `DriveSummary.elevationLossM` alongside `elevationGainM` | n/a | details |
| Place names | `DriveSummary.startPlace`, `endPlace` from geofences, so the hero does not split raw addresses | n/a | hero |
| Server-side tariff | Session or geofence `rateKwh` + `currency` + `rateSource` (see Charging history) so trip cost does not depend on a device-local rate | n/a | D5 |

## Inputs and confidence

| Input | Read? | Notes |
|---|---|---|
| `docs/SPEC.md`, `ROADMAP.md`, `API.md`, `TESLA.md`, `TESLA_SIGN_IN.md`, `DEPLOY.md` | yes | |
| `/Users/macbook/Documents/reports/wattly-feature-map-20261007/feature-map.json` | yes | 23 areas, fields `id`, `area`, `family`, `features`, `inputs`, `private_design`, `dependency`. It is a public-documentation scope inventory, not Wattly's implementation. |
| `.../research-notes.md` | yes | States exact scoring and health methods, import/export schemas, the full automation matrix and compatibility are unknown. |
| `docs/reference/*.png` (12 images) | not opened for this file | Visual direction only. Not used as evidence for data availability. |
| iOS source, server, commander | yes, by inspection | Not built or run for this file. Status reflects code reading on `921a30d`, refreshed for `61adc89`, `3ff2c7e` and the operational receipts above. |

Uncertainties:

- Feature areas group several capabilities (research notes), so some
  sub-features above (for example automation triggers) are enumerated from
  Wattly's one-line descriptions, not a full spec.
- Whether Fleet Telemetry exposes a given field for George's vehicle (pack
  temperature, FSD, TPMS) is unverified until the capture.
- Wattly's HW4 restriction on FSD is advertised; Volta's applicability is
  unknown.

## How to update this file

1. Change a row only with evidence: a path on main, a merged PR, or a doc
   statement. Put the PR or commit in the Evidence cell.
2. Promote `in-progress` to `implemented` only when the workstream branch
   merges. Do not mark a row `source-verified` without a recorded review, and
   do not mark `native-verified` without a doc or receipt that records the
   observation on a device with real data (link it).
3. If a prerequisite is missing, use `need-data` and name the exact fields or
   endpoints; if it needs George's approval, use `need-consent` and say what
   is being approved. Do not use `implemented` for placeholders, mock data or
   derived decorations.
4. Add new fields or endpoints to "Backend contract requests", keep them
   nullable and metric, and mirror accepted ones in API.md and `Models.swift`.
5. Keep the trip worker's entries under "Trip detail" at the
   `<!-- TRIP-CONTRACT-REQUESTS -->` marker; replace the marker line only when
   filling it in, and keep the heading.
6. Update the "Last updated" date and baseline commit at the top.

## Placeholder sweep on feat/placeholder-screens

Scope: app and widgets, inspected with ComingLater/coming/soon/placeholder/TODO,
empty-state, and literal em-dash searches. Screens owned by other workers were
read only. This is branch evidence, not merged/live acceptance.

- **Tires**: the only remaining More ComingLater destination and Soon row
  (`MoreView.swift`, `MoreRoute.swift`, `ComingLaterView.swift`). Another worker
  owns it; ComingLater stays until that branch replaces Tires.
- **Dashboard Pack Temp**: hardcoded em dash and N/A, not a recorded pack
  temperature (`DashboardView.metricGrid`). **Weather** uses vehicle ambient
  temperature plus an icon inferred from temperature/device hour and a
  time-of-day gauge; no weather provider (`DashboardView.weatherCard`).
- **Controls/climate**: controls default disabled (`commandsAvailable=false`);
  command forwarding returns 501 on this baseline. Unknown lock/sentry/charge
  limit/temperature fields render Unknown or em dash. Another worker owns this.
- **Places / charging cost settings**: `PlacesView` is a real read-only geofence
  map. `AccountSettingsView` charging-cost settings has a Home-rate fallback
  “Coming later” card. Time-of-use rates
  and editing tariffs are not implemented.
- **Battery Climate** uses outdoor-temperature efficiency bands and estimated
  range, not pack-temperature conditioning history. **Specs & Warranty** uses
  TeslaMate vehicle facts but static US Model 3/Y Long Range warranty rules
  and a device-local purchase date,
  not a vehicle-specific Tesla warranty contract. Their missing readings use
  em dashes; they are not empty-only screens.
- **Battery Health, Stats, Mileage, Firmware, drive/charge/idle history, maps,
  account/vehicle settings and vehicle switching** have real data paths and
  specific empty states when no records/vehicle exist. Their conditional em
  dashes denote unrecorded measurements, unknown costs/currency, missing sample
  coverage or sparse analytics. They are not ComingLater screens.
- **Widgets** have real app-written App Group snapshots. Provider placeholder
  and gallery fixtures are WidgetKit preview data, not a live fake reading.
  Missing snapshots show “Open Volta”; optional/stale readings render em dashes.
  Refresh is app-driven, and Live Activities update while the app is active;
  independent background network/push refresh is not implemented.
- **Loading/design previews**: history skeleton blocks, dashboard redaction,
  DesignSystem sample tiles and DEBUG demo fixtures are loading/preview paths.
  No TODO implementation marker or other empty-only product screen was found.

Maintenance sources: item names/intervals and completion date/odometer are owner
entries in `volta.service_items/service_events`; next due/progress are derived
from the latest dated completion. Odometer source/time is shown explicitly.
Defaults are personal editable-on-creation reminders, not manufacturer guidance.
Charger sources: grouping is geofence ID, else address ID, else session ID (no
location inference); names/coordinates come only from TeslaMate geofences,
addresses and positions. Session count/last visit/energy/cost use charging_processes.
Average input power is the mean of recorded session energy-used divided by its
recorded duration, with the measured-session count shown. Incomplete total energy
or cost stays null; unknown currency is never substituted. MapKit supplies tiles.

Branch validation (2026-10-09): isolated PostgreSQL 17 production bootstrap +
`bun test` passed 115 tests (0 failures); server TypeScript typecheck and
`scripts/privacy-check.sh` passed. Xcode 26.6 `scripts/ios-build.sh` on an iOS 26.5
simulator built the app/widgets and passed 257 unit tests. Synthetic demo native
flow checked Maintenance rendering and completion reset, Charger Map pins,
location session navigation and charge detail. These observations do not claim
real-car acceptance or production schema rollout. No private screenshots are
tracked or attached to the PR.

Review fixes add correction/removal menus for items and completion records,
calendar-day completion timestamps, readable number entry, consistent Unicode
name validation, preserved session pages on returning from detail, guarded
optional migration grants, and noninteger duration power calculations. Scale
verification includes the service endpoint: 62–67 ms with 1,722,500 positions;
all recorded odometers remain eligible even when battery-range fields are absent.
Suggested interval presets require an owner-added item and a logged completion;
no fictitious maintenance baseline is created automatically.
