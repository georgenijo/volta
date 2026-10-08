# Tesla integration prerequisites

Research checked **2026-10-07** against the linked primary sources. Prices and
portal requirements must be rechecked at enrollment. No private tokens,
developer account, vehicle or running TeslaMate instance were inspected.

## Phase 1: how TeslaMate authenticates

TeslaMate defaults to the unofficial **Owner API**, with an externally generated
access token and refresh token entered at its sign-in page. TeslaMate does not
generate the initial tokens itself; Owner and Fleet tokens are different and
must match the configured API. See [token generation](https://docs.teslamate.org/docs/installation/tokens/).

George's `teslamate-host/ubuntu/compose.yml` pins TeslaMate/Grafana **4.3.0** and
PostgreSQL 17, with no `TESLA_API_HOST` or OAuth-client overrides. This indicates
the default configuration, not proof of successful authentication. Credentials
remain in TeslaMate; Volta reads approved history tables and needs no Tesla token.

The [4.3.0 release](https://github.com/teslamate-org/teslamate/releases/tag/v4.3.0)
includes safer refresh handling, clearer rejected-token errors and credential
log protection. It does not announce a native direct Fleet Telemetry receiver.
[TeslaMate's API guide](https://docs.teslamate.org/docs/configuration/api/)
(also checked in the [4.3.0 tag](https://github.com/teslamate-org/teslamate/blob/v4.3.0/website/docs/configuration/api.md))
documents configurable Fleet API endpoints/client ID and a separate streaming
adapter. It recommends Owner API for ordinary personal accounts while available,
and Fleet migration for business fleets. Its sample telemetry bridge uses GCP
Pub/Sub and a WebSocket translator; Volta's private design must replace that
hosted dependency with self-operated ingestion. Its direct-Fleet section still
labels the path free; use Tesla's metered prices below. Its one-minute minimum
is not a current universal telemetry limit: Tesla's
[system-behavior examples](https://developer.tesla.com/docs/fleet-api/fleet-telemetry#system-behavior)
use one-second intervals. Actual availability depends on field/client version.

**Unverified:** George's account type, valid token audience, latest recorded
data, and what actually runs on Ubuntu. If Owner API access is unavailable for
his account, Fleet enrollment becomes a Phase 1 collector blocker rather than
something Volta can fix by reading SQL.

## Fleet API application registration

Tesla's [onboarding guide](https://developer.tesla.com/docs/fleet-api/getting-started/what-is-fleet-api)
requires a Tesla account with verified email/MFA and an application request
with legal business details, name, description, purpose and scopes. Approval
produces a client ID and client secret. The public documentation does not
establish whether George's specific personal application/legal details will
be approved; the authenticated portal is the authority.

Configure **Authorization Code** and **Machine-to-Machine** grants. Register
an allowed HTTPS origin under George's controlled public-key domain and the
exact OAuth callback URI chosen for Volta. **Superseded:** the registered
values are origin `https://georgenijo.com` and callback
`https://georgenijo.com/volta/oauth/callback`; see
[Sign in with Tesla](TESLA_SIGN_IN.md). Original proposal: public origin
`https://<app-domain>` hosts only the PEM; callback
`https://<node>.<tailnet>.ts.net/oauth/tesla/callback` is handled by the private
broker while George's authorizing browser is on Tailscale. The broker exchanges
the code and stores credentials; the public host receives none. These are
proposed values, not existing endpoints. Confirm Tesla accepts this callback
outside the origin's root domain in the portal before implementing it. If it
does not, revisit the callback design explicitly; do not expose the whole API.
Tesla documents the callback in [third-party tokens](https://developer.tesla.com/docs/fleet-api/authentication/third-party-tokens);
the portal's origin/grant field names are corroborated by the primary
[Home Assistant integration guide](https://www.home-assistant.io/integrations/tesla_fleet/).
**Not directly verified:** the current authenticated Tesla form and which
origin/redirect variants it accepts. Do not assume wildcards or custom schemes.

Generate an EC `prime256v1` key pair and keep the private half on the server.
Host only the public PEM, without a login challenge, at the exact path:

```text
https://<domain>/.well-known/appspecific/com.tesla.3p.public-key.pem
```

Obtain a [partner token](https://developer.tesla.com/docs/fleet-api/authentication/partner-tokens)
using `client_credentials`, client ID/secret and the regional Fleet audience.
Call [partner registration](https://developer.tesla.com/docs/fleet-api/endpoints/partner-endpoints)
(`POST /api/1/partner_accounts`, domain body) in every region of operation.
The registered domain must share the allowed origin's root domain; keep the
registration domain, PEM hostname and pairing link consistent.
Use Tesla's [region list](https://developer.tesla.com/docs/fleet-api/getting-started/regions-countries)
rather than inferring a region from George's phone location.

For George's personal vehicle, implement authorization-code consent and a
validated random `state`, then exchange/refresh tokens on the server. Include
`openid offline_access` for refresh access; request only needed scopes:
`vehicle_device_data`, `vehicle_location` when routes are needed,
`vehicle_cmds` for controls, and `vehicle_charging_cmds` for charging actions.
Partner registration does not substitute for the vehicle owner's consent.
See [authentication scopes](https://developer.tesla.com/docs/fleet-api/authentication/overview).
Use `fleet-auth.prd.vn.cloud.tesla.com` for server-side token exchange, including
refresh. Persist each returned refresh token atomically before treating renewal
as successful; serialize renewal and provide crash recovery. Tesla's
[FAQ](https://developer.tesla.com/docs/fleet-api/support/faq) says refresh tokens
last three months and the most recently used token remains valid up to 24 hours.
Keep one writer per token chain; a Fleet-configured TeslaMate and Volta's broker
need independently managed grants/token storage, not copies of one rotating
token. **Unverified:** whether repeated consent by the same user to the same
client preserves independent chains; prove that behavior or use separate Tesla
client applications. Monitor expiry/renewal failure and request reauthorization
when necessary.

## Virtual keys and signed commands

After OAuth consent, George opens the following on his phone, using the same
Tesla account and selecting the correct vehicle, and accepts pairing in the
Tesla app:

```text
https://tesla.com/_ak/<domain>
```

The [virtual-key guide](https://developer.tesla.com/docs/fleet-api/virtual-keys/developer-guide)
requires the public PEM to remain available. OAuth grants access through Tesla;
the paired public key permits the vehicle to verify commands/configuration.
Deleting the key or revoking third-party access withdraws that authority.

Use the official [vehicle-command proxy](https://github.com/teslamotors/vehicle-command)
behind the private API. The proxy signs requests with the application private
key and forwards them with OAuth. Its TLS server key and the application
command-signing key are distinct secrets.

Tesla's [command docs](https://developer.tesla.com/docs/fleet-api/endpoints/vehicle-commands)
state that unsigned requests are rejected by vehicles requiring this protocol,
with exceptions for most business vehicles and pre-2021 Model S/X. The SDK
states pre-2021 S/X do not support the new protocol. Plan for signed commands
on modern Model 3/Y, Cybertruck and 2021+ S/X, but decide from the actual
[`fleet_status`](https://developer.tesla.com/docs/fleet-api/endpoints/vehicle-endpoints)
`vehicle_command_protocol_required` and key status, not a model-year guess.
George's model/year/firmware and individual command support remain unverified.

## Pricing and billing as checked today

Tesla currently advertises **usage pricing**, not fixed Basic/Pro subscription
tiers. The USD [developer homepage](https://developer.tesla.com/) lists:

| Category | Units per USD 1 | Equivalent unit charge |
|---|---:|---:|
| Streaming signals | 150,000 | $0.000006667 approximately |
| Commands | 1,000 | $0.001 |
| Device data polls | 500 | $0.002 |
| Wakes | 50 | $0.02 |

The [billing policy](https://developer.tesla.com/docs/fleet-api/billing-and-limits)
provides a $10 monthly discount, monthly invoices, and a default billing limit
of zero. Adding a payment method permits raising that limit; configure an
explicit cap. Requests below HTTP 500 are billable, including failed 4xx calls.
Authentication endpoints are unbilled per their token documentation.
At the cap, usage is suspended and telemetry configurations are removed;
reenabling access does not restore them. Rate limits are distinct from billing
(per device/account: 60 realtime-data, 30 command and 3 wake requests/minute).
The page retains an obsolete 2024 payment-transition sentence; do not rely on it.

Illustration at these rates: one poll/minute for 24 hours is $2.88/day before
discounts, while 100 commands cost $0.10. This is arithmetic, not a usage forecast.
**Unverified:** George's portal currency/tax, credit application without a payment
method, negotiated terms and actual monthly usage. A $10 discount is not a
promise of uninterrupted free service. Recheck the portal before enabling calls.

## Fleet Telemetry receiver requirements

[Tesla's current overview](https://developer.tesla.com/docs/fleet-api/fleet-telemetry)
describes the modern path: public receiver, paired virtual key and configuration
through the signing proxy. Baseline firmware is 2024.26+; Intel Atom S/X require
2025.20+. Legacy certificate-signed setups have different requirements and are
not the new-install plan. Pre-2018 S/X without the infotainment upgrade are
unsupported per the billing page's compatibility note. Verify actual hardware
and `fleet_status` before promising coverage. Tesla's
[2025-06-26 announcement](https://developer.tesla.com/docs/fleet-api/announcements#2025-06-26-fleet-telemetry-support-for-model-s-and-model-x-intel-atom-vehicles)
specifically exempts those Intel S/X from virtual-key pairing: their owner must
enable Allow Third-Party App Data Streaming in the in-car Safety screen.
**Unverified:** the exact configuration-delivery procedure for this hardware;
confirm it before Phase 3. This exception is distinct from legacy certificate
signing, and does not establish a need to use that old enrollment flow.

The [official receiver repository](https://github.com/teslamotors/fleet-telemetry)
requires **mTLS to terminate at Fleet Telemetry**, where vehicle TLS client
certificates are authenticated. Provide public DNS, a valid server certificate
and private TLS key, a compatible CA chain, and public TCP ingress (default
443). Validate hostname/port/CA with its `check_server_cert.sh`. Use a TCP
passthrough firewall/load balancer; an ordinary HTTPS proxy that terminates TLS
or injects a browser login is not an equivalent receiver.

For the modern key-paired path, signed [`fleet_telemetry_config`](https://developer.tesla.com/docs/fleet-api/endpoints/vehicle-endpoints)
contains receiver host/port/CA, requested fields and emission intervals/deltas.
It is signed using the application key already paired to the vehicle, distinct
from receiver TLS credentials. Location fields require `vehicle_location`.
Use a local durable dispatcher/consumer; choose only necessary fields and
measure signal costs. Streaming sends changed values while awake/connected,
not a full polling-equivalent snapshot. New configurations need an explicit
coverage/cutover plan; see [ROADMAP.md](ROADMAP.md).

## George's ordered personal checklist

### Needed now for Phase 1

1. Restore/confirm access to **ubuntu**, or choose **opti** as the fallback;
   authorize deployment separately. Confirm which TeslaMate instance/database
   is authoritative and whether it contains existing history.
2. Confirm personal versus business-fleet Tesla account, vehicle selection and
   logger sign-in. If authentication is missing, generate compatible Owner API
   access/refresh tokens with a tool from TeslaMate's guide and enter them
   directly into TeslaMate. Supply secrets through a private server channel,
   never chat, Git or the iPhone app. Existing valid tokens need not be replaced.
   **If Owner API is unavailable**, complete the conditional collector checklist
   below before treating Phase 1 as ready; do not keep attempting Owner login.
3. Select an encrypted off-host backup destination and retention policy; retain
   TeslaMate's encryption key separately. Confirm tariff/currency inputs in
   TeslaMate if charge-cost estimates are wanted.
4. Sign into the same Tailscale tailnet on iPhone and permit its VPN. Enable
   tailnet HTTPS if needed; accept the final private API URL and pair using a
   one-time code generated on the server. Identify the allowed admin devices
   for TeslaMate/Grafana; restrict their separate web ports as in DEPLOY.md.
5. Confirm the phone can run **iOS 26+** and sign into Xcode with George's Apple
   Account on the build Mac. Provide the signing team selection; trust/pair the
   phone and enable Developer Mode for direct development install.
6. Choose free Personal Team for the first direct install (seven-day renewal),
   or enroll/confirm paid **Apple Developer Program** membership for TestFlight
   (USD 99/year, local pricing may vary). Paid membership is **not required**
   for the first Xcode install. TestFlight requires App Store Connect setup and
   a build upload; it is optional for Phase 1. See [DEPLOY.md](DEPLOY.md).

### Conditional Phase 1 collector setup if Owner API is unavailable

1. Complete Tesla developer approval, domain/PEM hosting, partner registration,
   billing and a supported consent flow now, using the enrollment steps above.
   Verify TeslaMate 4.3's actual Fleet sign-in/refresh path before provisioning.
2. Have the operator configure TeslaMate's regional `TESLA_API_HOST`,
   `TESLA_AUTH_HOST`, `TESLA_AUTH_PATH` and `TESLA_AUTH_CLIENT_ID` from its tagged
   guide, checking that server token exchanges use Tesla's current token host.
   Supply a compatible Fleet grant directly to the collector; keep its token
   lifecycle independent of the later command broker.
3. Approve a measured collection/billing budget. Continuous one-minute polling
   for 30 days would cost $86.40 before the monthly discount at published USD
   rates; this illustrates cost, not TeslaMate's actual duty cycle. Measure
   history resolution and respect sleep rather than raising polling blindly.
4. Disable incompatible Owner streaming while using Fleet polling, or bring
   forward an explicitly scoped self-hosted telemetry adapter with the relevant
   Phase 3 requirements. Hosted MyTeslaMate/Teslemetry intermediaries do not
   meet Volta's infrastructure goal and are excluded from this fallback.

### Needed later, in order

1. Before Phase 2, provide vehicle model/year, hardware, installed firmware and
   account region; choose a controlled application domain and OAuth callback
   and authorize hosting the public PEM. No public vehicle-history API is needed.
2. Complete Tesla developer MFA/application/legal-details submission and accept
   its terms. Provide the approved client ID and store the client secret in the
   server secret store. Resolve any personal-app approval rejection yourself.
3. Choose a Tesla billing method and monthly cap after reviewing portal prices.
   Engineers generate/store the key, host its public half and register the
   partner in each required region; verify those receipts before consent.
4. Complete Tesla OAuth consent for the minimum scopes and accept virtual-key
   pairing through `tesla.com/_ak/<domain>`. Keep the tokens server-side and
   authorize a safe physical-vehicle command test before controls are enabled.
5. Before Phase 3, choose/authorize the public receiver domain, TCP ingress and
   TLS certificate/renewal plan. Confirm compatible vehicle firmware and any
   applicable Intel S/X in-car toggle using `fleet_status`. Engineers validate mTLS,
   sign configuration and prove stream ingestion before reducing polling.
6. Choose telemetry retention, automation rules/actions and notifications.
   Enroll in the paid Apple program if remote APNs updates are chosen, and
   approve minimal push payloads leaving the private infrastructure. Approve
   each automation's physical effects before enabling it.
