#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PG_BIN="${PG_BIN:-$(brew --prefix postgresql@17)/bin}"
clusters=()
cleanup() {
  for cluster in "${clusters[@]}"; do
    "$PG_BIN/pg_ctl" -D "$cluster/data" -m immediate stop >/dev/null 2>&1 || true
    rm -rf "$cluster"
  done
}
trap cleanup EXIT INT TERM
free_port() {
  python3 - <<'PY'
import socket
with socket.socket() as s:
 s.bind(('127.0.0.1', 0)); print(s.getsockname()[1])
PY
}
# start_cluster DIR PORT: one restored, bootstrapped volta_test database.
start_cluster() {
  local cluster=$1 port=$2 url="postgres://$(id -un)@127.0.0.1:$2/volta_test"
  # No persistent service; private socket directory, loopback only, synthetic data.
  # The cluster is deleted on exit, so crash safety buys nothing: skip fsync and
  # full-page writes. Memory settings stay at defaults so query timings stay comparable.
  local durability="-c fsync=off -c synchronous_commit=off -c full_page_writes=off"
  "$PG_BIN/initdb" -D "$cluster/data" -A trust --no-instructions >"$cluster/init.log"
  "$PG_BIN/pg_ctl" -D "$cluster/data" -l "$cluster/postgres.log" -o "-h 127.0.0.1 -p $port -k $cluster $durability" start >/dev/null
  "$PG_BIN/createdb" -h 127.0.0.1 -p "$port" volta_test
  "$PG_BIN/psql" "$url" -v ON_ERROR_STOP=1 -f test/teslamate-v4.3.0.sql >"$cluster/restore.log"
  # Run exactly the production bootstrap, omitting only the interactive passwords:
  # this isolated cluster uses trust for fixture-only localhost connections.
  sed '/^\\password /d' ../deploy/bootstrap.sql > "$cluster/bootstrap.sql"
  cp ../deploy/auth-schema.sql ../deploy/history-schema.sql ../deploy/service-schema.sql "$cluster/"
  cp ../deploy/auth-grants.sql ../deploy/privilege-checks.sql "$cluster/"
  "$PG_BIN/psql" "$url" -v ON_ERROR_STOP=1 -f "$cluster/bootstrap.sql" >"$cluster/bootstrap.log"
  "$PG_BIN/psql" "$url" -v ON_ERROR_STOP=1 -f ../deploy/telemetry/sql/001_volta_telemetry.sql >"$cluster/telemetry.log"
  "$PG_BIN/psql" "$url" -v ON_ERROR_STOP=1 -f ../deploy/telemetry/sql/002_api_series.sql >>"$cluster/telemetry.log"
  "$PG_BIN/psql" "$url" -v ON_ERROR_STOP=1 -f ../deploy/telemetry/sql/003_service_odometer.sql >>"$cluster/telemetry.log"
}
# run_on_cluster DIR PORT FILES...: bun test with that cluster's three role URLs.
run_on_cluster() {
  local cluster=$1 port=$2; shift 2
  TEST_DATABASE_URL="postgres://$(id -un)@127.0.0.1:$port/volta_test" \
  TESLAMATE_DATABASE_URL="postgres://volta_reader@127.0.0.1:$port/volta_test" \
  AUTH_DATABASE_URL="postgres://volta_auth@127.0.0.1:$port/volta_test" \
    bun test "$@"
}
new_cluster() { mktemp -d "${TMPDIR:-/tmp}/volta-test.XXXXXX"; }

if [[ $# -gt 0 ]]; then
  # Explicit files or bun test flags: one cluster, as before.
  cluster=$(new_cluster); clusters+=("$cluster"); port=$(free_port)
  start_cluster "$cluster" "$port"
  echo "Postgres $($PG_BIN/postgres --version), restored TeslaMate v4.3.0; database=volta_test (isolated loopback cluster)"
  run_on_cluster "$cluster" "$port" "$@"
  exit
fi

# Full suite: the files share one database and truncate it, and api.test.ts
# also changes cluster-wide roles, so they cannot share a cluster in parallel.
# api.test.ts (the 1.7M-row scale fixture) takes about half the time, so it
# gets its own cluster and the other files run on a second one at the same time.
heavy=(./test/api.test.ts)
rest=()
for file in ./test/*.test.ts; do [[ " ${heavy[*]} " == *" $file "* ]] || rest+=("$file"); done
a=$(new_cluster); b=$(new_cluster); clusters+=("$a" "$b")
port_a=$(free_port); port_b=$(free_port)
while [[ "$port_b" == "$port_a" ]]; do port_b=$(free_port); done
start_cluster "$a" "$port_a" & start_a=$!
start_cluster "$b" "$port_b" & start_b=$!
wait "$start_a"; wait "$start_b"
echo "Postgres $($PG_BIN/postgres --version), restored TeslaMate v4.3.0; database=volta_test (two isolated loopback clusters)"
run_on_cluster "$a" "$port_a" "${heavy[@]}" >"$a/bun.log" 2>&1 & run_a=$!
run_on_cluster "$b" "$port_b" "${rest[@]}" >"$b/bun.log" 2>&1 & run_b=$!
status=0
wait "$run_b" || status=1
cat "$b/bun.log"
wait "$run_a" || status=1
cat "$a/bun.log"
exit "$status"
