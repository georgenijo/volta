#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
source_root="$repo_root"
label="working"
output="/tmp/volta-load-benchmark/working.json"
output_dir="/tmp/volta-load-benchmark"
samples=5
compare_ref=""
keep_cluster=false
declare -a selected_cases=()

usage() {
  awk '/^# BENCHMARK_USAGE_BEGIN$/{show=1;next} /^# BENCHMARK_USAGE_END$/{exit} show{sub(/^# ?/, ""); print}' "$0"
}

# BENCHMARK_USAGE_BEGIN
# Repeatable synthetic backend load benchmark.
#
# Single source tree:
#   bash server/scripts/benchmark-loads.sh \
#     --source-root /path/to/volta-public --label working \
#     --output /tmp/volta-load-benchmark/working.json
#
# Immutable baseline followed by the working tree, on one database:
#   bash server/scripts/benchmark-loads.sh \
#     --compare-ref ae2193873741fc332a01a7d453ac2ba0c2880cb7 \
#     --output-dir /tmp/volta-load-benchmark
#
# Options:
#   --source-root PATH   Repository root whose server/src implementation is run.
#   --label LABEL        Result label for a single-tree run (default: working).
#   --output FILE        Result JSON for a single-tree run.
#   --compare-ref REF    Archive REF, run it first, then run --source-root.
#   --output-dir DIR     Comparison result directory.
#   --samples N          Measured samples per case after one warmup (default: 5).
#   --case NAME          Run only NAME; repeat for multiple cases.
#   --keep-cluster       Leave the isolated cluster running and write connection.env.
#   --help               Show this help.
# BENCHMARK_USAGE_END

while (($#)); do
  case "$1" in
    --source-root) source_root="$(cd "$2" && pwd)"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --output-dir) output_dir="$2"; shift 2 ;;
    --samples) samples="$2"; shift 2 ;;
    --compare-ref) compare_ref="$2"; shift 2 ;;
    --case) selected_cases+=("$2"); shift 2 ;;
    --keep-cluster) keep_cluster=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! -f "$source_root/server/src/telemetry.ts" ]]; then
  echo "Source root does not contain server/src/telemetry.ts: $source_root" >&2
  exit 2
fi
if [[ ! "$samples" =~ ^[1-9][0-9]*$ ]] || ((samples > 100)); then
  echo "--samples must be an integer from 1 to 100" >&2
  exit 2
fi

if [[ -n "${BUN_BIN:-}" ]]; then
  bun_bin="$BUN_BIN"
elif command -v bun >/dev/null 2>&1; then
  bun_bin="$(command -v bun)"
elif [[ -x "$HOME/.bun/bin/bun" ]]; then
  bun_bin="$HOME/.bun/bin/bun"
else
  echo "Bun is required (set BUN_BIN when it is not on PATH)" >&2
  exit 1
fi

if [[ -n "${PG_BIN:-}" ]]; then
  pg_bin="$PG_BIN"
elif command -v pg_ctl >/dev/null 2>&1; then
  pg_bin="$(dirname "$(command -v pg_ctl)")"
elif command -v brew >/dev/null 2>&1; then
  pg_bin="$(brew --prefix postgresql@17)/bin"
else
  echo "PostgreSQL 17 tools are required (set PG_BIN)" >&2
  exit 1
fi
for tool in initdb pg_ctl createdb psql postgres; do
  if [[ ! -x "$pg_bin/$tool" ]]; then
    echo "Missing PostgreSQL tool: $pg_bin/$tool" >&2
    exit 1
  fi
done

temp_parent="${TMPDIR:-/tmp}"
temp_parent="${temp_parent%/}"
[[ -n "$temp_parent" ]] || temp_parent="/tmp"
cluster="$(mktemp -d "$temp_parent/volta-benchmark.XXXXXX")"
port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
)"
stopped=false
cleanup() {
  if [[ "$keep_cluster" == true ]]; then
    return
  fi
  if [[ "$stopped" != true ]]; then
    "$pg_bin/pg_ctl" -D "$cluster/data" -m immediate stop >/dev/null 2>&1 || true
    stopped=true
  fi
  case "$cluster" in
    "$temp_parent"/volta-benchmark.*) rm -rf -- "$cluster" ;;
    *) echo "Refusing to remove unexpected cluster path: $cluster" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM

mkdir -p "$output_dir" "$(dirname "$output")"
"$pg_bin/initdb" -D "$cluster/data" -A trust --no-instructions >"$cluster/init.log"
"$pg_bin/pg_ctl" -D "$cluster/data" -l "$cluster/postgres.log" \
  -o "-h 127.0.0.1 -p $port -k $cluster -c fsync=off -c full_page_writes=off" start >/dev/null
"$pg_bin/createdb" -h 127.0.0.1 -p "$port" volta_benchmark

export TEST_DATABASE_URL="postgres://$(id -un)@127.0.0.1:$port/volta_benchmark"
export TESLAMATE_DATABASE_URL="postgres://volta_reader@127.0.0.1:$port/volta_benchmark"
export AUTH_DATABASE_URL="postgres://volta_auth@127.0.0.1:$port/volta_benchmark"

baseline_root=""
schema_root="$source_root"
if [[ -n "$compare_ref" ]]; then
  baseline_revision="$(git -C "$repo_root" rev-parse --verify "$compare_ref^{commit}")"
  baseline_root="$cluster/source-baseline"
  mkdir -p "$baseline_root"
  git -C "$repo_root" archive "$baseline_revision" | tar -xf - -C "$baseline_root"
  if [[ ! -d "$repo_root/server/node_modules" ]]; then
    echo "server/node_modules is required for archived baseline imports; run bun install in server/" >&2
    exit 1
  fi
  ln -s "$repo_root/server/node_modules" "$baseline_root/server/node_modules"
  schema_root="$baseline_root"
fi

# Restore the upstream TeslaMate schema and apply the production bootstrap and
# Fleet Telemetry SQL from the selected schema root. The synthetic fixture is
# owned by this benchmark and is identical for both implementations.
"$pg_bin/psql" "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f "$schema_root/server/test/teslamate-v4.3.0.sql" >"$cluster/restore.log"
sed '/^\\password /d' "$schema_root/deploy/bootstrap.sql" >"$cluster/bootstrap.sql"
cp "$schema_root/deploy/auth-schema.sql" "$schema_root/deploy/history-schema.sql" \
  "$schema_root/deploy/service-schema.sql" "$schema_root/deploy/auth-grants.sql" \
  "$schema_root/deploy/privilege-checks.sql" "$cluster/"
"$pg_bin/psql" "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f "$cluster/bootstrap.sql" >"$cluster/bootstrap.log"
for migration in 001_volta_telemetry.sql 002_api_series.sql 003_service_odometer.sql; do
  "$pg_bin/psql" "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 \
    -f "$schema_root/deploy/telemetry/sql/$migration" >>"$cluster/telemetry.log"
done

vin_digest="c9462b93da9abc8f69717e20b235632d45849e8bf40817b1e6856a4165915c2d"
"$pg_bin/psql" "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -v vin_digest="$vin_digest" \
  -f "$repo_root/server/test/load-benchmark-fixtures.sql" >"$cluster/fixture.log"

declare -a case_args=()
for case_name in ${selected_cases[@]+"${selected_cases[@]}"}; do
  case_args+=(--case "$case_name")
done

run_one() {
  local root="$1" run_label="$2" revision="$3" result_file="$4"
  "$bun_bin" "$repo_root/server/scripts/benchmark-loads.ts" \
    --source-root "$root" --label "$run_label" --revision "$revision" \
    --samples "$samples" --output "$result_file" ${case_args[@]+"${case_args[@]}"}
}

if [[ -n "$compare_ref" ]]; then
  baseline_file="$output_dir/baseline.json"
  working_file="$output_dir/working.json"
  comparison_file="$output_dir/comparison.json"
  run_one "$baseline_root" baseline "$baseline_revision" "$baseline_file"
  working_revision="$(git -C "$source_root" rev-parse HEAD 2>/dev/null || echo working-tree)+working-tree"
  run_one "$source_root" working "$working_revision" "$working_file"
  "$bun_bin" "$repo_root/server/scripts/benchmark-loads.ts" \
    --compare "$baseline_file" "$working_file" --output "$comparison_file"
else
  revision="$(git -C "$source_root" rev-parse HEAD 2>/dev/null || echo working-tree)+working-tree"
  run_one "$source_root" "$label" "$revision" "$output"
fi

if [[ "$keep_cluster" == true ]]; then
  connection_file="$output_dir/connection.json"
  connection_env="$output_dir/connection.env"
  connection_baseline_root="${baseline_root:-$source_root}"
  umask 077
  python3 - "$connection_file" "$TESLAMATE_DATABASE_URL" "$AUTH_DATABASE_URL" \
    "$connection_baseline_root" "$source_root" "$pg_bin" "$cluster/data" "$port" <<'PY'
import json
import sys

path, reader_url, auth_url, baseline_root, working_root, pg_bin, pg_data, port = sys.argv[1:]
with open(path, 'w') as handle:
    json.dump({
        'readerURL': reader_url,
        'authURL': auth_url,
        'baselineRoot': baseline_root,
        'workingRoot': working_root,
        'pgBin': pg_bin,
        'pgData': pg_data,
        'port': int(port),
    }, handle, indent=2)
    handle.write('\n')
PY
  {
    printf 'CONNECTION_JSON=%q\n' "$connection_file"
    printf 'READER_URL=%q\n' "$TESLAMATE_DATABASE_URL"
    printf 'AUTH_URL=%q\n' "$AUTH_DATABASE_URL"
    printf 'BASELINE_ROOT=%q\n' "$connection_baseline_root"
    printf 'WORKING_ROOT=%q\n' "$source_root"
    printf 'PG_BIN=%q\n' "$pg_bin"
    printf 'PGDATA=%q\n' "$cluster/data"
    printf 'PGPORT=%q\n' "$port"
  } >"$connection_env"
  echo "Synthetic cluster retained; connection metadata: $connection_file and $connection_env"
else
  echo "Synthetic cluster will be stopped and removed: $cluster"
fi
