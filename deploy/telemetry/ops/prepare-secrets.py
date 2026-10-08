#!/usr/bin/env python3
"""Fresh telemetry setup on ubuntu only; secret values never reach argv/output.

Default is a plan. --apply creates dedicated files exclusively and updates only
the telemetry/budget keys in commander's existing protected env. Existing
telemetry credentials are never rotated. --set-ingest-password feeds the saved
password to psql's hidden prompts after the schema has created the ingest role.
"""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile
from urllib.parse import urlsplit

BASE = Path('/opt/volta-telemetry')
COMMANDER = Path('/opt/volta/deploy/commander/.env')
OPERATOR = Path('/etc/volta/commander-operator.curl')
DB = ['docker', 'compose', '--env-file', '/opt/teslamate-host/ubuntu/.env',
      '-f', '/opt/teslamate-host/ubuntu/compose.yml', 'exec', '-T', 'database',
      'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', 'teslamate', '-d', 'teslamate']


def read_env(path):
    if path.is_symlink() or path.stat().st_mode & 0o077:
        raise ValueError('source must be a protected regular env file')
    values = {}
    for line in path.read_text().splitlines():
        key, sep, raw = line.partition('=')
        if sep and not key.lstrip().startswith('#'):
            raw = raw.strip()
            if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "'\"":
                raw = raw[1:-1]
            values[key.strip()] = raw
    return values


def exclusive(path, content, mode, uid=0, gid=0):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(fd, 'w') as file:
        file.write(content)
        file.flush()
        os.fsync(file.fileno())
    os.chown(path, uid, gid)


def update_env(path, changes):
    lines, seen = [], set()
    for line in path.read_text().splitlines():
        key = line.partition('=')[0].strip()
        if key in changes:
            if key not in seen:
                lines.append(key + '=' + changes[key])
                seen.add(key)
        else:
            lines.append(line)
    lines.extend(key + '=' + value for key, value in changes.items() if key not in seen)
    fd, temp = tempfile.mkstemp(prefix='.telemetry-env-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as file:
            file.write('\n'.join(lines) + '\n')
            file.flush()
            os.fsync(file.fileno())
        os.chmod(temp, 0o600)
        os.chown(temp, 0, 0)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--set-ingest-password', action='store_true')
    args = parser.parse_args()
    if not args.apply and not args.set_ingest_password:
        print('Plan: create telemetry-only secrets on ubuntu; preserve existing commander credentials; set polling budget $5. No changes.')
        return
    if os.geteuid() != 0:
        raise ValueError('run as root on ubuntu')
    if args.set_ingest_password:
        path = BASE / 'secrets/database-url'
        if path.is_symlink() or path.stat().st_mode & 0o077:
            raise ValueError('protected ingest file required')
        password = urlsplit(path.read_text().strip()).password
        if not password or not re.fullmatch('[0-9a-f]{64}', password):
            raise ValueError('saved generated ingest password required')
        # psql without a TTY reads these prompts from stdin without echoing.
        result = subprocess.run(DB + ['-c', '\\password volta_telemetry_ingest'],
                                input=password + '\n' + password + '\n', text=True,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode:
            raise ValueError('ingest password setup failed; preserve saved files and investigate privately')
        print('Saved ingest credential applied; no existing Volta credential changed.')
        return
    env = read_env(COMMANDER)
    mapping = json.loads(env.get('COMMANDER_VEHICLES', '{}'))
    if not mapping or any(not re.fullmatch('[1-9][0-9]*', key) or not isinstance(vin, str)
                          or not re.fullmatch('[A-HJ-NPR-Z0-9]{17}', vin) for key, vin in mapping.items()) \
            or len(set(mapping.values())) != len(mapping):
        raise ValueError('a valid distinct commander vehicle map is required')
    internal = env.get('COMMANDER_INTERNAL_SECRET', '')
    if len(internal) < 32 or any(c in internal for c in '\r\n"\\'):
        raise ValueError('protected commander operator credential is invalid')
    targets = [BASE / 'secrets' / name for name in ['vehicles.json', 'database-url', 'status-secret']]
    targets += [BASE / 'telemetry.env']
    if any(p.exists() or p.is_symlink() for p in targets):
        raise ValueError('telemetry files already exist; preserve them and use the recovery runbook')
    check = subprocess.run(DB + ['-At', '-c', "SELECT EXISTS(SELECT FROM pg_roles WHERE rolname='volta_telemetry_ingest')"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    if check.returncode or check.stdout.strip() != 'f':
        raise ValueError('ingest role already exists or database check failed; refuse fresh credential setup')
    for directory in [BASE, BASE / 'secrets', OPERATOR.parent]:
        if directory.is_symlink():
            raise ValueError('symlink destination refused')
        directory.mkdir(parents=True, exist_ok=True)
    os.chmod(BASE / 'secrets', 0o700)
    os.chown(BASE / 'secrets', 65532, 65532)
    password, status = secrets.token_hex(32), secrets.token_hex(32)
    exclusive(targets[0], json.dumps(mapping) + '\n', 0o400, 65532, 65532)
    exclusive(targets[1], f'postgres://volta_telemetry_ingest:{password}@database:5432/teslamate?sslmode=disable\n', 0o400, 65532, 65532)
    exclusive(targets[2], status + '\n', 0o400, 65532, 65532)
    exclusive(BASE / 'telemetry.env', 'TELEMETRY_CERT_DIR=/opt/volta-telemetry/certs\nTELEMETRY_SECRET_DIR=/opt/volta-telemetry/secrets\nTELEMETRY_RESERVATION_USD=25\nTELEMETRY_WARN_RATIO=0.8\nTELEMETRY_STOP_RATIO=0.92\n', 0o600)
    if not OPERATOR.exists():
        exclusive(OPERATOR, f'header = "Authorization: Bearer {internal}"\n', 0o600)
    elif OPERATOR.is_symlink() or OPERATOR.stat().st_mode & 0o077:
        raise ValueError('existing operator curl config must be protected; preserve and inspect privately')
    update_env(COMMANDER, {'TELEMETRY_STATUS_SECRET_FILE': str(BASE / 'secrets/status-secret'), 'COMMANDER_TELEMETRY_ENABLED': 'true',
                          'COMMANDER_MONTHLY_BUDGET_USD': '5', 'COMMANDER_TELEMETRY_CAP_USD': '25',
                          'COMMANDER_TOTAL_MONTHLY_CAP_USD': '30'})
    print('Telemetry files prepared. Apply schemas and saved ingest password before starting the reviewed stack.')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Never include raw env/JSON/DB errors or secret-bearing arguments.
        raise SystemExit('Telemetry setup refused or incomplete; preserve existing files and inspect privately.')
