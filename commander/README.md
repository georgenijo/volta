# Volta commander — Phase 2 groundwork

A private, single-account Go service in front of Tesla's official
`tesla-http-proxy`. Phase 1 continues returning `501 commands_unavailable`.
The service defaults to **stub mode, commands disabled**. No developer app,
Tesla credentials, partner registration, virtual key, or deployment is assumed.

## Architecture and upstream decision (checked 2026-10-07)

Use the official HTTP proxy as a private sidecar, with a standard-library-only
Go wrapper. The wrapper owns OAuth, encrypted token storage, the Volta contract,
validation, rate limits, idempotency and audit receipts. The proxy owns the
P-256 signing key, protocol/session negotiation and command transport. Keeping
the signing key out of the wrapper reduces its credential footprint; keeping
Tesla's protocol in the official implementation avoids recreating signing and
replay rules. The thin wrapper has no Go module dependencies.

- [Official SDK/proxy](https://github.com/teslamotors/vehicle-command): latest
  published release inspected was **v0.4.1**, published 2026-02-04, commit
  `49977a18fd68567501d59e16a6c9e4a8b9348544`. Main was
  `a4b43c1eff0e09d77deb9f2dce97031141fe8c8a` (2026-09-25). The Docker target
  builds **v0.4.1** through Go's checksum-verified module download, not `latest`.
- [Third-party tokens](https://developer.tesla.com/docs/fleet-api/authentication/third-party-tokens):
  authorization URL is `https://auth.tesla.com/oauth2/v3/authorize`; server-side
  token exchange/refresh uses
  `https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token`.
- [Signed commands](https://developer.tesla.com/docs/fleet-api/endpoints/vehicle-commands)
  require a paired virtual key on applicable vehicles. The proxy expects a
  **17-character VIN**, not TeslaMate's integer ID.
- [Region discovery](https://developer.tesla.com/docs/fleet-api/endpoints/user-endpoints)
  uses `GET /api/1/users/region`; only the documented
  [NA and EU bases](https://developer.tesla.com/docs/fleet-api/getting-started/regions-countries)
  are accepted in live mode. China requires separate onboarding and is outside
  this private US-account groundwork. Proxy routing itself uses the issued
  token's audience/region, as implemented by the upstream account package;
  commander uses the discovered base for wake and state checks.

### PKCE verification boundary

The implementation sends `code_challenge_method=S256`, a SHA-256 challenge of a
256-bit verifier, and the verifier on code exchange. State is random, one-use,
valid for ten minutes, bound to the paired Volta device that started it, and
persisted only as a SHA-256 hash inside the encrypted store (the verifier is
encrypted too), so an app return after a commander restart still completes.
Wrong-state, expired or other-device completions never contact the token
endpoint; a repeated completion replays the stored outcome. A failure after the
link was consumed is stored as terminal `oauth_link_failed` (start again), so a
retry never resends a possibly spent code. The current
Fleet third-party documentation does **not explicitly document PKCE parameters**,
and public OIDC metadata did not advertise challenge methods when checked.
Tests prove our PKCE exchange against a verifier-checking stub; Tesla's actual
acceptance/enforcement must be verified after developer registration. There is
no downgrade to a non-PKCE flow. This is a live acceptance gate, not evidence of
Tesla login working.

## Run and verify without Tesla

Go 1.27.1 or later and Python 3 are sufficient. All tests use `httptest` and
synthetic IDs/tokens. The stub smoke script builds and starts only its own
loopback processes, checks login, a command, replay and restart persistence,
then removes its temporary state and stops its processes.

```sh
cd commander
go test -race -count=1 ./...
go vet ./...
python3 scripts/smoke-stub.py
```

The smoke script requires unused loopback ports 19090, 8090, 8091 and 8092. It uses
explicit fixture credentials (`STUB_ONLY`), not Tesla credentials. The standalone
`go run ./cmd/fakefleet` fixture emulates token exchange, discovery and command
responses; it does not sign or contact Tesla. Integration behavior is tested,
not vehicle execution or Tesla authentication.

## Security and persistence

- Internal listener defaults to `127.0.0.1:8090`. Every route, including health
  and login initiation, needs `Authorization: Bearer <internal shared secret>`.
  This secret is distinct from Volta device tokens and Tesla access tokens.
- Callback/key listener defaults to `127.0.0.1:8091` and contains only the
  stateless callback bounce at the `TESLA_REDIRECT_URI` path and the well-known
  public-key route. Never route a public ingress to port 8090. Production uses
  the equivalent Cloudflare Worker in `deploy/edge/` instead. See
  [INTEGRATION.md](INTEGRATION.md) and [Sign in with Tesla](../docs/TESLA_SIGN_IN.md).
- The optional read-only collector (`COMMANDER_COLLECTOR_ENABLED`) listens on
  `127.0.0.1:8092` by default and needs `COMMANDER_COLLECTOR_SECRET`.
- Fleet Telemetry control is separately staged by
  `COMMANDER_TELEMETRY_ENABLED`. It uses the signing proxy without enabling
  vehicle commands. The durable guard polls the private usage meter every 15
  seconds, installs the economy profile at `$20`, and deletes/latches the
  configuration at `$23`, the `$28` combined operating line, or whenever
  accounting is unknown. A separate `$2` reserve is usable only for bounded
  delete retries. See
  [cost and guard](../docs/TELEMETRY_COST.md).
- Tesla-billed charging history (`COMMANDER_CHARGING_HISTORY_ENABLED`, off by
  default) is an operator-triggered, one-page private read sharing the
  collector's budget ledger and lock. Its live contract is unverified; see
  [Tesla-billed charging history](../docs/CHARGING_HISTORY.md).
- Tokens and receipts are stored in `COMMANDER_DATA_DIR/state.enc`, authenticated
  with AES-256-GCM and a fresh nonce per write. `COMMANDER_ENCRYPTION_KEY` is
  **base64 of 32 random bytes**. AAD binds the format version. Atomic rename,
  file/directory fsync, a 0700 data directory and 0600 files protect persistence.
  Losing the encryption key requires reauthorization; do not delete receipt
  state to recover authorization. Back up the encrypted state and protect the
  encryption key separately. Host root/Docker administrators remain trusted.
- An exclusive OS file lock allows one instance per state directory. Deploy a
  single replica, never independent replicas for this account. On-demand
  automatic refresh runs when access expiry is less than the command deadline
  plus a one-minute margin (125 seconds by default),
  serialized across requests, saving the rotated refresh token before use.
  Requests fail closed if state cannot be saved. There is no background refresh:
  an account unused for Tesla's refresh-token lifetime needs a deliberate
  reconnect. This service never wakes or polls a car just to maintain login.
- Commands are serialized for this one-account service; queue wait is capped at
  two seconds (`command_in_progress`, retry the same key). A cancelled request
  is checked before reservation. Once reserved, a bounded send continues after
  client disconnect so its actual result is saved for same-key replay. A durable
  reservation is written before a send. Replays return the original result for 24 hours;
  changed bodies/routes conflict. Incomplete receipts after a crash return
  `command_outcome_unknown` and never resend. After 24 hours keys can be reused;
  use a new UUID for each new intent and never retry older intents.
  A definitive Tesla 429 clears the reservation, allowing same-key retry after
  `Retry-After`; it still consumes the local attempt budget. A definitive dial
  failure is saved as `upstream_unavailable`, not an ambiguous outcome; after
  repairing the service, make a new confirmed intent/key.
- Per-vehicle budget: **6 new commands per rolling minute**, persisted across
  restarts. Replays consume no budget. Wake/retry is one wake, up to 30 seconds
  of state polling at two-second intervals, then at most one command retry.
  Only explicit asleep rejections permit this path; generic failures do not.
  A logical command can therefore create two command sends plus a wake and
  state reads. Account for that when setting Tesla's billing cap.
- `audit.jsonl` and stdout contain timestamps, event, local vehicle ID,
  command name, a hash-derived request ID, and result code/status. Never tokens,
  OAuth codes/state/verifiers, VINs, parameters, or raw upstream responses.
  Denied command requests record status only. Protect/rotate `audit.jsonl`
  using the host's log policy; stdout has bounded Docker rotation. Encrypted
  receipts also survive restarts. No raw proxy verbose logging is enabled.
- Tesla URLs are fixed/allowlisted in live mode, stub URLs are loopback-only,
  redirects are refused, ambient outbound HTTP proxies are disabled, and the
  live proxy certificate is verified using a supplied trust certificate. Its
  destination is restricted to loopback or `tesla-command-proxy:4443` on the
  dedicated private Docker network.
  Never use `InsecureSkipVerify` or publish the raw proxy.

## Keys and deployment

```sh
# Generate outside Git. Refuses overwrites and any Git checkout destination.
./commander/scripts/generate-keys.sh /absolute/private/commander-secrets
```

This creates P-256 `fleet-key.pem`, its `public-key.pem` export, and a separate
`tls-key.pem`/`tls-cert.pem` for private proxy HTTPS (localhost and Docker service
DNS SANs). Private keys are unencrypted PEM
because the upstream proxy must load them unattended: restrict host/container
access; only the OAuth token store is encrypted with the env key. Never commit
or serve private keys. Copy **only** the public export to the public host at:

```text
https://<app-domain>/.well-known/appspecific/com.tesla.3p.public-key.pem
```

The service validates that its optional public PEM is P-256 `PUBLIC KEY` and
rejects private PEMs. The keygen script creates a one-year private proxy TLS cert;
renew that certificate before expiry without changing the vehicle signing key.
Changing the signing key requires updating Tesla registration and pairing again.

Deployment files live in `deploy/commander/`. They are a standalone fragment for
the ubuntu backend worker to integrate; nothing in `server/` or `deploy/ubuntu/`
is changed. Before a future authorized deployment:

1. Copy `.env.example` to a private `.env` (0600), generate distinct random
   internal and encryption keys, and keep commands disabled until prerequisites
   are complete. The example intentionally has blank secrets.
2. Prepare `/var/lib/volta/commander`, owned by UID/GID 65532, mode 0700. Prepare
   `/etc/volta/commander-public` with **only** `public-key.pem` and `tls-cert.pem`
   (0644, directory 0755). Prepare `/etc/volta/commander-secrets` containing
   `fleet-key.pem`, `tls-key.pem`, `tls-cert.pem`, owned by UID/GID 65532,
   directory 0700 and private files 0600. Commander mounts only the public dir;
   only the proxy mounts the signing/TLS keys.
3. Fill Tesla app configuration and mapped VIN, choose live mode, set
   `TESLA_PROXY_CA_FILE=/public/tls-cert.pem`,
   `TESLA_PUBLIC_KEY_FILE=/public/public-key.pem`. For account setup, set
   `COMMANDER_OAUTH_ENABLED=true` and keep `COMMANDER_COMMANDS_ENABLED=false`.
   Enabling commands also enables OAuth. Only enable commands after George
   authorizes controls and completes registration, login and virtual-key pairing.
4. From the repo root, build/start using the live profile **only when authorized**:

   ```sh
   docker compose --env-file deploy/commander/.env \
     -f deploy/commander/compose.yaml --profile live up -d --build
   ```

The proxy and commander have independent network namespaces and share only the
dedicated `internal: true` signing network; Docker service DNS preserves routing
across restarts/recreation. The proxy has its own outbound network for Tesla,
is absent from volta-api's network, and publishes no host ports. The Docker host
administrator is trusted. A per-Dockerfile source allowlist excludes keys,
`.env`, runtime data and unrelated repo files from the build context/cache.
Only ports 8090/8091 are published, both to host loopback. For a containerized
volta-api, attach it to the `volta-commander` network and use commander:8090 with
the shared secret. A host volta-api can use 127.0.0.1:8090. Cross-host operation
needs a tailnet HTTPS transport and ACL restricted to volta-api, still with the
shared secret; the provided fragment assumes same-host operation. See
[INTEGRATION.md](INTEGRATION.md) for the backend contract and owner prerequisites.

There is no installed Docker runtime on the implementation MacBook, so image
execution is a separate check from local Go tests and Linux cross-compilation.

## Telemetry-backed TeslaMate reads (optional, default off)

`COMMANDER_TELEMETRY_READS=true` lets the private collector answer vehicle
summary and `vehicle_data` reads from recorded Fleet Telemetry, before its cache
TTL and monthly pacing checks. These replies make **no Fleet API request**, do
not reserve or spend polling budget, and never wake a vehicle. This switch is
independent of `COMMANDER_TELEMETRY_ENABLED` (configuration/budget control).
Products discovery and every fallback retain the existing budget policy.

Enable only after telemetry migrations 001/002 and the consumer's identity
binding have been applied. As the local database owner, apply
`deploy/commander/telemetry-reader.sql`, then set that role's password out of band
with `\password volta_commander_reader`. The role can select only car identity
columns and the required telemetry tables/views; it cannot read raw records or
write either schema. It uses a two-connection pool, read-only transactions and a
one-second query deadline. Put its private DSN in the untracked
`deploy/commander/.env` as `COMMANDER_TELEMETRY_DATABASE_URL`; never use the ingest
role or the TeslaMate owner. Add `deploy/commander/compose.telemetry-reads.yaml`
to the chosen commander Compose files and set `TESLAMATE_NETWORK` to the existing
private database network. No new published port or public ingress is needed.

A successful real, complete `vehicle_data` response is required once per vehicle
and commander process as the parser template. It remains available across later
408 replies, but is cleared on account replacement/disconnection. Cold starts,
missing templates, DB failures, bad identities and stale telemetry follow the
original paced behavior. This may delay bootstrap until an ordinary paid polling
slot becomes available; the feature does not bypass that budget.

Fresh means a **valid source observation within 90 seconds**, receiver liveness
and consumer catch-up within 90 seconds, zero recorded queue lag, and a latest
`CONNECTED` event handed off after the running receiver generation started.
Future timestamps are refused. Every carried field must belong to the same
continuous connection, after the newest recorded disconnect/silence gap.
[Telemetry emits only when values change](https://developer.tesla.com/docs/fleet-api/fleet-telemetry),
so an unchanged gear/location can be older than 90 seconds while still current.
A silent stream exceeding 90 seconds falls back even if its socket is connected.
Invalid/conflicting/malformed latest values are omitted; supported dynamic fields
without valid telemetry become JSON null rather than refreshing cached readings.
The `invalid_fields` history pivot is not used: the indexed `latest_samples`
lookup exposes each field's own `invalid` and `quality`, including conflicts.

Identity is exact: the requested Tesla numeric ID or VIN must match the successful
Fleet response; that VIN must resolve to exactly one TeslaMate car with matching
`vehicle_bindings` and `api_vehicle_bindings` SHA-256 digests. No ID guessing or
numeric TeslaMate-ID/Tesla-ID interchange occurs. IDs remain lossless JSON numbers.
Binding, health, connectivity and latest fields are read in one SQL snapshot.

| Response | Telemetry fields and units |
| --- | --- |
| `drive_state` | Location → latitude/longitude (degrees), GpsHeading → integer heading, VehicleSpeed → integer mph, Gear → D/R/N/P, PackVoltage × PackCurrent → integer kW only with same payload/time and operator-verified sign |
| `charge_state` | BatteryLevel → battery_level, Soc → usable_battery_level (integer percent); RatedRange/IdealBatteryRange/EstBatteryRange → miles; DetailedChargeState → Disconnected/NoPower/Starting/Charging/Complete/Stopped; AC/DCChargingPower → integer charger_power kW; DCChargingEnergyIn → charge_energy_added kWh; ChargeLimitSoc → integer percent; TimeToFullCharge → hours; ChargerVoltage/ChargeAmps → integer volts/amps; FastChargerPresent/ChargePortDoorOpen → booleans |
| `climate_state` | InsideTemp/OutsideTemp → degrees Celsius |
| `vehicle_state` | Odometer → miles; Locked/SentryMode → booleans; TpmsPressureFl/Fr/Rl/Rr → bar; Version → car_version |

`source_unit` is checked: native mi/mph remain unchanged; km and km/h convert by
1.609344, Fahrenheit converts to Celsius, and minutes convert to hours. Unknown
units and nonfinite numbers are refused. DCChargingEnergyIn is the documented
battery-side session counter for both AC and DC; ACChargingEnergyIn measures
charger input and is not substituted or added. Charger power is the larger valid
AC/DC observation, never their sum. EnergyRemaining has no equivalent vehicle_data
field and is not invented. All four overlaid section timestamps use the newest
valid telemetry source time in milliseconds; `gps_as_of` retains the location's
source seconds. Static template identity/configuration remains intact. Unsupported dynamic flags
(user presence, climate operation, battery heaters, warnings, etc.) become null.
Locked/SentryMode and TPMS pressures are populated from valid telemetry; Version
updates car_version. An active software-update template or a template without
known closed doors/trunks falls back to normal polling because those states
cannot safely be inferred from the configured telemetry fields. Known closed
closure values and the empty software-update parser sentinel remain scaffolding.
Active charge counters/powers must have source times at or after the latest
Starting/Charging transition, so values from an earlier session cannot inflate
the next session. Closing counters also require the indexed derived charge session
to cover that state transition, keeping the final current-session counter without
resurrecting an older session when no new counter arrived. Summary replies require the same usable overlay as data reads.

The implementation was checked against TeslaMate commit
[`6af9a0ff9ec8a6cec2833ae0fde66a929469a15b`](https://github.com/teslamate-org/teslamate/tree/6af9a0ff9ec8a6cec2833ae0fde66a929469a15b):
`elixir/lib/tesla_api/vehicle/state.ex` and
`elixir/lib/teslamate/vehicles/vehicle.ex`. Its poll state machine starts a drive
on D/R/N, ends it on P/null, starts charging on Starting/Charging, reads millisecond
timestamps and converts mph/miles for storage. Vehicle-data overlays require
known gear, known detailed charge state and valid location; missing core data
falls back instead of inventing a session transition. Real-car acceptance and
compatibility with an operator's installed TeslaMate version remain deployment
gates; unit/SQL tests do not establish those.
