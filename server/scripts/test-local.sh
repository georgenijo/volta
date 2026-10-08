#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PG_BIN="${PG_BIN:-$(brew --prefix postgresql@17)/bin}"
cluster="$(mktemp -d "${TMPDIR:-/tmp}/volta-test.XXXXXX")"
port="$(python3 - <<'PY'
import socket
with socket.socket() as s:
 s.bind(('127.0.0.1', 0)); print(s.getsockname()[1])
PY
)"
cleanup() {
  "$PG_BIN/pg_ctl" -D "$cluster/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$cluster"
}
trap cleanup EXIT INT TERM
# No persistent service; private socket directory, loopback only, synthetic data.
"$PG_BIN/initdb" -D "$cluster/data" -A trust --no-instructions >"$cluster/init.log"
"$PG_BIN/pg_ctl" -D "$cluster/data" -l "$cluster/postgres.log" -o "-h 127.0.0.1 -p $port -k $cluster" start >/dev/null
"$PG_BIN/createdb" -h 127.0.0.1 -p "$port" volta_test
export TEST_DATABASE_URL="postgres://$(id -un)@127.0.0.1:$port/volta_test"
"$PG_BIN/psql" "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f test/teslamate-v4.3.0.sql >"$cluster/restore.log"
# Run exactly the production bootstrap, omitting only the interactive passwords:
# this isolated cluster uses trust for fixture-only localhost connections.
sed '/^\\password /d' ../deploy/bootstrap.sql > "$cluster/bootstrap.sql"
cp ../deploy/auth-schema.sql ../deploy/history-schema.sql "$cluster/"
cp ../deploy/auth-grants.sql ../deploy/privilege-checks.sql "$cluster/"
"$PG_BIN/psql" "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f "$cluster/bootstrap.sql" >"$cluster/bootstrap.log"
export TESLAMATE_DATABASE_URL="postgres://volta_reader@127.0.0.1:$port/volta_test"
export AUTH_DATABASE_URL="postgres://volta_auth@127.0.0.1:$port/volta_test"
echo "Postgres $($PG_BIN/postgres --version), restored TeslaMate v4.3.0; database=volta_test (isolated loopback cluster)"
bun test
