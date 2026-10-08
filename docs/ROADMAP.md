# Volta roadmap

Scope agreed for research on **2026-10-07**. This is a delivery plan, not a
claim that the app, logger, or infrastructure has passed live acceptance.
[SPEC.md](SPEC.md) and [API.md](API.md) remain the implementation contracts.
Tesla prerequisites are in [TESLA.md](TESLA.md); hosting and installation are
in [DEPLOY.md](DEPLOY.md).

## Basis and scope decisions

The input is the 23-area public feature inventory in
`/Users/macbook/Documents/reports/wattly-feature-map-20261007/feature-map.json`
and its `research-notes.md`, plus the 12 Wattly reference screenshots (kept in the private repo, not published here).
The inventory groups advertised capabilities; it does not establish Wattly's
implementation or formulas. The screenshots establish visual direction and
empty-state examples, not data availability. Volta uses its own name and assets.

| Area | Volta decision |
|---|---|
| 01 Live vehicle | Phase 1 last-recorded dashboard; Phase 3 streaming freshness and additional supported signals. |
| 02 Drive detail | Phase 1 route, elevation where recorded, energy and efficiency. Defer driving score and FSD breakdown. |
| 03 History & replay | Phase 1 paginated history/date filters and route detail. Defer search/comparisons, heatmaps, 3D replay and sharing exports. |
| 04 Efficiency statistics | Phase 1 Today/7D/30D summaries and basic drive/charge aggregates; defer richer comparisons. |
| 05 Battery health | Phase 1 rated-range trend and explicitly estimated health/capacity; defer cycles and thermal analysis until inputs are proven. |
| 06 Live charging | Phase 1 recorded current status and session curves; Phase 3 streaming updates. |
| 07 Charging costs | Phase 1 stored TeslaMate session costs/geofence rates and explicit currency. Defer time-of-use, receipts, exchange rates, energy mix and gasoline comparisons. |
| 08 Parked & drain | Phase 1 derived idle gaps and battery/range loss with missing-data handling. |
| 09 Climate | Phase 1 recorded read display; Phase 2 supported climate commands. |
| 10 Vehicle controls | Phase 1 unavailable Controls UI; Phase 2 explicit manual commands. |
| 11 Automations | Phase 3 opt-in server rules with bounded actions and audit history. |
| 12 Chargers & planning | Defer external charger/routing datasets; drop community prices/photos/comments. |
| 13 Maintenance | Defer private service log/reminders; no Phase 1 endpoint exists. |
| 14 Firmware | Phase 1 own vehicle version/install history; defer fleet rollout statistics and external release notes. |
| 15 Mileage & work | Phase 1 mileage buckets; defer lease allowances, work classification and expense PDFs. |
| 16 Professional mode | Defer client records, invoicing and jurisdiction-specific accounting. |
| 17 FSD center | Optional Phase 3 extension only after vehicle/hardware/field validation; no promise of Wattly parity. |
| 18 Community & passport | Drop community, friends, awards, competitions, referrals and social maps. |
| 19 Dashcam Studio | Defer USB import/video tooling as a separate project. |
| 20 Apple surfaces | Phase 3 widgets, Live Activities and selected Shortcuts; defer Watch app. |
| 21 Personalization | Phase 1 units/currency, vehicle selection, security and pairing; defer themes/layout editing and settings sync. |
| 22 Import & export | Phase 1 reads the existing TeslaMate DB directly; no bulk import. Defer versioned exports and other providers' imports. |
| 23 AI & MCP | Drop AI assistants, MCP control, chat and provider data copies. |

Deferred items are outside the three-phase acceptance baseline and need a new
scope decision. Weather, tires, warranty and battery temperature shown in the
references ship only if the contract and collector actually supply them; use
unknown/unavailable states rather than synthetic readings in connected mode.

## Phase 1 — private read-only analytics

### Scope

Deliver pairing and Keychain device-token storage; dashboard map, battery/range,
recorded temperatures/status, 48-hour timeline and activity ranges; drive list
and detail; charging list, curves, costs and places; idles/drain; estimated
battery health; mileage; firmware; units/currency and optional biometric lock.
Controls remain visibly unavailable and command endpoints return
`501 commands_unavailable`. Refreshing Volta reads the DB and never wakes the car.

“Read-only” applies to TeslaMate vehicle history: Volta may write device hashes
and its own metadata in the separate `volta` schema. Its database role must not
access the credential schema `private` or modify logger tables. Cost/tariff
editing stays in TeslaMate until a separately scoped Volta write contract exists.

### Dependencies

- An authenticated, collecting TeslaMate 4.3.0 instance and PostgreSQL 17;
  current deployment and schema must be checked after Ubuntu access is restored.
  If Owner API is unavailable, the conditional Fleet collector checklist in
  TESLA.md becomes Phase 1 scope, with billing/resolution acceptance first.
- Bun/Hono server, least-privilege DB grants, private HTTPS over Tailscale,
  durable pairing metadata and a tested backup/restore path.
  Restrict TeslaMate/Grafana's separate admin ports to selected devices and
  disable anonymous Grafana; Volta device-token revocation cannot protect them.
- Xcode with the iOS 26 SDK, XcodeGen, an iOS 26 phone, and Apple signing access.
- TeslaMate schema/field audit: `positions` is history, not a complete live
  vehicle snapshot. Some API.md status fields and sentry/climate duration
  breakdowns may be unavailable. Return `null`; resolve contract mismatches
  with the backend owner before claiming completion.

### Acceptance checks

1. Build the simulator app and render every included screen with populated,
   empty, stale, partial and failed data; compare reference density/layout,
   check scrolling, Dynamic Type and accessible unavailable controls.
2. Run server checks against a seeded 4.3 schema; compare known drive/charge
   totals with SQL/Grafana, validate UTC/DST boundaries, units, pagination,
   currency and zero-versus-null behavior. Empty records cannot imply zero cost.
3. Verify single-use 10-minute pairing expiry, invalid/rate-limited attempts,
   Keychain persistence, device revocation and rejection of revoked tokens.
   Prove the DB role cannot access `private` or change history; prove an
   unapproved device cannot reach the independent TeslaMate/Grafana UIs.
   Document Keychain device-only accessibility and validate lock/relaunch
   behavior; defer extension-sharing choices until Phase 3 design.
4. On the installed iPhone, pair over private HTTPS on Wi-Fi and cellular,
   open each data flow, disconnect/reconnect Tailscale and recover cleanly.
   Verify the running app/API revisions and a recent logger timestamp.
5. Observe no Tesla calls/wakes from browsing; unavailable commands have no
   side effects. Complete a restore into an isolated database before live use.

### Risks

Owner API authentication can change; logger downtime creates permanent history
gaps. Small or temperature-biased samples cannot establish diagnostic battery
health. Idle battery differences do not prove Sentry caused the drain. Rated
range is not measured usable capacity. Missing prices cannot produce reliable
cost totals. Keep these limitations visible without blocking basic history.

## Phase 2 — manual vehicle commands

### Scope

Add a server command broker using official Fleet API OAuth and Tesla's
`vehicle-command` proxy. Enable a capability-checked subset of lock/unlock,
trunk/frunk, climate/preconditioning, charging start/stop/limit, Sentry,
lights/horn and charge-port operations. Omit unsupported vehicle features.
Public-key hosting and OAuth setup are separate from private `volta-api`.
The phone retains only its Volta token; Tesla secrets and signing keys stay
on the server. Automations are not part of this phase.

### Dependencies

Tesla application approval, region registration, domain/public key, billing
limit, user consent, virtual key pairing and verified vehicle capabilities
([TESLA.md](TESLA.md)). Add scoped command authorization distinct from read
pairing; a paired analytics device does not silently gain control. Extend the
API contract for command results, authorization and capability reporting.

### Acceptance checks

1. Validate the private OAuth callback, state, serialized atomic refresh-token
   rotation/crash recovery, revocation and server-only secret storage;
   prohibit shared collector/broker token chains.
   Verify public key and `fleet_status` on George's actual vehicle.
2. Exercise the broker/proxy with fake upstreams for missing key/scope,
   sleeping/offline vehicle, rejected parameters, timeouts, rate/billing limits
   and duplicate requests. Unknown outcomes must not trigger blind repeats.
3. After George authorizes vehicle testing, perform a safe supported command
   and observe the resulting vehicle state. An HTTP acknowledgment alone is
   insufficient. Require fresh local user authentication (biometric or device
   passcode) and explicit confirmation for sensitive unlock/open operations,
   plus a bounded server-side command grant. Confirm no automatic wake
   from dashboard refresh, revocation enforcement and sanitized audit records.
4. Inspect usage against the approved billing cap; preserve Phase 1 history
   access when Tesla command access fails.

### Risks

Commands change physical state. Signed-command requirements vary by vehicle;
OAuth alone is insufficient. Token/key rotation, wake costs, stale state and
uncertain command delivery need explicit handling. New fields/endpoints require
cross-family review and live acceptance before controls are considered usable.

## Phase 3 — streaming, Apple surfaces and automations

### Scope

Operate Tesla's Fleet Telemetry receiver, feed a durable local queue/store and
normalize streamed observations into Volta's analytics model. Replace routine
vehicle-data polling only after field coverage and session derivation are
proven. Retain the TeslaMate archive; do not write an undocumented imitation
schema or run competing collectors without a deduplication plan.

Provide cached widgets, charging Live Activities, selected App Intents, and
opt-in rules for schedules/battery/temperature/location with notifications
and allowlisted Phase 2 actions. Optional FSD statistics require supported
HW4 signals; they are not a core completion gate.

### Dependencies

Phase 2 key/consent setup; supported vehicle firmware; public TLS ingress with
mTLS terminating at Fleet Telemetry; signed vehicle configuration; local
dispatch/retention; monitoring, renewal and backup procedures. TeslaMate 4.3
needs a stream adapter for this path; design a self-hosted adapter or an
independent ingestion service, with no hosted vehicle-data intermediary.

WidgetKit/ActivityKit integration and shared cached state require additional
app contracts. Remote Live Activity updates/alerts may need APNs and paid Apple
membership; Apple then processes push payloads. Decide whether that fits the
privacy goal, use minimal payloads, and do not equate a tailnet with background
execution permission. Widgets must tolerate suspended apps and VPN outages.

### Acceptance checks

1. Validate TLS chain/hostname and vehicle client certificates; reject invalid
   peers. Confirm signed configuration, virtual key, scopes and actual incoming
   signals. Test certificate renewal and revoked consent.
2. Verify queue durability, duplicate/out-of-order handling, bounded retention,
   reconnect/replay and restart recovery; show explicit gaps and stale times.
   Compare complete drives/charges against the polling baseline before cutover.
3. Observe reduced polling/wakes and actual Tesla billing with bounded field
   intervals/deltas; alert on missing stream/configuration and restore a
   removed configuration only after the underlying billing issue is resolved.
4. On iPhone, exercise widget and Live Activity freshness/end states with the
   app foregrounded, suspended and disconnected; measure actual update behavior.
5. Test rules across DST, missed schedules, stale sensor inputs, restart and
   duplicate delivery. Dry-run first; require explicit enablement, cooldowns,
   maximum retries, a disable switch and an audit record of each decision/action.

### Risks

Home uplink downtime and public ingress become collection risks. Streaming is
not equivalent to every polling field. Billing suspension can remove telemetry
configuration. iOS background limits prevent continuous phone-side polling;
server rules must survive without the phone. Location rules and push surfaces
can expose sensitive information. Do not automatically unlock/open the vehicle
from an ambiguous trigger.
