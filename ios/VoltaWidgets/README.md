# VoltaWidgets

WidgetKit extension (`com.georgenijo.volta.widgets`) with:

| Widget | Kind / type | Families |
|---|---|---|
| Home Screen | `VoltaHomeWidget` | `systemSmall` (battery, range, state), `systemMedium` (+ doors, climate, inside/outside temp, last updated), `systemLarge` (+ today's activity, 48h strip) |
| Lock Screen | `VoltaAccessoryWidget` | `accessoryCircular` (battery gauge), `accessoryRectangular` (battery + range + bar), `accessoryInline` |
| Live Activity | `ChargingActivityAttributes` | Lock Screen banner, Dynamic Island expanded / compact / minimal: SOC toward the charge limit, kW, countdown to the limit, energy added, range |
| Live Activity | `DrivingActivityAttributes` (optional) | distance this drive, battery, range, elapsed time, energy used |

Every family and Live Activity state has an Xcode `#Preview` with fixture data
(`Extension/Fixtures.swift`, mirroring `MockDataSource`'s "Friday").

## Layout

```
VoltaWidgets/
  Shared/     compiled by BOTH the app and the extension (Foundation + ActivityKit only)
    WidgetSnapshot.swift          WidgetSnapshot, WidgetSnapshotStore, VoltaAppGroup
    VoltaActivityAttributes.swift ChargingActivityAttributes, DrivingActivityAttributes
  AppSide/    compiled by the APP ONLY (uses ios/Volta/Core models)
    WidgetBridge.swift            VehicleStatus -> WidgetSnapshot mapping, WidgetSnapshotStore.reset()
    LiveActivityPlanner.swift     pure start/update/finish/dismiss decisions (unit tested)
    WidgetSync.swift              VehicleSurfaces: writes the snapshot, applies plans via ActivityKit
  Extension/  compiled by the EXTENSION ONLY (views, provider, bundle)
```

The extension never compiles `ios/Volta/**`; it only sees `Shared/`. Keep
`Shared/` free of app types so that stays true.

## Integration (app target, ios/project.yml)

1. Pull in the extension target:

   ```yaml
   include: [project.widgets.yml]
   ```

2. In `targets.Volta`:

   ```yaml
   sources:
     - path: Volta
     - path: VoltaWidgets/Shared     # snapshot + ActivityAttributes
     - path: VoltaWidgets/AppSide    # WidgetSync, planner, snapshot mapping
   dependencies:
     - target: VoltaWidgets          # embeds VoltaWidgets.appex
   entitlements:
     path: Volta/Volta.entitlements
     properties:
       com.apple.security.application-groups: [group.com.georgenijo.volta]
   info:
     properties:
       NSSupportsLiveActivities: true
       # optional, for widget taps (volta://dashboard, volta://charging, volta://drives)
       CFBundleURLTypes:
         - CFBundleURLName: com.georgenijo.volta
           CFBundleURLSchemes: [volta]
   ```

   `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` must match between the app
   and the extension. `project.widgets.yml` sets `1.0` / `1`; if project.yml
   defines them at project level, delete those two lines from the extension.

3. Both targets need the App Group capability `group.com.georgenijo.volta`
   registered on the developer team for device builds (the simulator does not
   enforce it).

## How the app drives them

`AppModel` owns a `WidgetSync` (`AppModel.surfaces`, also injected as the
`\.vehicleSurfaces` environment value) and tells it the current
`VehicleSurfaceContext` on every pairing, demo or vehicle change:

| Context | When | Effect |
|---|---|---|
| `.vehicle(id, name)` | paired, vehicle list loaded | publishes are accepted; switching vehicles clears another vehicle's snapshot and ends its activities immediately |
| `.inactive` | unpaired, or any demo mode (including launch-only) | snapshot deleted, all Volta Live Activities ended immediately |
| `.suspended` | Keychain still locked after prewarm | nothing written, nothing cleared (the saved pairing survives) |
| `.pending` | paired, vehicles not loaded yet | nothing written |

The app injects no publisher into demo screens, so synthetic refreshes never
reach `WidgetSync`. Real paired screens call `surfaces.publish(VehicleRefresh(...), dataSource:)` after every
successful status load: Dashboard (launch, pull-to-refresh, retry, return to
foreground after 30 s) and Controls (refresh after commands). Each publish:

1. writes the snapshot (keeping the previous snapshot's timeline for the same
   vehicle when the refresh did not load it, and its today totals only within
   the same reporting day; after it ends they become unknown) and calls
   `WidgetCenter.shared.reloadAllTimelines()`;
2. fetches the newest charge/drive (last 7 days) only when needed, plans with
   `LiveActivityPlanner`, and applies the plan through ActivityKit. Work is
   serialized so two refreshes never start two activities.

Refreshes from different screens can finish out of order (Dashboard waits on
summaries while Controls publishes). Callers take a `StatusRequestToken`
(`surfaces.nextStatusToken()`) immediately before issuing `/status` and pass it
in `VehicleRefresh.issued`; `WidgetSync` accepts a publish only if its token is
greater than the last accepted one for the vehicle, before writing the snapshot
or queueing activity work. Request issue order, not telemetry time: the
backend's `updatedAt` can decrease when a session closes and can stay equal
across different states. On unpair, demo and a switch to another vehicle the
watermark is fenced to the last token issued, so requests issued before the
change never publish after it (including A -> B -> A). Entering the first
vehicle from `.pending` at launch is not a fence: Dashboard may already have
issued its first request for the saved vehicle. The counter never resets.

Every ActivityKit change goes through one FIFO mutation lane. A sync fetches
session history outside the lane, then enqueues its changes and re-checks
inside the lane that it is still current (and re-reads the driving
preference). Context changes (unpair, demo, vehicle switch) and turning off
"Show while driving" enqueue an immediate end of the activities present at
that moment (by id): they never wait for a sync's network fetches, they
invalidate queued syncs (epoch + cancellation), and later syncs cannot
interleave with them or have their new activities ended by them.

**Reporting day:** the app sends the device zone as `tz` to `/summary`.
Servers that support it count "today" from local midnight and report
`periodStart`/`timeZone`; the totals' day is then [periodStart, next local
midnight) (23 or 25 hours on DST days). Older servers ignore `tz`, count from
UTC midnight and report no period, so the day is the UTC day of the request
start (`TodaySummary.requestedAt`). `ReportingDay` (Shared/WidgetSnapshot.swift)
defines both; the dashboard and the snapshot use the same `TodaySummary.day`.
Totals are dropped (unknown) if that day ended before publishing. The snapshot
stores the day's start and end (`todayDay`/`todayDayEnd`), so the extension
needs no time-zone logic; snapshots from before `todayDayEnd` existed keep the
UTC rule they were written with. A local day also stores the device zone it
was requested in (`todayZone`): after a time-zone change (travel) its totals
are unknown in the app and widgets until a refresh in the new zone. The app
refreshes the dashboard and reloads widgets on `NSSystemTimeZoneDidChange`;
UTC-rule days have no zone check.

**Demo mode policy:** synthetic demo data never reaches the App Group or Live
Activities. Entering demo clears both, so widgets show "Open Volta".

### Live Activity rules

- Attributes carry `vehicleId` and the TeslaMate session id (`chargeId` /
  `driveId`). An activity for another vehicle, a different known session, or a
  duplicate is ended immediately and replaced. An activity started while the
  session id was unknown is replaced once the id becomes known, so its start
  details and final state belong to the right session.
- Unknown values stay `nil` and render as "—" (charge limit, energy added,
  distance, start time, charger type). Nothing defaults to 100% or 0.
- When a session ends, the activity gets final content (`phase`
  `.completed`/`.stopped`/`.ended`, `endedAt`, no power, frozen timer) and
  is dismissed 5 minutes later (`VoltaLiveActivityTiming.finalLinger`).
- Content is stale 20 min (charging) / 10 min (driving) after the vehicle data
  time. Every presentation (Lock Screen, expanded, compact, minimal) reads
  `context.isStale`: amber clock, dimmed values, no countdown.
- An unknown observation (car offline, no charging state) leaves the activity
  as is so it goes stale on its own. No activity starts from already-stale data.
- The charging activity is always on; driving is opt-in under
  Settings > General > Live Activities ("Show while driving").

## Data path

1. **Snapshot (implemented).** The app is the only network client. It writes a
   versioned JSON `WidgetSnapshot` (metric values + the user's display units)
   to the App Group container with `completeUntilFirstUserAuthentication`
   protection. `VoltaProvider` reads it; with no snapshot the widgets show an
   "Open Volta" empty state (the widget gallery shows fixture data). The
   timeline has entries every 10 min (5 min while charging) plus one at the
   exact moment the data turns stale (1 h) and when the reporting day ends
   (today totals carry their day and are hidden after it), so "Updated … ago" and the amber
   stale styling stay honest in every family, including small and Lock Screen.
   Live Activities are updated by the app via `WidgetSync` while it runs.

2. **Widget-side fetch (documented, not enabled).** To let the timeline
   provider refresh on its own:
   - store the device token with `kSecAttrAccessGroup = "<TEAMID>.com.georgenijo.volta.shared"`
     (`VoltaAppGroup.keychainAccessGroupSuffix`) and
     `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and add that group to
     `keychain-access-groups` in both targets' entitlements;
   - store the base URL (Tailscale host) in `UserDefaults(suiteName: "group.com.georgenijo.volta")`;
   - in `getTimeline`, `GET /v1/vehicles/{id}/status` (+ `summary?range=today`,
     `timeline?hours=48`) with `Authorization: Bearer <token>`, build a
     `WidgetSnapshot`, write it, and fall back to the stored one on failure.
     Note the extension only reaches volta-api when the phone's Tailscale VPN
     is connected, so the snapshot remains the primary path.
   - Charging Live Activities could also be driven by APNs push updates from
     volta-api (`pushType: .token`); not in phase 1.

## Screenshots

The private repo's `docs/screens/widgets/` holds renders of every family and Live Activity state
(`home-*`, `lock-*`, `live-*`) produced with `ImageRenderer` from the same
views and fixtures as the previews, plus `sim-dynamic-island-compact-charging.png`,
a real iOS 26.5 simulator screenshot of the charging Live Activity (taken
before the final-state and stale handling was added).
The `live-charging-expanded-*` images approximate the Dynamic Island's
expanded layout (regions arranged by hand), since `ImageRenderer` cannot
host `DynamicIsland` itself.
