# Fleet Telemetry capture and dense history

Status: **implemented, staged off**. This branch combines the original commits
from PR #17 (Build 6 trip UI) and #18 (capture), and supersedes them. PR #19 is
unaffected. Nothing here enables production, a vehicle config or Funnel.
Deployment follows the lead's cross-family review and merge; see
[exact operator steps](TELEMETRY_RUNBOOK.md) and [field cost math](TELEMETRY_COST.md).

## Private data flow

Car mTLS → partner-domain name → router TCP forward :443 → node LAN :8448 → official receiver → durable
Redpanda dispatcher → Go consumer → TeslaMate PostgreSQL `volta_telemetry` →
read-only Volta API → SwiftUI trip/charge detail.

Verified upstream release: **v0.9.5**, commit
`bd076fe1494841707528449560c4a19d0d426da4`, published 2026-09-28. Its official
image is pinned by SHA-256 in `ingestion/Dockerfile`. The unmodified binary
terminates TLS and trusts only Tesla's embedded production vehicle CA. Custom
vehicle CA, engineering CA, decoded logger dispatcher and VIN-labelled
Prometheus metrics are disabled in production. A wrapper suppresses all raw
receiver output, emitting only fixed event codes/counts and private liveness.

Only the receiver publishes, on `127.0.0.1:8448`. Broker, meter :8449 and liveness
:8450 are internal. Commander, API, TeslaMate and DB stay private. The certificate
chain for the vehicle config is the server certificate's intermediate/root,
distinct from Tesla's client-auth CA. Daily renewal restarts only an already
running receiver; it cannot activate the staged stack.

## Integrity and billing

Receiver ACKs vehicle data only after Kafka confirms a durable write (`acks=all`,
no write caching). Consumer offsets commit only after the PostgreSQL transaction
stores samples and a billing receipt. Replayed offsets are idempotent. Every
vehicle-data record is counted, including rejected VINs, malformed data and
resends. Uncountable/undated records make accounting a lower bound. Receipts are
never pruned; raw protobufs and rejections have bounded retention.

Queue completeness now requires durable checkpoints, exact topic-incarnation
IDs, retained-start offsets and receipt coverage. A retained suffix cannot prove
lost earlier history. Retention loss, topic replacement, missing partitions,
store errors or stale progress immediately make accounting unknown. Commander
deletes on unknown as well as stop; a recent checkedAt is not recent accounting.

Permanent SHA-256 VIN/vehicle-ID bindings reject reassignment in either direction
at consumer startup. API also checks the digest against TeslaMate's current car
VIN. Raw VINs are not stored in bindings or returned to iOS. Receiver identity
comes from the client certificate, not a spoofable payload VIN.

Freshness uses the exact receiver startup instant; a same-second CONNECTED event
from a previous generation cannot revive data. Every known disconnect creates
uncertainty, including short breaks with buffered records. Affected derived
sessions become partial and routes break. Absent, invalid and conflicting fields
remain distinct. No field is carried forward. Voltage/current from separate
payloads never combine; drive power stays null until operator sign calibration.

## API and iOS

`FLEET_TELEMETRY_ENABLED=true` adds an optional `telemetry` envelope to existing
drive/charge detail, joining exact car binding and TeslaMate session time window.
Legacy polling arrays remain unchanged and old drives keep their sparse handling.
Reads expose only views and permitted metadata, never raw records or ingest writes.
See [API contract](API.md).

Independent-time series include speed, calibrated power, battery percent,
remaining kWh, module min/max temperature, inside/outside temperature and charge
electrical fields. `invalidFields` distinguishes explicitly invalid/conflicting
fields from an absent slow signal. The API selects at most 2,000 samples evenly
across the full session, preserving metric boundaries and extrema; it reports
source/returned counts, per-metric coverage, downsampling and omitted-gap truncation.
The client compares each metric's session coverage, density and gaps with the
legacy data before choosing it. Partial/mid-session telemetry falls back per metric;
uncalibrated telemetry power cannot remove legacy power/regen. Signal-only rows
never receive fabricated GPS. Chart x-domains span the complete session, and drive
telemetry charts share map/replay scrub selection. Charts respect invalid readings,
declared gaps and long lapses; selection cannot jump into a gap. Volta Smoothness
v1 derives acceleration from sufficiently dense speed samples and preserves its
coverage gates. An optional telemetry query failure logs a fixed code and returns
`telemetry: null`, keeping the legacy detail available.

There is no telemetry elevation field. Reuse TeslaMate SRTM only from the same
drive within 60 seconds and 50 metres; unmatched elevations remain null. No
coordinate/address is sent to an external elevation or geocoding service.

The API enriches **TeslaMate sessions**. Telemetry-derived sessions are stored
separately and do not create TeslaMate rows or new history-list items. A drive
TeslaMate never segments cannot appear in its list. Validate segmentation with
reduced polling before accepting the $5 fallback lane for real use.

## Guard and cost

Tesla charges 150,000 signals/USD, about $0.00000667 per signal. The normal profile
requests location every 2 s with co-timed speed, heading, current/voltage and two
acceleration fields; slow fields use delta filters and longer intervals. The
30-driving-hour planning month is about **$4.24 gross**, below the requested
approximately $20 target. The estimate is a planning model, not a billing bound.

Telemetry reservation $25: switch to economy at $20; delete/latch at $23 or
unknown/stale/unreachable metering. Polling/normal Fleet calls have a $5 lane.
Combined operating threshold $28 plus a separate $2 DELETE-only reserve stays
inside $30 gross. Deletion failures persist and retry with bounded backoff across
restart. No automatic reenable on month rollover. Active signed configs renew
before their 30-day expiry. [Per-field math](TELEMETRY_COST.md) includes startup
parent/includes and a whole-month resend scenario.

Private operator create/delete/status endpoints use existing internal auth and
the proxy signer while physical controls stay disabled. Create meters fleet_status,
requires a paired key/client >=1.3.0 and reports `virtual_key_not_paired` clearly.
Existing read-only `vehicle_device_data`/`vehicle_location` scopes suffice when
both were granted. George pairs at `https://tesla.com/_ak/georgenijo.com`.

## Verification and remaining gates

Offline tests cover guard/ledger limits, stale/unknown/failure/restart paths,
retention continuity, identity, API series/privileges and dense/sparse iOS flows.
Docker acceptance uses the actual pinned receiver, self-signed test server and
vehicle CAs, real protobufs, durable storage and an authenticated Bun HTTP response
containing streamed dense series. Tests never call Tesla.

```sh
cd ingestion && go test -count=1 -race ./... && go vet ./...
go vet -tags acceptance ./acceptance
cd ../server && bun install --frozen-lockfile && bun run typecheck && bun run test:local
cd .. && ./scripts/ios-build.sh
bash deploy/telemetry/funnel/test-funnel.sh
bash deploy/telemetry/cert/test-renew.sh
bash deploy/telemetry/ops/test-check.sh
bash deploy/telemetry/test/run-acceptance.sh .
```

Acceptance is synthetic. Live gates: Tesla config adoption, public reachability,
real field density/units, billing agreement/month/credit semantics, physical-car
PackCurrent sign, TeslaMate segmentation under reduced polling and physical iPhone
runtime. Module-temperature units are inferred and require live confirmation;
Tesla documents longitudinal/lateral acceleration in m/s². DELETE depends on
working Tesla OAuth/network; config expiry is a fallback, not a hard spend guarantee
during an outage. Tesla's portal limit remains the final external safety boundary.

The prior PRs' GitHub jobs failed before running any steps: the annotation reports
failed account payments or an Actions spending limit. Resolve that account gate;
local tests do not substitute for required green CI.

### Recording telemetry-only trips through TeslaMate

Commander can now feed fresh recorded telemetry back into TeslaMate's private
Tesla API facade, so a drive need not already exist in `public.drives` for its
positions to be recorded. This is optional and off by default:
`COMMANDER_TELEMETRY_READS=true`, a narrowly granted read-only database DSN, and
`deploy/commander/compose.telemetry-reads.yaml`. See
[commander's enabling, identity, freshness and unit contract](../commander/README.md#telemetry-backed-teslamate-reads-optional-default-off).
The hot path reads indexed `latest_samples`, connectivity and stream health in
one database snapshot; it never scans trip history or calls Tesla. It overlays a
successful real response template, keeps exact VIN-digest ownership, and spends
no polling budget. A newest valid observation and receiver/consumer liveness must
be within 90 seconds, with zero recorded queue lag. Change-only fields are carried
only inside their proven continuous link; invalid/latest conflicting fields are
unknown. Stale/disconnected streams and cold-start templates retain normal paced
polling. No receiver, profile, ingest or deployed service is changed by enabling
code in this repository; the operator still controls setup and live acceptance.
