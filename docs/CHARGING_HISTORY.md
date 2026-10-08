# Tesla-billed charging history (operator preview)

Status: **implemented, off by default, live contract unverified.** Nothing in
this feature has been called against Tesla. With the default configuration
commander answers `501 history_unavailable`, requests no extra scope, and
makes no Tesla call; the paired app sees `available`/`enabled` flags and empty
lists.

## What it is

Tesla's Fleet API exposes the charging sessions **Tesla billed** to the
account: `GET /api/1/dx/charging/history`
([Charging endpoints](https://developer.tesla.com/docs/fleet-api/endpoints/charging),
operation `get-user-paginated-history`). Each session carries a site name,
start/stop/unlatch times, country, billing type, fee lines with amounts, and
invoice references.

It is **not** TeslaMate's charge log and the two are never merged:

- Coverage is whatever Tesla bills. Supercharger sessions are expected; whether
  other Tesla-billed charging appears has not been confirmed, so nothing assumes
  Supercharger-only.
- There is no state of charge, no coordinates and no battery energy. Energy is
  shown only as **billed kWh** (the single `CHARGING` fee's `usageBase`, kWh
  unit, no tier usage); when tiers or several charging fees appear it is null.
  Billed energy is not energy added to the battery.
- Amounts are kept as exact decimal strings in storage. Session `totalDue` and
  `netDue` are the sum of per-fee values only when every fee has the same
  non-null currency and carries that amount; otherwise null. Fee subtotals
  (`totalBase`, tiers) are never added to the totals, so nothing is
  double-counted. A null currency stays null.
- Invoice PDFs are never downloaded. Invoice `contentId`, file names and raw
  fee amounts stay in the private `volta` schema and are never logged.

## Scope and prerequisites (none are done)

Tesla has no history-only scope. History needs `vehicle_charging_cmds`, the
same scope that authorizes charging commands. This feature asks for it
**without** `vehicle_cmds` and without enabling Volta's command path:

| Setting | Requested scopes |
|---|---|
| default | `openid offline_access vehicle_device_data vehicle_location` |
| `COMMANDER_CHARGING_HISTORY_ENABLED=true` | default + `vehicle_charging_cmds` |
| `COMMANDER_COMMANDS_ENABLED=true` (separate feature) | default + `vehicle_cmds vehicle_charging_cmds` |

Commander has no route that sends a charging command when commands are
disabled, but the issued token *could* authorize one. Granting the scope is
George's decision. To activate after that decision:

1. Add `vehicle_charging_cmds` to the app's allowed scopes on
   [developer.tesla.com](https://developer.tesla.com/).
2. Set `COMMANDER_CHARGING_HISTORY_ENABLED=true` in commander's environment
   (`deploy/commander/compose.signin.yaml` does not set it, so it stays off;
   requires `COMMANDER_OAUTH_ENABLED=true`). Keep `COMMANDER_COMMANDS_ENABLED=false`.
3. Disconnect and sign in again from the app, approving the charging
   permission on Tesla's consent screen. Until the token has the scope,
   commander answers `403 history_scope_missing` without spending budget again.
4. Apply `deploy/history-schema.sql` (see [deploy/README.md](../deploy/README.md)).

## Cost and limits

History calls go through the same encrypted ledger as the TeslaMate collector
and count against the same `COMMANDER_MONTHLY_BUDGET_USD` (the live $10 is
unchanged). Each call is reserved durably before it is sent at 1/500 USD.
On top of the budget: **12 calls per UTC day, 60 per month, at least one second
apart, one in flight**. A Tesla 429 blocks further calls until its
`Retry-After` (delay-seconds counted from when the response arrived, or an
absolute HTTP-date), honoured in full and persisted in the ledger as a UTC
deadline, so it survives restarts and is never shortened. The floor is one
minute; a missing or malformed value waits an hour; a deadline past year 9999,
which the ledger cannot store, saturates there. 401/403 and payment errors stop
without retries.

Each call's reservation also writes a pending marker, cleared in the same
write that records the reply's outcome (backoff, scope refusal or nothing).
If that write fails, commander keeps the outcome in memory, writes it before
anything else and refuses every history call (`503 storage_unavailable`)
until it succeeds. If commander stops before the outcome is written (a crash
mid-call, or a failed write followed by a restart), the marker left behind
means the reply's `Retry-After` is unknown, and no amount of elapsed time
proves that deadline has passed. History is then **held indefinitely**:
every history call answers `503 history_outcome_unknown` with no
`Retry-After`, and nothing clears the hold by itself. A new day or month, a
restart, a disconnect or a new sign-in all leave it in place. The TeslaMate
collector is not affected. A backoff that *was* recorded keeps its exact
deadline across restarts, however long it is. Sixty calls are $0.12 a month,
which slightly shortens the collector's paced interval while the budget is
shared.

### Releasing a held history (operator decision)

Commander has no command or endpoint that clears the hold; ending it is a
deliberate operator decision, and no automatic expiry, re-authorization cycle
or monthly reset does it. If it happens:

1. Confirm the hold: history calls answer `503 history_outcome_unknown`.
2. Wait until Tesla's longest plausible `Retry-After` for that call has
   certainly passed. Commander did not record it, and making another call to
   learn it would be the paid call the hold exists to prevent.
3. Clearing the marker means editing commander's encrypted ledger
   (`History.Pending` in the state file) with commander stopped, under the
   same protection as any other change to its secrets. No tool for this ships
   in this change; treat it as an incident and agree the exact operation
   before running it.

History calls take the collector's existing lock, so a history read and a
TeslaMate read never overlap. The collector's own caching and pacing are
unchanged, including the known baseline where a cached reply is served again
inside its TTL; that is a separate follow-up and not affected here.

## Account namespace and vehicle matching

Commander gives each sign-in an opaque 64-hex namespace (a hash of a random
per-link ID, never of tokens or Tesla IDs). Rows are stored under that key.
Disconnecting or linking another account changes it, so earlier rows stay
stored but hidden. A reply whose namespace changed while it was in flight is
discarded, and a sync stops when the namespace changes between pages. Device
reads ask commander for the current namespace before their queries and again
after them; if it changed (disconnect or relink mid-read, or commander fails
the second check), the rows are dropped and the API answers `409
tesla_link_changed` (or the commander error) instead. List cursors carry a
one-way digest of the issuing namespace and vehicle; a cursor from an earlier
link is refused with `409 tesla_link_changed` before any query, so its position
is never applied to another account's rows.

Sessions attach to a TeslaMate car only by **exact full-VIN equality**, never
by the six-character suffix. Sessions with a missing, malformed or unknown VIN
stay stored and are counted as `unmatched` in the summary; they are never
attributed to a car. Paired devices never receive a VIN.

## Running it

Use the CLI on the API host, where `COMMANDER_URL`, `COMMANDER_INTERNAL_SECRET`
and `AUTH_DATABASE_URL` are set. Times are UTC seconds (`2026-01-01T00:00:00Z`).

### 1. Probe the page base (two calls, nothing stored)

Tesla documents `pageNo` but not whether it starts at 0 or 1. Run the same
window twice:

```bash
bun run cli history-probe --since 2026-01-01T00:00:00Z --page 0 --page-size 10
bun run cli history-probe --since 2026-01-01T00:00:00Z --page 1 --page-size 10
```

Each prints counts only: `received`, `rejected`, `totalResults` and where it
was found (`totalResultsLocation`: `top` level, inside `response`, `both`
when equal, `conflict` when they differ, or `none`; the docs example is
ambiguous), `withVin`, the earliest and latest start, and `pageDigest` (a hash
of that page's session IDs).

- Page 0 empty and page 1 non-empty, or both with the **same** digest: pages
  are 1-based; use `--first-page 1`.
- Both non-empty with **different** digests: pages are 0-based; use
  `--first-page 0`.
- Both empty: widen the window. Anything else: stop and inspect.

### 2. Plan, then apply a bounded sync

```bash
# Prints the plan; makes no Tesla call.
bun run cli history-sync --since 2026-01-01T00:00:00Z --first-page 1
# At most --max-pages calls (default 5, max 20), page size default 50.
bun run cli history-sync --since 2026-01-01T00:00:00Z --first-page 1 --max-pages 5 --apply
```

`--first-page` is required for a new run and only there; it is settled once
by the probe. Pages are fetched oldest first, one second apart. Rows are keyed
by `(namespace, sessionId)`, so a rerun updates only rows whose content
changed.

An applied run prints its resume token on stderr **before its first Tesla
call**, and stores the run's own row (outcome `in_progress`, only the
token's SHA-256) before calling; if the token cannot be printed, nothing is
called or stored. Each kept page is then one checkpoint transaction, taken
under the run's claim and row lock: the page's sessions, the run's counts,
the chain's evidence (pages, counts, `totalResults`, seen session IDs) and
the next page. A page that ends the chain also drops the token in that same
transaction, so a page whose rows were kept is never requested again through
any token. If a later step fails (the next call, an unexpected error or the
run's closing record), the row stays `in_progress` at the first page not yet
kept and the printed token continues from there.

The run stops before writing a suspect page and reports why (`outcome`):

| Outcome | Meaning | Window complete | Resumable |
|---|---|---|---|
| `total_reached` | kept + rejected rows reached `totalResults` | yes, if nothing was rejected | no |
| `rows_rejected` | `totalResults` reached, but some rows failed validation | no | no |
| `total_mismatch` | an empty page arrived before `totalResults` was reached | no | no |
| `total_exceeded` | more rows than `totalResults` | no | no |
| `total_conflict` | Tesla's top-level and `response` totals differed; that page is not written | no | no |
| `end_unverified` | an empty page followed earlier pages, but Tesla gave no total | no | no |
| `empty_first_page` | first page empty (possibly the wrong page base) | no | no |
| `end_unconfirmed` | short page; the next call would confirm the end | no | yes |
| `max_pages` | page cap reached | no | yes |
| commander code (`history_daily_limit`, `tesla_rate_limited`, …) | refused; the same page is retried | no | yes |
| `repeated_page` | a page repeated a session already seen in this chain | no | no |
| `total_changed` | `totalResults` changed between pages or runs | no | no |
| `account_changed` | the link changed between pages or before a resume | no | no |
| `page_limit` | page 200, commander's bound, was written and the chain would need page 201 | no | no |
| `in_progress` | the run is running, or stopped before recording why; its kept pages are recorded | no | yes, from `next_page` |

"Complete" (outcome `total_reached` only) needs Tesla's own `totalResults`,
stable across the chain, never contradicted by a conflicting total, and
matched exactly by kept rows with none rejected. An empty page alone, a
missing or conflicting total, or any rejected row leaves it `false`; counts
are still recorded. A conflict ends the chain: rows stored from its earlier
pages stay, but their coverage of the window is unknown, so a later fresh run
is needed to prove it. It covers only this window and never asserts the
account's whole history. Applied runs are recorded in
`volta.tesla_history_syncs` (counts and session IDs only).

### 3. Resume a stopped run

A resumable run prints `nextPage` and its one-time `resume` token (the same
token printed at its start). Continue it without re-reading pages already
kept:

```bash
bun run cli history-sync --resume <token>                # plan; no call, no claim
bun run cli history-sync --resume <token> --max-pages 5 --apply
```

The window, page size, page base, next page and pagination evidence (counts,
`totalResults` and every session ID already seen, so repeats across runs are
caught) come from storage; `--resume` refuses `--since`, `--until`,
`--first-page` and `--page-size`. Only the token's SHA-256 is stored. A token:

- works once; an applied resume retires it when it starts, in the same
  transaction that stores the new run's row, and prints that run's new token
  before its first call;
- is held by one run at a time. Claiming it writes a random owner generation
  and a 30-minute lease, renewed before every Tesla call. Each page write,
  the run's final record and the token's retirement check that owner and
  lease inside their transaction, under a row lock. A crashed run's claim
  lapses after the lease; if another run then takes over, the earlier run
  can no longer write, release the claim, retire the token or record a
  result, and stops before any further call;
- is bound to the link it was issued under: after a disconnect or relink it
  is retired with `account_changed` before any Tesla call.

Each resumed run still spends from the same daily, monthly and budget caps,
so a long window finishes over several days without repeating paid calls.

This is not exactly-once. A page is kept only when its checkpoint commits, so
a page whose reply arrived but whose checkpoint did not commit (a crash, a
lost database connection, a lapsed lease) is requested again by the next
run. The same holds when a run stops on an anomaly (`repeated_page`,
`total_changed`, `total_conflict`, `account_changed` between pages) and its
closing record then fails: the row stays `in_progress` at the suspect page,
which a resume requests again before stopping on it. Refused calls
(commander codes) keep `next_page` on the refused page.

## App surface

`GET /v1/tesla/charging-history` returns the summary and
`GET /v1/vehicles/{id}/tesla-charging-sessions` lists one car's matched
sessions; see [API.md](API.md). Native presentation is a follow-up.

## Not verified yet

- Live response shape, page base, `totalResults` location, VIN presence and
  coverage beyond Supercharging.
- Tier semantics: the docs example shows `usageBase` 40 and `usageTier2` 24
  with `totalBase` 18.4 (= 0.46 × 40), which is why tiered energy stays null.
- Whether the token with `vehicle_charging_cmds` but not `vehicle_cmds` is
  accepted for this read.

Primary sources: [Charging endpoints](https://developer.tesla.com/docs/fleet-api/endpoints/charging),
[Authorization scopes](https://developer.tesla.com/docs/fleet-api/authentication/overview#scopes),
[Billing and limits](https://developer.tesla.com/docs/fleet-api/billing-and-limits).
