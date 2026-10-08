# volta-api

Private, metric-only TeslaMate v4.3.0 API: Bun 1.4.1, Hono, strict TypeScript,
postgres.js. The contract is [docs/API.md](../docs/API.md); deployment is
[deploy/README.md](../deploy/README.md). No Tesla credentials or vehicle command
integration. Only `server/` and `deploy/` are owned here.

## Develop and test (macOS, no Docker)

```sh
brew install postgresql@17
cd server
bun install --frozen-lockfile
bun run typecheck
bun run test:local
```

`test:local` creates a fresh temporary PG17 cluster, binds only to loopback,
restores `test/teslamate-v4.3.0.sql`, runs the production grants/bootstrap without
interactive password prompts, seeds synthetic fixture data, and runs `bun test`.
It always stops/removes its own cluster; it does not install a launch service or
use an existing database. `PG_BIN=/path/to/postgresql17/bin` supports another
local PG17 installation. Python 3 is used to pick an available port. Trust auth
is only for this temporary localhost fixture cluster. Never use the test harness
against an existing TeslaMate database.

`bun test` directly requires `TEST_DATABASE_URL` pointing to localhost database
`volta_test` (fixture administrator), `TESLAMATE_DATABASE_URL` (volta_reader),
and `AUTH_DATABASE_URL` (volta_auth), with the snapshot and bootstrap already
restored. The tests truncate the fixture tables.

To run locally with your own separate synthetic database, put the two runtime
URLs in ignored `server/.env`, optionally `HOST=127.0.0.1`, `PORT=8080`,
`CURRENCY=USD`, then:

```sh
bun run start
bun run cli pair
bun run cli devices
bun run cli revoke 1
```

Pairing prints an 8-character code valid for ten minutes and consumed atomically
once. Successful pairing returns a random 256-bit device token. Only SHA-256
hashes are stored for both tokens and pairing codes. Authentication looks up the
hash and compares two fixed-length digests using `timingSafeEqual`. Revocation is
checked on every request. Pairing attempts are globally limited to 30 per ten
minutes in Postgres, including malformed bodies/names; an operator can wait out
or clear `volta.rate_limits` if the limit is exhausted. Client IP/identity headers
are never trusted. The CLI uses only the auth-role URL and never prints tokens.

## Schema source and reproducibility

The test schema is a **full schema-only pg_dump**, generated after executing all
unmodified upstream Ecto migrations from:

- [TeslaMate v4.3.0](https://github.com/teslamate-org/teslamate/tree/v4.3.0)
- Commit `33d200b2fba9d5138803916a788cef5eae31b1aa`
- [`elixir/priv/repo/migrations`](https://github.com/teslamate-org/teslamate/tree/33d200b2fba9d5138803916a788cef5eae31b1aa/elixir/priv/repo/migrations)
- [`grafana/dashboards/battery-health.json`](https://github.com/teslamate-org/teslamate/blob/33d200b2fba9d5138803916a788cef5eae31b1aa/grafana/dashboards/battery-health.json)

Upstream license and notice are retained in `test/upstream/`. The dump is a
generated representation of the migrations, not original TeslaMate source.
It includes real enums, numeric precision, UTC timestamps without timezone,
constraints, indexes, extensions, and `private.tokens`; it contains no data.
Regenerate when intentionally upgrading TeslaMate:

```sh
brew install postgresql@17 elixir
bun run schema:refresh
```

`schema:refresh` clones the pinned release, runs its migrations with a minimal
Ecto repository plus the real Vault/CarSettings modules (empty database, no Tesla
login), and dumps the schema. Hex/Mix dependencies are local build tools only;
Elixir is not needed to run the API or regular tests. The fixture snapshot is
upstream-generated DDL, not an application migration or production bootstrap.

## Derivations and recording limits

- **Metric / UTC:** km, km/h, °C, kW, kWh, metres. TeslaMate naive timestamps are
  UTC; DB connections set timezone UTC. Summary windows default to UTC and accept
  an optional IANA `tz` for local midnight/calendar-day arithmetic; responses
  include their exact UTC bounds and resolved zone. Mileage buckets use UTC.
  Summary boundaries use native Temporal in the pinned Bun >=1.4 runtime
  ([Bun 1.4 release](https://bun.sh/blog/bun-v1.4)), sharing IANA data with Intl
  validation rather than relying on the database's zone catalog/abbreviations.
  Currency is configuration (`CURRENCY`), not stored in
  TeslaMate; costs are already TeslaMate-calculated amounts. Missing currency is
  null. Per-minute geofence billing is not exposed as cost per kWh.
- **Status:** latest point/state, with range/temperature/climate from the latest
  full polled position (the existing partial index). Point lookups use two bounded windows: the recent24 hours and the15 minutes
  following the indexed last poll (which retains parked/offline snapshots).
  Sparse streamed positions do not clear richer fields or force an unbounded
  history scan. If full polling stopped and older streams extend beyond that
  window, snapshot fields are conservative last-known polling values; verify
  logger collection/freshness rather than inferring a live vehicle state.
  Health uses the same indexed polling anchor and latest charge/state sources.
  Open updates/drives/charging
  processes determining activity. Charging samples can update SOC/rated range.
  There is no live Tesla request. A stale open session may remain visible after
  logger interruption. Because end time is genuinely unknown, it also extends
  timeline activity to now and can suppress later idle gaps; check TeslaMate
  collection before treating those intervals as completed history. `updatedAt` and health's `lastDataAt` expose recording
  freshness; DB reachability alone does not prove the Tesla login works.
  TeslaMate does not persist lock, sentry, heading, charge limit, minutes to full,
  or the exact charging-state string: these are null. `chargingState=charging`
  means an open recorded charging process. A vehicle without any SOC observation
  receives 409 `data_unavailable`, preserving Swift's nonoptional batteryLevel.
  `/v1/vehicles` reports this ahead of time as `hasData: false`.
- **Drives:** energy is rated-range loss × modal rated efficiency derived from
  eligible charging processes, falling back to `cars.efficiency` (kWh/km).
  Open-drive range loss uses first/last full polling samples (`ideal_battery_range_km
  IS NOT NULL`), matching TeslaMate close_drive; intervening streamed samples
  lack ranges and must not clear the estimate. Average speed is distance / duration. Elevation gain uses `drives.ascent`.
  Open drives use their first/latest recorded positions because TeslaMate only
  fills linked endpoints when closing the drive. Until any odometer measurement
  exists, the drive is omitted from lists and summary/mileage calculations; its
  detail returns 409. This keeps older measurable history accessible and does
  not invent a distance. Aggregate energy and cost are null if any included record lacks that
  measurement; incomplete records are not silently omitted from totals.
- **Idles:** only completed gaps *between* activity islands; no invented interval
  before first or after last activity. Nested/overlapping drives/charges merge.
  Gap duration must strictly exceed minMinutes. Stable id is twice the last
  island-ending drive id, or twice its charging process id plus one. SOC/range
  boundaries use the linked drive endpoint positions or first/last charging
  samples, within15 minutes of the activity boundary. Open-drive idle endings use the
  first recorded position even before TeslaMate links the endpoint. These are direct keyed
  reads, not a scan of all historical positions for every gap.
  Losses are nonnegative differences; absent boundaries are null. Asleep time is
  clipped state-interval overlap; it is null if logger states do not cover the
  entire gap, and zero for a fully recorded awake gap. Climate time is estimated by carrying a logged
  boolean forward at most five minutes per position (no extrapolation over long
  logging gaps). Unknown sentry time is null. Unknown asleep coverage is null. Climate duration is an estimate from
  observed intervals; recorded off samples yield an estimated zero, while no
  recorded climate boolean yields null. Average idle drain is observed nonnegative SOC loss divided by
  observed idle duration, normalized to 24 hours.
- **Battery:** dashboard-style rated efficiency is the mode of charge kWh /
  rated-range gain, rounded to 0.001 kWh/km, for >10-minute charges ending at ≤95%
  SOC, falling back to car efficiency. Capacity samples require a completed
  charge with ≥100 × rated efficiency kWh added and positive usable SOC.
  `capacityNewKwh` is the maximum eligible final-sample capacity since logging
  began (an estimate, not a manufacturer's specification).
  `capacityNowKwh` averages the latest 100 eligible samples, matching v4.3.0's
  actual dashboard query. Health is current/max ×100, capped at100%. Current
  rated100 range uses the latest position/charge with positive usable SOC;
  history uses daily sum(range)/sum(usable SOC) ×100. Missing capacity stays
  null, including when no adequate charge exists; no dashboard 1kWh placeholder.
- **Pagination:** descending `(start_date,id)` keyset cursors retain PostgreSQL
  microseconds, scope to vehicle/list/date/minMinutes filters, and are opaque to
  callers. `from` inclusive, `to` exclusive, both ISO UTC. Limits1–100 (default50).
  `hours`1–744, `minMinutes`1–10080. Drive paths/charge samples are chronological;
  histories and battery history are newest first.

## Security and operations

Use two dedicated runtime connections: `volta_reader` inherits the explicit
SELECT-only allowlist from `volta_readonly`; `volta_auth` gets DML only inside
`volta`, with no TeslaMate/private-token access. The administrator owns the DDL;
the API cannot migrate either schema. SQL values are parameterized. No secrets
are tracked. Request logs contain method, route template, status and duration;
no raw path, headers, query, body, codes, tokens, SQL or database error detail.
A scale regression seeds 2,500 drives, 1.5 million drive positions plus 222,500 parked positions and 7,500 state
transitions, 1,000 charging processes and 100,000 charge samples using the real upstream indexes. Drive pages
limit before joining, completed drive endpoints use primary keys, efficiency is
materialized per car, and climate overlap uses one bounded sweep per visible
page. No indexes or DDL are added to TeslaMate.

Bodies are capped at 4096 bytes; SQL has a 15-second statement timeout. Health
is public but contains only reachability and last recording time. Apply tailnet
ACLs to George's device; pairing tokens still authorize all recorded vehicles.
