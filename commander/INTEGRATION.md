# volta-api → commander integration

This worker owns only `commander/` and `deploy/commander/`. The backend worker
should keep Phase 1's `501 commands_unavailable` until George completes setup
and explicitly enables Phase 2. Do not reuse or read TeslaMate credentials.

## Backend contract

Same-host URL: `http://127.0.0.1:8090`, or `http://commander:8090` on the private
`volta-commander` Docker network. The API's tailnet HTTPS URL and Volta device
authentication remain the only iOS-facing entry point.

```http
POST /v1/vehicles/1/commands/set_temps
Authorization: Bearer <COMMANDER_INTERNAL_SECRET>
Idempotency-Key: <UUID generated for this user intent>
Content-Type: application/json

{"driverTempC":20,"passengerTempC":21}
```

```json
{"ok":true,"command":"set_temps","requestId":"hash-derived-id"}
```

Errors preserve the existing API shape, with optional `command` and `requestId`:

```json
{"error":{"code":"virtual_key_missing","message":"Pair Volta's virtual key in the Tesla app."},"command":"set_temps","requestId":"hash-derived-id"}
```

Backend responsibilities:

1. Authenticate the Volta device, enforce its vehicle access, and reject
   unsupported command names/parameters before forwarding. Keep commander auth
   exclusively on the server. Never send Tesla tokens or the shared secret to
   the phone.
2. Forward the unchanged Volta vehicle ID. Configure
   `COMMANDER_VEHICLES={"1":"<full VIN>"}` on commander; the mapping is
   explicit and independent of TeslaMate's ID and Fleet's numeric ID. Do not
   derive a full VIN from `vinSuffix`, and do not return it to the phone.
3. iOS generates/persists one UUID for each **confirmed user intent**, stable
   across network retries. volta-api requires and forwards that UUID unchanged
   in `Idempotency-Key`; never generate a replacement key on a retry or silently
   fill a missing header. Keys are 16–128 characters
   from `[A-Za-z0-9_-]`. The same key with different vehicle/command/params yields
   409. Canonical translated params are hashed, so JSON field order is irrelevant.
4. Give upstream requests at least 70 seconds (service deadline 65 seconds).
   Preserve commander's HTTP status, `error.code`, `requestId`, `Retry-After` and
   `Idempotency-Replayed`. A successful replay has `Idempotency-Replayed: true`.
   Do not automatically retry physical commands with a new key. A transport
   timeout after sending must surface `command_outcome_unknown`.
5. Refresh observed status after a command without assuming execution from
   TeslaMate's lagging history. Phase 1's TeslaMate collector remains read-only.
   `wake_up` success means **wake request accepted**, not confirmed online; only
   commander's automatic wake/retry path polls for online. Stub health includes
   `mode: "stub"`; never present stub success as actual vehicle control.

### Required additive Phase 2 iOS seam (owned by the iOS/backend workers)

The current `VoltaDataSource.command(vehicleID:name:params:)` uses
`[String: String]` and has no intent key. It is the Phase 1 disabled contract;
it cannot call commander unchanged. Keep that existing method unavailable, and
add a typed Phase 2 overload such as:

```swift
func command(vehicleID: Int, command: VehicleCommand, intentID: UUID) async throws
```

`VehicleCommand` should encode the command-specific flat bodies in the table
below: temperatures/coordinates as JSON numbers, percentages as JSON integers,
trunk/window selectors as JSON strings, and parameterless commands as `{}`.
The Controls sheet creates and retains `intentID` before sending. The networking
layer adds its UUID string as `Idempotency-Key`; volta-api validates the typed
body and forwards it without string coercion. On client timeout, recover/query
the same intent by replaying its same key and body; retain pending keys across
app retries/restarts. A new deliberate control action gets a new UUID.

This typed overload, networking header and backend forwarding remain separate
Phase 2 integration work. This PR does not edit the shared Swift contract,
Controls sheet or `server/`. Do not forward the old string-only numeric payloads
or connect Phase 1 controls while claiming this seam is already implemented.

Commander caps queue wait at two seconds. `command_in_progress` has no receipt
or budget charge: retry the same key after `Retry-After`. Cancellation before
durable reservation creates no command receipt; after reservation, execution
continues with a bounded independent context to persist the result even if the
client disconnects. A definite Tesla 429 clears its reservation (local budget
still applies), so the same key can retry after `Retry-After`. Definitive dial
failure is saved as `upstream_unavailable`; after repair use a new confirmed
intent/key, since replays retain that original failure. Never automatically use
a new key to retry an ambiguous outcome.

### Allowed names and parameters

All bodies are flat JSON objects, maximum 4096 bytes, camelCase, metric. Empty
commands require `{}`. Unknown/duplicate/extra fields, nulls, numeric strings,
fractional percentages, nonfinite/out-of-range values and unknown commands fail
closed before contacting Tesla. There are no arbitrary Fleet endpoints.

| Volta command | Body | Proxy/Fleet mapping |
|---|---|---|
| `lock`, `unlock` | `{}` | `door_lock`, `door_unlock` |
| `climate_on`, `climate_off` | `{}` | `auto_conditioning_start/stop` |
| `set_temps` | `{driverTempC, passengerTempC}`, both numbers 15–28 °C | `set_temps`, `driver_temp`, `passenger_temp` |
| `charge_start`, `charge_stop` | `{}` | same names |
| `set_charge_limit` | `{percent}`, integer 50–100 | same name/field |
| `open_charge_port`, `close_charge_port` | `{}` | `charge_port_door_open/close` |
| `actuate_trunk` | `{whichTrunk:"front"\|"rear"}` | `which_trunk` |
| `window_control` | `{command:"vent"\|"close"}` | same name/field; modern signed protocol needs no coordinates |
| `honk`, `flash` | `{}` | `honk_horn`, `flash_lights` |
| `sentry_on`, `sentry_off` | `{}` | `set_sentry_mode`, `{on:true/false}` |
| `trigger_homelink` | `{latitude, longitude}`, numbers −90…90/−180…180 | `trigger_homelink`, `lat`, `lon` |
| `wake_up` | `{}` | direct Fleet `POST /api/1/vehicles/{vin}/wake_up` |

`actuate_trunk` is upstream's open/actuate operation, not a general close-trunk
toggle. Legacy pre-2021 S/X vehicles have different protocol/parameter behavior;
this groundwork targets George's signed-command-capable car. Confirm actual
capabilities during pairing and do not promise unsupported controls.

### Controls sheet errors

| HTTP | `error.code` | iOS action/message |
|---|---|---|
| 501 | `commands_unavailable` | Disable controls; Phase 2 setup pending. |
| 409 | `authorization_required`, `reauthorization_required` | Owner must connect/reconnect Tesla on the server; no phone credentials. |
| 409 | `virtual_key_missing` | Open the documented owner pairing link. |
| 409 | `vehicle_asleep` | Vehicle did not wake; show retry later, with a new confirmed intent. |
| 409 | `vehicle_offline` | Check vehicle connectivity; do not loop commands. |
| 409 | `vehicle_unavailable`, `command_rejected` | Check vehicle state/capability (park, cable, HomeLink configured, etc.). |
| 409/502/503/504 | `command_outcome_unknown` | May have executed. Inspect vehicle/status before a new intent; same-key replay is safe. |
| 409 | `idempotency_conflict` | Client integration error: key reused with changed intent; do not resubmit automatically. |
| 409 | `command_in_progress` | Short bounded queue wait expired; retry the same key after `Retry-After`. |
| 408 | `request_cancelled` | Cancelled before acceptance; no command reserved/sent. Reuse the same intent key for a deliberate retry. |
| 429 | `rate_limited`, `tesla_rate_limited` | Honor `Retry-After`; no immediate repeated sends. |
| 400 | `invalid_command`, `invalid_params`, `idempotency_key_required` | Client validation issue; correct the request. |
| 401 | `unauthorized` | Backend internal secret mismatch; operator fixes it. |
| 403 | `permission_denied` | Check Tesla account access and granted scopes. |
| 404 | `vehicle_not_found` | Mapping or account access missing. |
| 502/503 | `oauth_unavailable`, `oauth_invalid_response`, `region_unavailable`, `upstream_unavailable`, `storage_unavailable` | Operator checks service/configuration; no blind command retry. |

In pinned upstream v0.4.1, offline/asleep and unpaired-key errors can be HTTP
500 with explicit text. Commander recognizes those and newer upstream variants;
it does not infer missing pairing solely from a generic 403/412. Unknown server
errors and malformed responses remain ambiguous. A direct 401 is surfaced for
reauthorization and never triggers an automatic physical-command retry.

## Operator-only OAuth contract

Sign in with Tesla is driven by the paired app through volta-api; see
[Sign in with Tesla](../docs/TESLA_SIGN_IN.md) for the full flow. All routes
below use the internal shared secret:

- `GET /v1/health` → `{ok, mode, commandsEnabled, oauthEnabled, historyEnabled, authorized}`. This is process
  readiness only; it does not call Tesla or prove token validity, proxy health,
  pairing, or live command execution.
- `GET /oauth/status` → `{available, connected, needsReauth, linkPending,
  collector:{enabled}, budget:{monthlyLimitUsd, spentUsd, paused},
  history:{enabled, account?}}`. No tokens. `account` is the opaque 64-hex
  namespace of the current link, present only while connected.
- `GET /v1/history/charging?pageNo&pageSize(≤50)&startTime[&endTime][&sortOrder]`
  reads one bounded page of Tesla-billed charging history: `501
  history_unavailable` unless `COMMANDER_CHARGING_HISTORY_ENABLED=true`. Any
  other parameter or a request body is refused. Metered through the shared
  budget ledger, plus 12 calls a day and 60 a month, one second apart, holding
  the collector lock. Invoices are never fetched. See
  [Tesla-billed charging history](../docs/CHARGING_HISTORY.md).
- `POST /oauth/start {"deviceId"}` → `{authorizationUrl, callbackScheme, expiresAt}`.
  Supersedes any earlier pending link. Ten-minute state/verifier are bound to the
  device and stored encrypted (state only as a hash). `already_authorized` unless
  a reconnect is required. Set `COMMANDER_OAUTH_ENABLED=true` for setup while
  keeping commands disabled; otherwise `501 oauth_disabled`. Read-only scopes are
  requested unless commands are enabled.
- `POST /oauth/complete {"deviceId","state","code"|"error"}` consumes the link
  durably, exchanges the code with the client secret and verifier, saves
  encrypted tokens and discovers region. Replays from the same device return the
  stored outcome; other devices get `oauth_state_invalid`; a live link started
  by another device returns `409 oauth_device_mismatch` without being consumed.
  Errors: `oauth_state_invalid`, `oauth_denied`, `oauth_code_rejected`, and
  `400 oauth_link_failed` when the exchange or token save fails
  after the link was consumed (the code may be spent, so the client starts a new
  sign-in instead of retrying). A `503 storage_unavailable` before consumption
  is safe to retry with the same callback.
- `POST /oauth/cancel {"deviceId"}` drops only that device's pending link.
- `DELETE /oauth/account` locally disconnects and invalidates pending login,
  preserving receipts/rate limits. Use it before a deliberate reconnect.
  This **does not** remotely revoke Tesla consent or remove the vehicle key.
  A rejected refresh token marks the account `needsReauth` and allows relinking.

## Exactly what must be public

1. **Always public:** the P-256 public key at
   `https://<app-domain>/.well-known/appspecific/com.tesla.3p.public-key.pem`.
   Tesla fetches it for partner registration/pairing; it must remain available
   without login, Tailscale, Cloudflare Access or a private bearer header.
2. **Owner-browser reachable:** the registered HTTPS OAuth callback
   (`https://georgenijo.com/volta/oauth/callback`). Tesla redirects George's
   browser here. It is a stateless bounce: it validates the query and 302s to
   `volta://tesla-callback` with only `state` plus `code` or `error`; it never
   exchanges or stores anything. `deploy/edge/` serves both paths from a
   Cloudflare Worker with logs and observability off; its callback route ends
   in `*` because Cloudflare route matching includes the query string, and the
   Worker itself answers only the exact pathname. Commander's 8091 listener
   provides the same two routes for local/stub use.
3. **Never public:** private listener/commands, `/oauth/*` operator routes,
   `/v1/health`, the collector (8092), raw `tesla-http-proxy` port 4443,
   state/log files, client secret, encryption key and any private PEM.

## George's prerequisite checklist and decisions

- [ ] Choose the application's domain and callback URL. Choose whether callback
  access stays on the tailnet or uses an exact-path public route. Domain must
  match Tesla's allowed-origin registration rules.
- [ ] Register/approve a private application at
  [developer.tesla.com](https://developer.tesla.com/), choose third-party
  authorization code access, set allowed origins and exact redirect URI, and
  obtain actual client ID/client secret. Set the Tesla billing limit/budget;
  commands, wake and state reads have usage costs. No credentials exist in this PR.
- [ ] Read-only collection requests `openid offline_access vehicle_device_data
  vehicle_location`. Commands add `vehicle_cmds vehicle_charging_cmds` only when
  `COMMANDER_COMMANDS_ENABLED=true`, which also needs a new consent and the
  virtual key; enabling them is a separate decision. Charging history alone
  (`COMMANDER_CHARGING_HISTORY_ENABLED=true`) adds only `vehicle_charging_cmds`,
  which Tesla bundles with charging commands; it is also a separate decision
  and needs a new consent, not the virtual key. HomeLink coordinates are
  caller parameters, not a new location read.
- [ ] Generate the signing key **once**, protect it and the private proxy TLS key,
  and publish only the public export at the exact well-known HTTPS path.
- [ ] Using a **partner token** (client-credentials flow with selected regional
  Fleet audience), register via `POST /api/1/partner_accounts` with
  `{"domain":"<app-domain>"}` and verify the public-key endpoint. Registration
  is required in every region used; for George choose NA unless discovery says
  otherwise. Never substitute the partner token for a third-party user token.
  This is a prerequisite, not an automated privileged action in commander.
- [ ] Configure distinct random internal/encryption secrets, actual app settings,
  stable encrypted storage and the local-ID/full-VIN mapping. Use the pinned
  proxy, trusted proxy cert (with Docker service DNS SAN), live profile and single-instance service.
- [ ] Complete George's one-time login, verify Tesla accepts/enforces our S256
  PKCE flow, and verify region discovery. If Tesla doesn't support that flow,
  stop at the acceptance gate and resolve the documented contract; don't remove
  PKCE silently. Refresh-token rotation/expiry/revocation must also be confirmed
  against the actual app after setup.
- [ ] On George's phone with the Tesla app, pair the virtual key through
  `https://tesla.com/_ak/<app-domain>?vin=<full-VIN>` (omit VIN to select in-app).
  Approve the key with owner access near the vehicle; inspect Tesla's key list.
  Pairing requires George's trusted user action. Confirm protocol/capabilities
  for the actual model/firmware.
- [ ] Explicitly authorize deployment and enabling controls. Run one owner-chosen
  low-impact live command and check its physical/status outcome. Local tests or
  stub success do not satisfy this acceptance. Until then keep Phase 1 unavailable.

Official references checked 2026-10-07:
[third-party OAuth](https://developer.tesla.com/docs/fleet-api/authentication/third-party-tokens),
[scopes](https://developer.tesla.com/docs/fleet-api/authentication/overview),
[partner tokens](https://developer.tesla.com/docs/fleet-api/authentication/partner-tokens),
[partner registration](https://developer.tesla.com/docs/fleet-api/endpoints/partner-endpoints),
[virtual key guide](https://developer.tesla.com/docs/fleet-api/virtual-keys/developer-guide),
[official proxy](https://github.com/teslamotors/vehicle-command).
