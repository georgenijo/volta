# Volta deployment and iPhone installation plan

Assessed **2026-10-07**. These are recommendations; no services, DNS, VPN
settings, accounts or databases were changed. [SPEC.md](SPEC.md) specifies a
tailnet-only API; [TESLA.md](TESLA.md) lists user prerequisites.

## Recommended placement

Run `volta-api` beside TeslaMate/PostgreSQL on **ubuntu** once host access and
logger health are confirmed. Keep database traffic on a private container
network, with no published PostgreSQL port. Colocation avoids a second host
dependency and sending SQL history over the network. Run the API under a
restart-managed service/container with a pinned build and separate persistent
Volta metadata. The API's DB account gets SELECT on necessary history tables,
no USAGE or table grants on TeslaMate's credential schema `private`, and limited
writes only to its own `volta` schema; avoid inherited superuser/owner roles and
use a separate migration identity for schema creation.

The local `teslamate-host/ubuntu/compose.yml` defines TeslaMate/Grafana 4.3.0,
PostgreSQL 17, restart policies and named data volumes. It binds web UIs to
`${BIND_IP}` and does not expose PostgreSQL. The actual IP/configuration and
running containers were not inspected. Its README also packages Family Host
wrappers; neither packaging path proves a live deployment.

The package enables anonymous Grafana Viewer access and publishes admin UIs
on 3000/4000. These routes bypass Volta's token/revocation boundary. Before
Phase 1 acceptance, restrict both ports to George's selected admin devices via
Tailscale grants/ACLs, or use loopback bindings behind separately restricted
Serve access. Disable Grafana anonymous access in the deployment plan. Verify
TeslaMate's settings/token-entry UI is inaccessible to unapproved devices.
Loopback/Serve alone is not user authorization; its access policy must also be
restricted. No such settings were changed by this research.

The read-only `fleet context --json` snapshot at `2026-10-07T05:37:28Z` reported:

| Host | Evidence | Placement tradeoff |
|---|---|---|
| ubuntu | Online/reachable flags true; inventory failed with SSH connection closed. User reported offline. | Preferred after recovery; uptime, Docker and logger health unverified. Home power/uplink and known direct-path flakiness affect availability. |
| opti | Linux Mint 22.3; inventory succeeded, about eight weeks uptime and about 5.8 GB available RAM. | Best fallback Linux host. Existing home workloads and a tailscaled 443 listener require capacity/Serve checks. Move collector and DB together, or accept a cross-host dependency. Do not assume Docker is installed from the empty inventory. |
| mac-mini | M4 worker; tailnet online/reachable; SSH inventory timed out. Xcode availability is supplied task context. | Build/sign iOS here after Xcode verification. An always-awake Mac can host Bun, but sleep/reboots and a Linux-container VM add operational dependencies. Keep build jobs separate from collection. |
| macbook | Control node; local inventory succeeded. | Convenient local development/direct phone install, but a mobile workstation is a poor unattended logger/API host. |
| Family Host | CLI 0.8.0 app inventory succeeded; no Volta/TeslaMate app listed. | Managed restart/persistence/HTTPS is attractive. Private apps use browser identity access, not the specified Volta bearer-token/tailnet flow. Existing-host DB access and private tailnet attachment are unverified. |

Family Host's service model is a local operator reference (installed at
`/Users/macbook/.codex/skills/family-host/references/service-model.md`);
its public control plane is [family.georgenijo.com](https://family.georgenijo.com).
Use the tenant CLI for any future hosted app and its dry-run workflow before
provisioning. Managed PostgreSQL and persistent `/data` exist as platform
features, but migrating this TeslaMate DB is a separate decision and must
preserve/restorably back up history and encryption keys.

**Decision:** retain the task's Ubuntu/private API architecture. If Ubuntu cannot
be made reliable, choose opti explicitly and update the endpoint/deployment plan.
Do not deploy a public Family Host analytics endpoint merely to work around VPN
reachability. The topology flags alone prove neither SSH nor service health.

## How the iPhone reaches the API

Use [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve) to
terminate HTTPS at the node's full `<node>.<tailnet>.ts.net` name, forwarding
to an API listening on loopback. Tailnet HTTPS must be enabled; access rules
apply to Serve. The Volta bearer token still authenticates/revokes each device.
The phone uses the DNS HTTPS URL, not a raw `100.x` URL with a mismatched cert.

Future setup sequence, only after deployment authorization:

1. Inspect `tailscale serve status` and listeners on the selected host before
   assigning a port/path; preserve existing mappings. Confirm the real API
   listen port with the backend implementation rather than guessing one.
2. Configure persistent Serve forwarding to that loopback port, verify the
   returned HTTPS URL, and grant only George's intended devices access.
3. Install Tailscale iOS, sign into the tailnet, accept its VPN configuration
   and connect. Test `/v1/health` from the phone on cellular and Wi-Fi.
4. Pair Volta with the server URL and one-time 8-character code; token storage
   is Keychain-backed. Revoke a test device and verify protected calls fail.
5. Enable [VPN On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand):
   profile/settings → VPN On Demand; choose Always on Wi-Fi and cellular for
   predictable private access. Alternatively choose Do Nothing and enable
   `*.ts.net` hostname matching. Avoid home-Wi-Fi exceptions unless another
   private route has been proven. Test relaunch, network switching and VPN loss;
   another On Demand VPN may disable Tailscale's policy.

Serve is private to the tailnet. Public Funnel is not needed. Keep HTTP/SQL
ports inaccessible from the public internet and do not replace device-token
auth with a trusted-header assumption. HTTPS certificate issuance may disclose
the node DNS name through certificate transparency; avoid sensitive host names
([Tailscale HTTPS](https://tailscale.com/kb/1153/enabling-https)).

## Public exposure in later phases

Phase 2 needs a public HTTPS **static PEM path** and a private OAuth callback,
not public access to `volta-api`, PostgreSQL or the command proxy. A small public
Family Host app can be evaluated for PEM hosting; a private Access-gated app
cannot serve Tesla's key fetch. Expose only the needed paths, and keep tokens,
keys and history out of page content and access logs. The signing proxy remains
private and connects outbound to Tesla. The proposed callback is on the private
node's HTTPS URL; George's browser uses Tailscale to reach it, and the broker
performs the code exchange. The public PEM host handles no OAuth codes, secrets
or tokens. Portal acceptance of that redirect outside the public origin's root
domain is an enrollment gate; see TESLA.md before implementing the callback.

Phase 3 needs a separate internet-reachable Fleet Telemetry hostname/TCP port
with mTLS ending at the receiver. Serve cannot receive vehicles outside the
tailnet. An HTTP/Cloudflare browser proxy is not sufficient evidence of mTLS
passthrough; Family Host's tenant service model does not prove support for this
ingress. Verify raw TCP passthrough and client-certificate validation before
selecting it. Ubuntu/opti would need authorized DNS, certificate renewal and a
tested public TCP route despite home NAT; a separately approved public ingress
host with TCP forwarding to George's receiver is an alternative. Host/network
availability for that path is **unverified**. See [Tesla requirements](TESLA.md).

## Backup and recovery plan

Adopt daily logical dumps with an explicit suggested retention of 7 daily,
4 weekly and 3 monthly copies, plus a fresh backup before upgrades/migrations.
George must choose the destination and accept the recovery window. Follow
[TeslaMate's backup guide](https://docs.teslamate.org/docs/maintenance/backup/);
for the packaged database service the core command is:

```sh
# Example only: run from the confirmed Compose directory after authorization.
# Operator first creates a restricted /var/backups/volta directory.
umask 077
docker compose exec -T database pg_dump -U teslamate -Fc teslamate \
  > "/var/backups/volta/teslamate-$(date -u +%Y%m%dT%H%M%SZ).dump"
```

Use the PostgreSQL 17 client in the container. Automate exit-status checks,
nonempty output and `pg_restore --list`; encrypt before copying through Fleet
to an independent host/storage destination. Raw live volume copies are not a
substitute for a consistent database backup. Store backups outside checkout
and Compose directories, with restricted access, checksum and completion time.

Back up the `volta` schema if it shares this DB, or separately if the backend
uses another store. Preserve DB role/grant definitions for reconstruction;
`pg_dump` alone does not include cluster roles. Keep TeslaMate `ENCRYPTION_KEY`,
DB credentials and later OAuth/signing material in a separate encrypted secret
backup, never source control. A restored token row without its encryption key
is not a complete logger recovery. Include Grafana persistence if customized.

Periodically restore into an isolated PostgreSQL 17 instance with no outbound
Tesla access. This custom-format dump requires `pg_restore`, not the upstream
plain-SQL `psql < backup` recipe. Provision an empty restore database with the
needed roles, then run
`pg_restore --exit-on-error --dbname=<restore-database> <decrypted-dump-path>`;
restore all intended schemas, including `volta`.
Do not mix the dump into an existing DB by dropping only `public`/`private`.
Keep the restored API disabled until all Volta device tokens are invalidated
and devices re-paired, or current revocations have been independently reapplied;
old backups can otherwise re-enable revoked devices. Reconstruct least-privilege
grants, check schema/data counts and representative history queries,
and verify Volta reads it. Never test restoration over the active DB or start
a duplicate logger against real vehicles. Record achieved recovery time and
last successful backup/restore. Retention/deletion must cover backup copies too.

## Installing on George's iPhone

First verify iOS 26+, matching Xcode SDK and the build host. Paid membership
is optional for the initial **direct Xcode install**. A free Apple Account
creates a Personal Team; Apple says its provisioning expires after seven days
and requires rebuild/reinstall. See [developer accounts](https://developer.apple.com/help/account/basics/about-your-developer-account).
Paid [Apple Developer Program](https://developer.apple.com/programs/enroll/)
membership is USD 99/year (region-dependent) and enables distribution services.

For a direct install:

1. George signs into Xcode's Apple Accounts settings and chooses his Personal
   Team or paid team for `com.georgenijo.volta` with automatic signing.
2. Generate/open the project using XcodeGen as specified in SPEC.md. Connect
   the phone by cable, unlock/trust the Mac and pair in Xcode's Device Hub.
3. George enables [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device),
   restarts/confirms on the phone, then selects it as the run destination.
4. Build/run, launch the installed app, pair to the private API and verify real
   data. Remote Mac mini builds do not alone establish phone pairing or install;
   use the Mac physically paired to the phone, usually macbook, when needed.

[Xcode device setup](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)
documents automatic signing. Existing team enrollment, phone OS, Xcode version
and successful installation are **unverified** in this research.

For **TestFlight**, George needs paid membership and an App Store Connect app
record matching the bundle ID. Archive/upload a distribution-signed build,
complete export-compliance/test information and add George as an internal
tester with an eligible role. Install TestFlight and accept the invitation.
External testers require the initial beta review; no public listing/link is
necessary for George's private testing. Builds expire after 90 days and need
replacement ([TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/),
[tester setup](https://developer.apple.com/testflight/)). TestFlight installation
does not require Developer Mode. It distributes the binary through Apple;
vehicle history still resides on George's server. Keep Tesla credentials and
real vehicle fixtures out of the uploaded app and demo/review evidence.
