# Fleet Telemetry cost and guard

Status: staged off. These controls do not create a vehicle configuration until
an operator calls commander's private create endpoint. The receiver, meter,
commander and database stay private; only the separately approved raw TCP
Funnel listener on port 10000 is public.

## Price and planning assumptions

Tesla publishes **150,000 streaming signals per USD**. That is about
`$0.00000667` per signal. Tesla's own example expresses the same rate as 15
signals costing `$0.0001` per minute. The `$0.0001/signal` shorthand would be
15 times higher and is not used by the ledger or guard.

The planning month is one car with 30 driving hours, 120 AC charging hours,
4 DC charging hours, 300 awake hours and 600 connections. A connection can
send one startup snapshot of every top-level field. The normal profile sends:

- `Location` at most every 2 seconds after 3 metres of movement, with
  `VehicleSpeed`, `GpsHeading`, `PackVoltage`, `PackCurrent`,
  `LongitudinalAcceleration` and `LateralAcceleration` co-timed in the same
  payload. These six includes require client 1.3.0 or newer.
- SOC, energy remaining and odometer every 30 seconds when changed; ranges,
  battery module min/max and inside/outside temperature every 60 seconds when
  changed. Temperature fields also use a 0.5 degree minimum delta.
- AC charging power, AC/DC energy-in, charge amps, charger voltage and
  time-to-full at 60 seconds when changed. DC charging power remains at 10
  seconds for fast-charge power shape; discrete charge state remains event-like.

Fleet Telemetry sends only after both the interval has elapsed and the value
has changed. The estimate below deliberately treats continuous fields as if
they change at every interval. The theoretical maximum also treats discrete
fields that way.

Per-field normal-profile planning math follows. `Signals` includes activity
plus 600 reconnect snapshots; each snapshot conservatively counts the parent
and every include, even when the same include appears under another parent.

| Field | Interval s | Includes | Activity h | Activity signals | Reconnect signals | Signals | USD |
|---|---:|---:|---:|---:|---:|---:|---:|
| Location | 2 | 6 | 30 | 378,000 | 4,200 | 382,200 | $2.54800 |
| Soc | 30 | 0 | 154 | 18,480 | 600 | 19,080 | $0.12720 |
| BatteryLevel | 30 | 0 | 154 | 18,480 | 600 | 19,080 | $0.12720 |
| EnergyRemaining | 30 | 0 | 154 | 18,480 | 600 | 19,080 | $0.12720 |
| ModuleTempMin | 60 | 0 | 300 | 18,000 | 600 | 18,600 | $0.12400 |
| ModuleTempMax | 60 | 0 | 300 | 18,000 | 600 | 18,600 | $0.12400 |
| InsideTemp | 60 | 0 | 300 | 18,000 | 600 | 18,600 | $0.12400 |
| OutsideTemp | 60 | 0 | 300 | 18,000 | 600 | 18,600 | $0.12400 |
| ACChargingPower | 60 | 2 | 124 | 22,320 | 1,800 | 24,120 | $0.16080 |
| RatedRange | 60 | 0 | 154 | 9,240 | 600 | 9,840 | $0.06560 |
| EstBatteryRange | 60 | 0 | 154 | 9,240 | 600 | 9,840 | $0.06560 |
| IdealBatteryRange | 60 | 0 | 154 | 9,240 | 600 | 9,840 | $0.06560 |
| DCChargingPower | 10 | 2 | 4 | 4,320 | 1,800 | 6,120 | $0.04080 |
| ChargeAmps | 60 | 0 | 124 | 7,440 | 600 | 8,040 | $0.05360 |
| ACChargingEnergyIn | 60 | 0 | 124 | 7,440 | 600 | 8,040 | $0.05360 |
| DCChargingEnergyIn | 60 | 0 | 124 | 7,440 | 600 | 8,040 | $0.05360 |
| Odometer | 30 | 0 | 30 | 3,600 | 600 | 4,200 | $0.02800 |
| LifetimeEnergyUsed | 60 | 0 | 30 | 1,800 | 600 | 2,400 | $0.01600 |
| LifetimeEnergyGainedRegen | 60 | 0 | 30 | 1,800 | 600 | 2,400 | $0.01600 |
| ChargerVoltage | 60 | 0 | 124 | 7,440 | 600 | 8,040 | $0.05360 |
| TimeToFullCharge | 60 | 0 | 124 | 7,440 | 600 | 8,040 | $0.05360 |
| Locked | 5 | 0 | 300 | 600 | 600 | 1,200 | $0.00800 |
| SentryMode | 5 | 0 | 300 | 600 | 600 | 1,200 | $0.00800 |
| TpmsPressureFl | 1,800 | 0 | 300 | 600 | 600 | 1,200 | $0.00800 |
| TpmsPressureFr | 1,800 | 0 | 300 | 600 | 600 | 1,200 | $0.00800 |
| TpmsPressureRl | 1,800 | 0 | 300 | 600 | 600 | 1,200 | $0.00800 |
| TpmsPressureRr | 1,800 | 0 | 300 | 600 | 600 | 1,200 | $0.00800 |
| Gear | 1 | 0 | 30 | 360 | 600 | 960 | $0.00640 |
| DetailedChargeState | 5 | 0 | 300 | 300 | 600 | 900 | $0.00600 |
| ChargingCableType | 60 | 0 | 300 | 150 | 600 | 750 | $0.00500 |
| ChargePortDoorOpen | 5 | 0 | 300 | 150 | 600 | 750 | $0.00500 |
| ChargePortLatch | 5 | 0 | 300 | 150 | 600 | 750 | $0.00500 |
| FastChargerPresent | 60 | 0 | 300 | 60 | 600 | 660 | $0.00440 |
| ChargeLimitSoc | 60 | 0 | 300 | 30 | 600 | 630 | $0.00420 |
| Version | 3,600 | 0 | 300 | 3 | 600 | 603 | $0.00402 |

| Case | Signals/month | Gross telemetry cost |
|---|---:|---:|
| Normal planning model | 636,003 | $4.2400 |
| Startup snapshots, included above | 27,000 | $0.18 |
| Normal theoretical maximum | 1,875,900 | $12.5060 |
| One full resend of that theoretical month | 3,751,800 | $25.0120 |
| Economy warning line | 3,000,000 | $20.00 |
| Delete line | 3,450,000 | $23.00 |
| Telemetry ceiling | 3,750,000 | $25.00 |

Reproduce the estimate and the generated commander profile offline:

```sh
cd ingestion
go run ./cmd/volta-telemetry-config -mode=budget
go run ./cmd/volta-telemetry-config -mode=profiles
```

These commands print configuration math only. They do not read credentials or
contact Tesla.

The gap from $20 to $23 gives the controller time to install the economy
profile, observe delayed/replayed records and then delete the config. The
$25 ceiling leaves a further $2 response margin. Tesla's real signal ledger,
including rejected VINs and resends, controls the state; the estimate never
overrides measured usage.

A hypothetical full resend of every theoretical-maximum signal is slightly
above the telemetry ceiling. The measured ledger switches profiles at `$20`
and deletes at `$23`, so the estimate is a stress case rather than permission
to spend through `$25`.

The consumer and commander must agree on these lines:
`TELEMETRY_RESERVATION_USD=25`, `TELEMETRY_WARN_RATIO=0.8` and
`TELEMETRY_STOP_RATIO=0.92`. Commander's independent absolute checks remain
authoritative if the meter is misconfigured. A meter `stop` deletes immediately;
`unknown` permits only the bounded projected-spend grace below.

Signed configs expire after 30 days. While an active config remains below the
guard lines, commander renews it during the final 24 hours. A stopped or
latched config is never renewed.

Before any signed create/update request, commander durably marks that vehicle
as managed with a pending action. A crash, timeout or malformed POST response
therefore becomes a delete-on-restart condition; an unknown first-create
outcome can never leave an unguarded config on the car.

At `$20` or the meter's `warn` state, commander replaces the normal profile
with an economy profile: 10-second location with speed/current/voltage,
120-second core battery fields and 300-second temperature/energy fields. At
`$23`, `stop`, or the shared operating line, commander durably latches stopped
and sends `DELETE /api/1/vehicles/{vin}/fleet_telemetry_config`. An unknown,
stale or unreachable meter permits at most five minutes of grace, only with
durable last-complete accounting and projected spend strictly below both stop
lines. Projection uses **1,000 signals/second per configured VIN**, elapsed
since last complete accounting (not just since the error), plus a 30-second
reconciliation/network margin. Any higher observed current-month lower bound
also counts. This exceeds configured field cadence/snapshots, but arbitrary
upstream replay is not a hard bounded guarantee. No baseline means immediate
DELETE. Grace cannot extend across commander restarts: its start is durable.

At UTC rollover, the meter returns current-month `starting` until refreshed;
commander permits a previous-month baseline only in the first five minutes,
projecting new-month burn from 00:00Z. It never carries previous-month spend
into that projection. A failed DELETE stays pending and retries after restart
with durable exponential backoff from 15 seconds to six hours. `stopReason`
distinguishes meter outages from budget, operator and uncertain config stops.
Only a `meter_*` stop auto-resumes after DELETE succeeds and complete current
accounting stays below `$20` and the shared line for ten continuously observed
minutes, with fresh paired-key/client preflight and normal paid-call reservations.
Automatic resume attempts use a separate durable per-vehicle UTC-month counter,
capped at three, and a 10/20/40-minute exponential cooldown saved before preflight.
Successful create/DELETE never resets this history. `auto_resume_limit` requires
operator action even after rollover; an unpaired key/old client also requires
operator action and an exhausted paid-call lane records `budget_stop`.
Every config create/update/renewal (including operator POST) requires unused
DELETE reserve for two fresh target attempts plus other possibly-live configs'
unused two-attempt claims. It fails with
HTTP 429 `telemetry_delete_reserve_insufficient` before a config POST when this
headroom is missing; automatic recovery/update uses `delete_reserve_stop`.
DELETE reservations persist per-config attempts and cannot consume another
potentially live config's unused two-attempt claim. Both vehicles can spend
their own attempts without stranding the last call. Unknown POST outcomes remain owned, but a refused first create does not
cause a DELETE. Confirmed successful deletions are durably idempotent: operator
repeats return `alreadyDeleted:true` without another paid call; new POST/remote
confirmation invalidates the proof. Unowned/unconfirmed stops return 409 rather
than inventing a successful rollback. This bounds flapping independently of the shared polling lane;
three automatic successes plus initial creation and four successful deletions
cost at most 16 calls ($0.024 normal, $0.008 DELETE) per vehicle/month. Failed
deletions still depend on the bounded reserve and working network/OAuth.
A budget/operator/config-outcome
latch never auto-clears, even on rollover. A later known budget stop upgrades a
meter latch to a budget latch.

## Shared account budget

With telemetry enabled, commander's polling budget defaults to **$5/month**:
2,500 conservative `$0.002` reservations. A TeslaMate summary plus
`vehicle_data` cycle uses two calls, so this is roughly 1,250 fallback cycles,
or one complete cycle every 35 minutes over a 30-day month. Dense trip and
charge segmentation comes from telemetry; polling remains for coarse state,
TeslaMate compatibility and fallback.

The configured ceilings are `$25 telemetry + $5 polling = $30 gross/month`.
George's existing `$10` account credit is shared, so a full guarded month can
incur about `$20` beyond the credit. In the Tesla developer portal, set the
billing limit above the guard's combined maximum before enabling telemetry;
`$35` gives operational headroom while commander's own limits remain `$30`.
Tesla removes telemetry configurations when its billing limit is hit, which is
why the local stop line must be lower than the portal limit.

Normal paid Fleet API calls stop at the smaller of the `$5` polling allowance
and the **$28 operating line** (`$30 total - $2 delete reserve`). Every
preflight, signed config POST, config status GET and automatic renewal reserves
its `$0.002` before contacting Tesla. The remaining `$2` is available only to
signed DELETE attempts. It hard-limits those attempts to 1,000 per UTC month;
the durable 15-second-to-6-hour backoff permits at most about 130 automatic
attempts in 30 days (`$0.26`). Safety DELETE is bounded only by this separate
reserve, even when observed telemetry plus polling exceeds the `$30` total;
refusing removal at high spend would allow further streaming.

The meter bearer secret is mounted as the single root-owned `status-secret`
file and read through `COMMANDER_TELEMETRY_METER_SECRET_FILE`; it is not copied
into the commander environment. `COMMANDER_TELEMETRY_DELETE_RESERVE_USD=2`
sets the separate delete reserve.

Once a vehicle has a managed config, keep the commander telemetry overlay and
guard running. To disable or roll it back, call the private DELETE endpoint and
verify the durable state is `stopped` with no pending action before removing
the overlay. Merely setting `COMMANDER_TELEMETRY_ENABLED=false` cannot delete a
configuration already stored on the car.

## OAuth, pairing and operator flow

Tesla's current documentation requires `vehicle_device_data` for vehicle data
and `vehicle_location` for `Location` and `GpsHeading`. Volta already requests
both in its read-only OAuth grant, so Fleet Telemetry does not add a scope or
require new consent when those scopes are already present. A user who did not
grant both must reconnect and grant them.

The paired virtual key is a separate prerequisite. On George's phone open:

`https://tesla.com/_ak/georgenijo.com`

Select the vehicle and approve the key in the Tesla app/car. Commander meters
one `fleet_status` preflight and proceeds only when `key_paired_vins` contains
the configured VIN and `fleet_telemetry_version` is at least `1.3.0`. Missing
pairing returns `virtual_key_not_paired`; missing access returns
`permission_denied`.

After the reviewed stack is deployed and the private meter reports complete,
fresh accounting, an operator uses commander's authenticated private listener:

```sh
sudo curl --fail --config /etc/volta/commander-operator.curl -X POST \
  http://127.0.0.1:8090/v1/vehicles/1/telemetry/config

sudo curl --fail --config /etc/volta/commander-operator.curl \
  http://127.0.0.1:8090/v1/telemetry/status

sudo curl --fail --config /etc/volta/commander-operator.curl \
  http://127.0.0.1:8090/v1/vehicles/1/telemetry/config

sudo curl --fail --config /etc/volta/commander-operator.curl -X DELETE \
  http://127.0.0.1:8090/v1/vehicles/1/telemetry/config
```

The referenced curl config is a root-owned mode-0600 file containing the
authorization header. Generate it on the node from the protected commander
environment without echoing either value, and never show its contents or use a
header containing the secret in process arguments. Run these only in the
private operator shell. The create endpoint loads the certificate chain from
the mounted file, signs through `tesla-http-proxy`, and never returns a VIN,
token, key or certificate. Configuration uses the existing read-only OAuth
scopes; commands remain disabled.

Official references checked 2026-10-08:

- [Fleet Telemetry overview and billing behavior](https://developer.tesla.com/docs/fleet-api/fleet-telemetry)
- [Available fields](https://developer.tesla.com/docs/fleet-api/fleet-telemetry/available-data)
- [Vehicle endpoints](https://developer.tesla.com/docs/fleet-api/endpoints/vehicle-endpoints)
- [OAuth scopes](https://developer.tesla.com/docs/fleet-api/authentication/overview)
- [Virtual key guide](https://developer.tesla.com/docs/fleet-api/virtual-keys/developer-guide)

## Estimation and billing-month limits

Ledger months use UTC. Tesla's billing-month timezone is undocumented; verify
its month boundary and credit treatment against the Tesla portal before enabling.
An up-to-approximately-eight-hour skew is covered operationally by the local
stop-versus-portal-limit gap, subject to that live comparison.

The planning model omits parked-awake GPS jitter and receiver rate-limit or
retention drops. Jitter can increase signals; drops do not establish billing
completeness or permission to subtract spend. Conservative receipts, unknown
coverage handling, bounded outage grace and the cost guard contain these cases;
the `$4.2400` planning estimate is not a spend guarantee.
