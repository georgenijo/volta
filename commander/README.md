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
