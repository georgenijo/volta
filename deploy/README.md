# Deploy Volta on ubuntu

The backend was prepared while Ubuntu was offline. The first private bring-up
on 2026-10-07 uses `/opt/teslamate-host` and `/opt/volta`, with Volta HTTPS on
**9443** because HTTPS 443/root already belongs to another app.
The current TeslaMate deployment is `teslamate-host/ubuntu/compose.yml`:
project **teslamate**, network **teslamate_default**, database service **database**,
TeslaMate4.3.0, Postgres17. Do not publish the DB port or replace that stack.
Volta's compose project is **volta** and joins the existing external network.

## Prerequisites and bounded discovery

Run only once deployment is authorized and ubuntu is online. Confirm the node,
Docker/Compose, current services, and paths using Fleet:

```sh
fleet context --json
fleet exec ubuntu -- 'tailscale ip -4; sudo docker version; sudo docker compose version'
fleet exec ubuntu -- 'sudo docker network inspect teslamate_default; sudo docker ps --format "{{.Names}} {{.Image}} {{.Ports}}"'
fleet exec ubuntu -- 'tailscale serve status'
```

Use the existing private GitHub authentication on ubuntu to obtain
`georgenijo/volta` in `/opt/volta` (or adjust every path below). Select the merged
backend commit or a reviewed immutable SHA; do not deploy unrelated branch work.
Have TeslaMate's owning runbook confirm its deployment path and current backup.
For a fresh install, start TeslaMate and wait for its complete v4.3.0 migrations
before bootstrap. The unsigned-in backend may be brought up with empty data;
George completes Tesla sign-in later. Health alone does not prove collection.
Existing installations require a verified backup before changes.

## Bootstrap the dedicated roles

Coordinate with `teslamate-host`'s runbook: reuse group **volta_readonly**, LOGIN
**volta_reader**, and independent LOGIN **volta_auth**. `bootstrap.sql` is
idempotent on this arrangement and grants SELECT only on ten explicit telemetry
tables. It grants no access to `private.tokens`, no global SELECT grants, and no
future-table default grants. The TeslaMate administrator owns `volta` and its
DDL; `volta_auth` has DML/sequence access there only. Runtime credentials cannot
run migrations. Use fresh dedicated roles; do not repurpose an existing role
with broader memberships/privileges. Bootstrap retains the telemetry hardening:
reader connection limit 10, statement timeout 30s, idle-in-transaction timeout
60s and lock timeout 5s. The API uses a stricter 15s statement timeout for its
own connections. Bootstrap also creates `volta_positions_drive_route_idx`, a
partial covering B-tree on `(drive_id, date, id)` for valid GPS positions. Route
thumbnail sampling and gap probes depend on this index; existing installations
need the same index before adopting these queries. Creating it on an existing
large positions table should follow the owning database maintenance procedure
(use `CREATE INDEX CONCURRENTLY` outside a transaction). No database changes
are performed by the API. Bootstrap rejects administrative role attributes, database
CREATE, unexpected memberships (including non-inherited roles accessible via
SET ROLE), CREATE on any non-system schema, table writes or sequence USAGE/UPDATE outside the auth
schema, and private-token access, including inherited/PUBLIC privileges,
without altering shared grants. Coordinate any
pre-existing broad grants with the owning runbook and re-run its privilege
assertions after bootstrap.

For the multiline blocks below, enter Ubuntu with `fleet ssh --home ubuntu`
and run them there. Do not nest Python heredocs in a single-quoted `fleet exec`
argument. Automation may transfer a script containing code only with `fleet cp`
and execute it via `fleet exec --timeout 120 ubuntu -- 'sudo -n python3 <path>'`;
this was the method used on 2026-10-07. Check `sudo -n true` first: these piped
operations must not consume stdin for a sudo password prompt.

The canonical TeslaMate env file is
root-owned mode 600, so use `sudo` and the explicit `--env-file` on every Compose
invocation. Copy the SQL files to the same container directory so relative
includes resolve:

```sh
cd /opt/teslamate-host
for file in bootstrap.sql auth-schema.sql history-schema.sql service-schema.sql auth-grants.sql privilege-checks.sql; do
  sudo docker compose --env-file ubuntu/.env -f ubuntu/compose.yml cp "/opt/volta/deploy/$file" "database:/tmp/$file"
done
```

For a **fresh installation only**, generate dedicated passwords on the node
with `openssl rand -hex 32` directly into the protected API env file. Before generating anything, the script refuses existing dedicated LOGIN roles
or either known Volta env path. Also inspect `docker compose ls` and any prior
Volta container's Compose working-directory label for other deployment paths;
preserve their env files. An existing env or role means use its preserved
credentials/recovery procedure, or stop for an explicitly authorized rotation.
The check queries only role names, never password hashes. File creation is
exclusive; dependency failures occur before it, and write failures remove only
the file created by this invocation. Never shell-source either env file or
print it, resolved Compose config, password arguments, or raw DB errors.

```sh
sudo python3 - <<'PYTHON'
import os, subprocess
from pathlib import Path
path = '/opt/volta/deploy/ubuntu/.env'
known_envs = [Path(path), Path('/home/george/code/volta/deploy/ubuntu/.env')]
if any(p.exists() or p.is_symlink() for p in known_envs):
    raise SystemExit('Existing Volta env: preserve credentials; stop fresh setup')
check = subprocess.run(
    ['docker', 'compose', '--env-file', '/opt/teslamate-host/ubuntu/.env',
     '-f', '/opt/teslamate-host/ubuntu/compose.yml', 'exec', '-T', 'database',
     'psql', '-X', '-At', '-U', 'teslamate', '-d', 'teslamate', '-c',
     "SELECT EXISTS (SELECT FROM pg_roles WHERE rolname IN ('volta_reader','volta_auth'));"],
    text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
if check.returncode != 0 or check.stdout.strip() != 'f':
    raise SystemExit('Existing Volta role or failed check: stop fresh setup')
ip = subprocess.check_output(['tailscale', 'ip', '-4'], text=True).strip()
lines = ['TAILSCALE_IP=' + ip]
for key, role in [('TESLAMATE_DATABASE_URL', 'volta_reader'),
                  ('AUTH_DATABASE_URL', 'volta_auth')]:
    password = subprocess.check_output(['openssl', 'rand', '-hex', '32'], text=True).strip()
    lines.append(f'{key}=postgres://{role}:{password}@database:5432/teslamate')
lines.append('CURRENCY=USD')
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    with os.fdopen(fd, 'w') as env:
        env.write('\n'.join(lines) + '\n')
except BaseException:
    os.unlink(path)  # Only the file this invocation exclusively created.
    raise
PYTHON
```

Feed each password twice from that file to psql's hidden `\password` prompts.
`exec -T` has no terminal, so psql reads the protected pipe without echo. It
hashes passwords client-side; no plaintext SQL literals or password argv are
used. Output is discarded to avoid exposing DB diagnostics. A failed bootstrap
rolls back. Correct the cause and retry the same bootstrap with the already
generated env file; do not regenerate credentials or switch to recovery when
roles were never committed. Inspect configuration privately rather than
publishing raw errors.
This fresh-bootstrap command changes both dedicated role passwords, so do not
use it for ordinary recovery or an existing installation.

```sh
sudo python3 - <<'PYTHON'
import subprocess
from pathlib import Path
from urllib.parse import urlsplit
values = dict(line.split('=', 1) for line in
              Path('/opt/volta/deploy/ubuntu/.env').read_text().splitlines())
passwords = [urlsplit(values[key]).password for key in
             ['TESLAMATE_DATABASE_URL', 'AUTH_DATABASE_URL']]
result = subprocess.run(
    ['docker', 'compose', '--env-file', '/opt/teslamate-host/ubuntu/.env',
     '-f', '/opt/teslamate-host/ubuntu/compose.yml', 'exec', '-T', 'database',
     'psql', '-X', '-U', 'teslamate', '-d', 'teslamate', '-f', '/tmp/bootstrap.sql'],
    input=''.join(password + '\n' + password + '\n' for password in passwords),
    text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print('Volta bootstrap succeeded' if result.returncode == 0 else 'Volta bootstrap failed')
raise SystemExit(result.returncode)
PYTHON
```

Existing dedicated credentials must be preserved and used with the recovery
procedure below. Interactive `\password` in a private Fleet SSH session remains
an alternative for an explicitly authorized credential setup/rotation.

### Same-cluster recovery

Restore the database using `teslamate-host`'s runbook first. PostgreSQL roles and
their passwords survive a database restore on the same cluster. Prefer
`auth-recover.sql` here: it creates missing auth tables and reapplies auth
grants and privilege assertions, without changing any role, password,
connection limit or timeout. It does not recover lost pairing/device rows;
restore those from the database backup or pair the phone again if absent.
The existing `volta_auth`, `volta_reader` and `volta_readonly` roles must exist;
on a new cluster, use the owning role/bootstrap setup instead.

After copying the five recovery files from the Volta checkout to the same
directory inside the database container:

```sh
fleet exec ubuntu -- 'sudo docker compose --env-file /opt/teslamate-host/ubuntu/.env -f /opt/teslamate-host/ubuntu/compose.yml cp /opt/volta/deploy/auth-recover.sql database:/tmp/auth-recover.sql'
fleet exec ubuntu -- 'sudo docker compose --env-file /opt/teslamate-host/ubuntu/.env -f /opt/teslamate-host/ubuntu/compose.yml cp /opt/volta/deploy/auth-schema.sql database:/tmp/auth-schema.sql'
fleet exec ubuntu -- 'sudo docker compose --env-file /opt/teslamate-host/ubuntu/.env -f /opt/teslamate-host/ubuntu/compose.yml cp /opt/volta/deploy/history-schema.sql database:/tmp/history-schema.sql'
fleet exec ubuntu -- 'sudo docker compose --env-file /opt/teslamate-host/ubuntu/.env -f /opt/teslamate-host/ubuntu/compose.yml cp /opt/volta/deploy/auth-grants.sql database:/tmp/auth-grants.sql'
fleet exec ubuntu -- 'sudo docker compose --env-file /opt/teslamate-host/ubuntu/.env -f /opt/teslamate-host/ubuntu/compose.yml cp /opt/volta/deploy/privilege-checks.sql database:/tmp/privilege-checks.sql'
fleet exec ubuntu -- 'sudo docker compose --env-file /opt/teslamate-host/ubuntu/.env -f /opt/teslamate-host/ubuntu/compose.yml exec -T database psql -X -U teslamate -d teslamate -f /tmp/auth-recover.sql >/dev/null 2>&1'
```

Use the node's verified checkout paths. Do not re-run fresh bootstrap
or rotate existing role passwords for an ordinary same-cluster restore.

## Configure and start the API

The fresh bootstrap above already creates `/opt/volta/deploy/ubuntu/.env`.
For existing installations preserve the root-owned mode 600 file and dedicated
credentials; update only the verified Tailscale address when needed. Password
characters must be URL-encoded; generated hexadecimal passwords need no escaping.

The two connection URLs point to `database:5432/teslamate` on the compose network.
`TAILSCALE_IP` must be ubuntu's actual Tailscale IPv4, never0.0.0.0 or a LAN IP.
No database port is published. The container runs as non-root `bun`, drops all
capabilities, has a read-only root filesystem, and checks `/v1/health` locally.
Docker build context copies only server package/lock/src and installed production
dependencies into the image; it does not copy env files or repository contents.

```sh
fleet exec ubuntu -- 'cd /opt/volta/deploy/ubuntu && sudo docker compose config --quiet && sudo docker compose up -d --build'
fleet exec ubuntu -- 'cd /opt/volta/deploy/ubuntu && sudo docker compose ps'
fleet exec ubuntu -- 'cd /opt/volta/deploy/ubuntu && sudo docker compose exec -T api bun -e "const j = await (await fetch(\"http://127.0.0.1:8080/v1/health\")).json(); console.log(JSON.stringify(j)); process.exit(j.ok ? 0 : 1)"'
```

`config --quiet` validates without printing resolved secrets. Do not paste
`docker inspect`, resolved compose config, connection URLs, or raw DB errors
into public reports. A green container health check proves DB reachability,
not live vehicle collection.

## Sign in with Tesla (optional)

Read-only Tesla account linking from the app uses the commander overlay
`deploy/commander/compose.signin.yaml`, the API overlay `ubuntu/compose.tesla.yml`,
the Cloudflare Worker in `deploy/edge/` and a TeslaMate env fragment. Follow
[Sign in with Tesla](../docs/TESLA_SIGN_IN.md) in order; vehicle data, history
and the database stay private.

## Tailnet HTTPS for iOS ATS

[Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve) only
accepts loopback HTTP targets. Volta's Docker port is bound only to the Tailscale
IP; the supplied systemd socket relay bridges **127.0.0.1:8081** to that IP:8080.
It adds no LAN/public bind, needs no TLS secret, and runs as a dynamic unprivileged
user. Ubuntu must provide `/usr/lib/systemd/systemd-socket-proxyd` (standard
systemd package). Inspect the units before installing; port8081 must be free.

On Ubuntu via Fleet:

```sh
cd /opt/volta
command -v /usr/lib/systemd/systemd-socket-proxyd
sudo install -d -m 0755 /etc/volta
# This file contains only the tailnet IP, no credentials.
tailscale ip -4 | sed 's/^/TAILSCALE_IP=/' | sudo tee /etc/volta/relay.env >/dev/null
sudo install -m 0644 deploy/ubuntu/volta-serve.socket deploy/ubuntu/volta-serve.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now volta-serve.socket
curl --fail http://127.0.0.1:8081/v1/health
```


For reliable reboot startup, install the scoped `volta-api.service` after the API
image is built. It waits for the actual Tailscale address (not just daemon start)
and retries failures; it does not change global Docker ordering or IP sysctls.
On Ubuntu via Fleet, after creating `/etc/volta/relay.env` above:

```sh
cd /opt/volta
sudo install -D -m 0755 deploy/ubuntu/wait-tailnet.sh /usr/local/libexec/volta-wait-tailnet
sed "s|^WorkingDirectory=.*|WorkingDirectory=/opt/volta/deploy/ubuntu|" deploy/ubuntu/volta-api.service | sudo tee /etc/systemd/system/volta-api.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now volta-api.service
sudo systemctl status volta-api.service --no-pager
```

After an authorized reboot, confirm `systemctl is-active volta-api.service`, the
compose container health, relay health, Serve status, and the HTTPS health URL.
Docker may attempt its own container restore before the address appears; this
ordered unit runs `compose up` again after the address is available.

Enable MagicDNS and HTTPS certificates in the tailnet if not already enabled.
Do not use Funnel. Apply tailnet grants/ACLs so only George's intended devices
can reach ubuntu's HTTPS/API ports. Inspect `tailscale serve status` before
changing its configuration. The Ubuntu allocation is HTTPS **9443**/root. Verify port 9443 and its Serve
handler are free before adding it; preserve every existing route. Never reset
Serve or replace another app's mapping. If 9443 is occupied, stop and coordinate
a new allocation. Compare `tailscale serve status --json` before/after and
confirm existing TCP/Web entries and Funnel settings are unchanged.

```sh
fleet exec ubuntu -- 'sudo tailscale serve --bg --https=9443 http://127.0.0.1:8081'
fleet exec ubuntu -- 'tailscale serve status'
```

From a tailnet-connected client, verify the exact HTTPS URL printed by Serve:

```sh
curl --fail 'https://volta-node.example.ts.net:9443/v1/health'
```

The iOS server URL is `https://volta-node.example.ts.net:9443` with no HTTP ATS
exception. The iPhone must run Tailscale on the permitted tailnet. Complete the
pairing flow on the phone and confirm populated status, drives and charging.
Health's `lastDataAt` should advance while TeslaMate is collecting; empty data
or409 `data_unavailable` calls for checking TeslaMate login/recording.

## Pair, list and revoke

```sh
fleet exec ubuntu -- 'cd /opt/volta/deploy/ubuntu && sudo docker compose exec -T api bun run cli pair'
fleet exec ubuntu -- 'cd /opt/volta/deploy/ubuntu && sudo docker compose exec -T api bun run cli devices'
fleet exec ubuntu -- 'cd /opt/volta/deploy/ubuntu && sudo docker compose exec -T api bun run cli revoke 1'
```

The pairing code is a temporary secret; do not publish command output. Give it to
the phone's pairing screen within ten minutes. Device tokens are stored only as
hashes in `volta.devices`; the phone stores its raw token in Keychain. Commands
remain501 `commands_unavailable` in phase1.

## Rollback / stop

Retain the protected env file and `volta` data. Stop only Volta's compose project:

```sh
fleet exec ubuntu -- 'sudo systemctl disable --now volta-api.service; cd /opt/volta/deploy/ubuntu && sudo docker compose stop api'
fleet exec ubuntu -- 'sudo systemctl disable --now volta-serve.socket; sudo systemctl stop volta-serve.service'
```

Remove only the Serve mapping created above after checking its current ownership
(`sudo tailscale serve --https=9443 off` removes only Volta's HTTPS 9443 listener). Do not
reset all Serve configuration. Roll back to the prior reviewed Volta SHA and
rebuild its API image. Never run `down --volumes` against TeslaMate, revoke its
role, or modify its service/network as part of a Volta rollback.

## Verification boundary

The 2026-10-07 fresh bring-up deployed TeslaMate **9b608b3** and Volta backend
**c27aa33** on `ubuntu` (`<tailscale-ip>`), Docker **29.7.2**, Compose **5.5.0**.
The three containers were healthy; TeslaMate published exactly
`127.0.0.1:4000` and PostgreSQL had no host binding. Dedicated role privilege
checks passed. Volta's startup and relay units were active, and its socket and
startup unit were enabled. Relay health and macbook HTTPS health returned 200;
unauthenticated vehicles returned 401 in the error envelope; devices CLI returned
`[]`. Before/after Serve JSON matched exactly except the new TCP/Web 9443 route.
All 14 pre-existing container IDs and running/stopped states were preserved.

Earlier local validation covered strict typecheck, the upstream migration/PG17
dump and restore, and synthetic API/auth/analytics/CLI/role integration tests.
iPhone pairing, permitted-device ACL coverage, reboot recovery and George's
actual TeslaMate collection remain unverified. On a fresh unsigned-in deployment,
leave TeslaMate backup/check timers uninstalled until sign-in and the first
verified backup, as its owning runbook requires. No offsite backup was installed.
