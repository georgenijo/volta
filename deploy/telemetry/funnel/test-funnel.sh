#!/usr/bin/env bash
# Offline test of stage/rollback/check against a stubbed tailscale CLI.
# Never invokes the real tailscale binary.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cp "$here/testdata/tailscale-stub" "$work/bin/tailscale"
export FUNNEL_HOST=volta-node.example.ts.net PATH="$work/bin:$PATH" TS_STATE="$work/state.json" TS_LOG="$work/log" FUNNEL_TEST_SKIP_CERT_PROBE=1
fail() { echo "FAIL: $*" >&2; exit 1; }
reset() { cp "$here/testdata/serve-baseline.json" "$TS_STATE"; : >"$TS_LOG"; }
canon() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$1"; }
base="$(canon "$here/testdata/serve-baseline.json")"

reset
"$here/check.sh" >/dev/null || fail "check on baseline"
"$here/stage-funnel.sh" | grep -q "dry run" || fail "stage default is not a dry run"
[[ "$(canon "$TS_STATE")" == "$base" ]] || fail "dry run mutated state"
grep -q '^funnel' "$TS_LOG" && fail "dry run called funnel"

"$here/stage-funnel.sh" --apply >/dev/null || fail "stage apply"
python3 - "$TS_STATE" <<'PY' || fail "staged state wrong"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["TCP"]["10000"] == {"TCPForward": "127.0.0.1:8448"}, d["TCP"]["10000"]
assert d["AllowFunnel"] == {"volta-node.example.ts.net:10000": True}
PY
grep -q -- '--tls-terminated-tcp' "$TS_LOG" && fail "used TLS termination"
"$here/check.sh" | grep -q "owned route :10000: on" || fail "check after stage"
"$here/stage-funnel.sh" --apply | grep -q "already staged" || fail "stage not idempotent"

"$here/rollback-funnel.sh" | grep -q "dry run" || fail "rollback default is not a dry run"
"$here/rollback-funnel.sh" --apply >/dev/null || fail "rollback apply"
[[ "$(canon "$TS_STATE")" == "$base" ]] || fail "rollback did not restore baseline exactly"
"$here/rollback-funnel.sh" --apply | grep -q "already absent" || fail "rollback not idempotent"

# A version where funnel off also drops the TCP entry.
reset
"$here/stage-funnel.sh" --apply >/dev/null
TS_FUNNEL_OFF_REMOVES_TCP=1 "$here/rollback-funnel.sh" --apply >/dev/null || fail "rollback (variant)"
[[ "$(canon "$TS_STATE")" == "$base" ]] || fail "variant rollback differs"

# Refuses when the baseline is not the expected port set.
reset
python3 - "$TS_STATE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["TCP"]["8448"] = {"HTTPS": True}; json.dump(d, open(sys.argv[1], "w"))
PY
if "$here/stage-funnel.sh" --apply 2>/dev/null; then fail "staged over unexpected ports"; fi

# Refuses to touch a foreign :10000.
reset
python3 - "$TS_STATE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["TCP"]["10000"] = {"TCPForward": "127.0.0.1:9999"}; json.dump(d, open(sys.argv[1], "w"))
PY
before="$(canon "$TS_STATE")"
if "$here/stage-funnel.sh" --apply 2>/dev/null; then fail "staged over foreign route"; fi
if "$here/rollback-funnel.sh" --apply 2>/dev/null; then fail "rolled back foreign route"; fi
[[ "$(canon "$TS_STATE")" == "$before" ]] || fail "foreign route modified"
# TLS-terminated variant also counts as foreign.
reset
python3 - "$TS_STATE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["TCP"]["10000"] = {"TCPForward": "127.0.0.1:8448", "TerminateTLS": "volta-node.example.ts.net"}
d["AllowFunnel"] = {"volta-node.example.ts.net:10000": True}; json.dump(d, open(sys.argv[1], "w"))
PY
if "$here/check.sh" >/dev/null 2>&1; then fail "check accepted TLS-terminated route"; fi
echo "funnel script tests: PASS"
