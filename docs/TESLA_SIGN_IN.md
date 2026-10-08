# Sign in with Tesla

Volta links George's Tesla account from the app, replacing externally generated
tokens pasted into TeslaMate. Collection is **read-only**: the requested scopes
are `openid offline_access vehicle_device_data vehicle_location`. No command
scope is requested and no command is enabled. History stays in TeslaMate's
database on George's server.

## Flow

```text
Volta app ──POST /v1/tesla/link──▶ volta-api ──POST /oauth/start {deviceId}──▶ commander
   │                                              (state hash + PKCE verifier, device-bound,
   │                                               encrypted, 10 min, supersedes older links)
   ▼
ASWebAuthenticationSession (ephemeral) ─▶ auth.tesla.com/oauth2/v3/authorize
   │   Tesla login + consent (George only)
   ▼
https://georgenijo.com/volta/oauth/callback?code&state     ← Cloudflare Worker (deploy/edge)
   │   validates, 302 → volta://tesla-callback?code|error&state; stores/logs nothing
   ▼
Volta app ──POST /v1/tesla/link/complete {callbackUrl}──▶ volta-api ──▶ commander /oauth/complete
       commander checks device + state, consumes link durably, exchanges the code
       with the client secret + verifier, stores encrypted tokens, discovers region
   ▼
TeslaMate ──TOKEN-mode reads──▶ commander collector :8092 (private network)
       allowlisted GETs only, cached, paced under the monthly budget
```

- The code is useless without the client secret, which exists only on the
  server. State and verifier never leave commander; state is persisted only as
  a SHA-256 hash.
- Only the device that started the link can complete it. A repeated completion
  from that device replays the stored result, including across restarts.
  Another device is refused. If Tesla or storage fails after the link was
  consumed, the result is a terminal "start again" (`tesla_link_failed`); the
  app drops that callback and offers a fresh sign-in.
- Cancel, denial, expiry (10 minutes), a new start (supersedes), app
  backgrounding and commander restarts are handled; see `commander/signin_test.go`
  and `ios/VoltaTests/TeslaLinkTests.swift`.
- A rejected refresh token marks the account **Reconnect needed** in the app;
  signing in again relinks it.
- No token, code or state reaches logs, URLs other than the one-time callback,
  analytics, widgets, exports, or responses. The API returns only status fields.

## Registered values

| Field | Value |
| --- | --- |
| Grants | authorization-code, client-credentials |
| Allowed origin | `https://georgenijo.com` |
| Redirect URI | `https://georgenijo.com/volta/oauth/callback` |
| Public key | `https://georgenijo.com/.well-known/appspecific/com.tesla.3p.public-key.pem` |
| Scopes | Vehicle Information, Vehicle Location |

The client ID is operator configuration supplied out of band; it is not
committed. The client secret is never committed, pasted into chat, or baked
into the app.

Fleet Telemetry, commands or charging control would need additional scopes, a
fresh consent and the virtual key. Each is a separate decision; nothing here
turns them on.

## Cost

Tesla bills data requests at 500 per $1, with a $10 monthly discount. Commander
records every upstream read in its encrypted store **before** sending it and
stops at `COMMANDER_MONTHLY_BUDGET_USD` (default **$20**, max $1000). Reads are
cached for `COMMANDER_CACHE_SECONDS` (default 60) and paced so the remaining
budget lasts to the end of the month: at $20 that is about one upstream read
every 4–5 minutes. Pacing applies to every upstream call, including failures:
billed replies (data, asleep, 4xx) are reused until the next allowed call, and
an uncached read inside the window gets `429` with `Retry-After`, which
TeslaMate honors by rescheduling. TeslaMate reads the vehicle summary and then
`vehicle_data` (or the reverse once the car sleeps) in one fetch, so the second
read of the same vehicle within a minute of an answered first read joins its
cycle; the next cycle then waits one extra interval, keeping the average at one
read per interval. With several vehicles, an opened slot is held for up to a
minute for a vehicle turned away during the last cycle and served less
recently, so no car starves. When the budget is spent, TeslaMate keeps the
last cached data and the app shows collection as paused. Disconnecting or
linking another account clears the cache, and a read in flight during the
change is dropped. No wake or command calls are
possible through the collector. Raising the budget makes data fresher.

## Operator setup (Ubuntu)

Run as root on the server. Never print secret values.

1. **Client secret file.** Copy the single value into a file only commander's
   uid can read:

   ```sh
   python3 -I deploy/commander/stage-client-secret.py \
     /opt/volta/secrets/<staged>.env /etc/volta/tesla/client-secret
   ```

   The script reads `TESLA_CLIENT_SECRET` (pass another key name as a third
   argument), keeps single-quoted values literal, and writes mode 0400 owned by
   65532. Only that one file is mounted into the container.

2. **Commander env** (`deploy/commander/.env`, mode 0600): `TESLA_CLIENT_ID`,
   `COMMANDER_INTERNAL_SECRET` and `COMMANDER_COLLECTOR_SECRET` (each
   `openssl rand -hex 32`, different), `COMMANDER_ENCRYPTION_KEY`
   (`openssl rand -base64 32`), `COMMANDER_VEHICLES={}`, and optionally
   `COMMANDER_MONTHLY_BUDGET_USD`.

3. **Start commander read-only:**

   ```sh
   docker compose --env-file deploy/commander/.env \
     -f deploy/commander/compose.yaml -f deploy/commander/compose.signin.yaml up -d commander
   ```

   Live read-only mode needs no signing proxy. Commands stay disabled.

4. **Public key and callback** (`deploy/edge`, Cloudflare Worker on two routes;
   the rest of georgenijo.com is untouched). Cloudflare matches a route against
   the whole URL, query included, and a pattern cannot contain a query, so the
   callback route is `georgenijo.com/volta/oauth/callback*`: without the `*`,
   Tesla's `?code|error&state` return would bypass the Worker. The Worker
   answers only the exact `/volta/oauth/callback` pathname and returns a local
   404 for anything else under that prefix. The key route stays exact. The
   redirect URI registered with Tesla is unchanged.

   ```sh
   cd deploy/edge
   bunx wrangler@4 deploy --var "TESLA_PUBLIC_KEY_PEM:$(cat /path/to/public-key.pem)"
   curl -fsS https://georgenijo.com/.well-known/appspecific/com.tesla.3p.public-key.pem
   curl -si 'https://georgenijo.com/volta/oauth/callback?state=s&code=c' | head -5   # 302 volta://…
   curl -si 'https://georgenijo.com/volta/oauth/callback?state=s&error=access_denied' | head -5   # 302 volta://…
   curl -si 'https://georgenijo.com/volta/oauth/callbackx' | head -1   # 404 from the Worker
   ```

   Only the public half is bound; the Worker refuses anything containing a
   private key. Logs and observability are off, and responses send
   `Cache-Control: no-store`, `Referrer-Policy: no-referrer` and `nosniff`.
   Cloudflare still terminates TLS for the callback URL; the one-time code it
   carries cannot be redeemed without the server-only secret and verifier.

5. **Partner registration** (once per region, after the PEM is live):

   ```sh
   docker compose --env-file deploy/commander/.env \
     -f deploy/commander/compose.yaml -f deploy/commander/compose.signin.yaml \
     run --rm commander register
   ```

   It prints only success or a generic error.

6. **API relay.** Add `COMPOSE_FILE=compose.yml:compose.tesla.yml` and the same
   `COMMANDER_INTERNAL_SECRET` to `/etc/volta/relay.env`, then restart
   `volta-api.service`. `GET /v1/tesla/status` should report `available: true`.

7. **TeslaMate.** Merge `deploy/teslamate/collector.env.example` into
   TeslaMate's env, attach it to the external `volta-collector` network, and
   recreate it. Open TeslaMate (tailnet only) once and press **Sign in**; it
   stores a placeholder session, not a Tesla token. Turn off **Use streaming
   API** for each car once it appears.

8. **Vehicle discovery.** TeslaMate lists vehicles only at startup. Install
   `deploy/ubuntu/volta-teslamate-rediscover.{path,service}` (set the container
   name) so commander's `linked` marker restarts TeslaMate once after a link, or
   press TeslaMate's vehicle reload after George signs in.

## George's step

On the paired phone: Volta → **Sign in with Tesla** (shown when no vehicle
exists, and under Settings → Account). Log in on Tesla's page and allow
Vehicle Information and Vehicle Location. Volta returns, shows **Connected**,
and rechecks for vehicles every 10 seconds for two minutes (then **Retry**).
Setup is not done until a vehicle appears.

## Disconnect

Settings → Account → Disconnect makes commander forget its Tesla tokens, so
collection stops. Recorded history stays in TeslaMate. Revoke Volta's access in
the Tesla account too if consent should end at Tesla.
