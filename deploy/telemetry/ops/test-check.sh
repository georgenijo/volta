#!/usr/bin/env bash
# Offline test of ops/check.sh against stubbed docker, ss, openssl, curl and
# tailscale. Never touches a real daemon, socket or tailnet.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tele="$(cd "$here/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/certs" "$work/secrets"
cp "$tele/funnel/testdata/tailscale-stub" "$work/bin/tailscale"

cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
# docker test double, driven by STUB_* variables.
svc_of() { echo "${1#id-}"; }
case "$1" in
  info) [[ -z "${STUB_DOCKER_DOWN:-}" ]]; exit ;;
  compose)
    shift
    while (($#)); do
      case "$1" in
        --env-file|-f) shift 2 ;;
        config) exit 0 ;;
        ps)
          shift; [[ "$1" == -q ]] || exit 2
          for s in ${STUB_RUNNING-redpanda receiver consumer}; do [[ "$s" == "$2" ]] && echo "id-$s"; done
          exit 0 ;;
        exec)
          if [[ "$*" == *"topic describe"* ]]; then
            printf 'cleanup.policy                       delete\nretention.bytes                      1073741824\nretention.ms                         604800000\nwrite.caching                        false\n'
          elif [[ "$*" == *auto_create_topics_enabled* ]]; then
            echo false
          fi
          exit 0 ;;
        *) shift ;;
      esac
    done
    exit 2 ;;
  inspect)
    fmt="$3"; s="$(svc_of "$4")"
    case "$fmt" in
      *Health*)
        if [[ " ${STUB_UNHEALTHY:-} " == *" $s "* ]]; then echo unhealthy; else echo healthy; fi ;;
      *NetworkMode*)
        v="STUB_NETMODE_$s"; echo "${!v:-volta-telemetry}" ;;
      *Networks*)
        v="STUB_NETS_$s"
        case "$s" in
          receiver) d="volta-telemetry-edge volta-telemetry" ;;
          redpanda) d="volta-telemetry" ;;
          consumer) d="volta-telemetry teslamate_default volta-telemetry-usage" ;;
        esac
        echo "${!v:-$d} " ;;
    esac
    exit 0 ;;
  exec)
    [[ "${STUB_DB:-ok}" != down ]] || exit 2
    sql="${!#}"
    if [[ "$sql" == "SELECT 1" ]]; then echo 1
    elif [[ "$sql" == *to_regclass* ]]; then [[ "${STUB_DB:-ok}" == noschema ]] && echo f || echo t
    elif [[ "$sql" == *has_table_privilege* ]]; then [[ "${STUB_DB:-ok}" == badperm ]] && echo f || echo t
    fi
    exit 0 ;;
esac
echo "docker stub: unsupported $*" >&2
exit 2
STUB

cat >"$work/bin/ss" <<'STUB'
#!/usr/bin/env bash
# ss test double: -Hltn 'sport = :PORT'
port="${2##*:}"
v="STUB_LISTEN_$port"
val=""; [[ "$port" == 8448 ]] && val="127.0.0.1:8448"
if declare -p "$v" >/dev/null 2>&1; then val="${!v}"; fi
for a in $val; do echo "LISTEN 0 4096 $a 0.0.0.0:*"; done
STUB

cat >"$work/bin/openssl" <<'STUB'
#!/usr/bin/env bash
host="${TELEMETRY_HOST:-volta-node.example.ts.net}"
case "$1" in
  s_client) echo SERVED ;;
  x509)
    if [[ "$*" == *-checkend* ]]; then exit 0; fi
    if [[ "$*" != *" -in "* ]] && ! grep -q SERVED; then exit 1; fi
    echo "X509v3 Subject Alternative Name:"; echo "    DNS:$host" ;;
esac
STUB

cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *'/v1/telemetry/status'* ]]; then
  [[ -z "${STUB_GUARD_DOWN:-}" ]] || exit 7
  echo "${STUB_GUARD_STATUS:-{\"enabled\":true,\"budget\":{\"warnUsd\":20,\"stopUsd\":23,\"capUsd\":25,\"pollingUsd\":5,\"totalUsd\":30}}}"
else
  exit "${STUB_CURL_EXIT:-35}"
fi
STUB
chmod +x "$work/bin/"*

export TELEMETRY_HOST=volta-node.example.ts.net PATH="$work/bin:$PATH" TS_STATE="$work/serve.json" TS_LOG="$work/ts.log" \
  TELEMETRY_CERT_DIR="$work/certs" TELEMETRY_SECRET_DIR="$work/secrets" TELEMETRY_ENV_FILE=/dev/null COMMANDER_CURL_CONFIG="$work/operator.curl"
fail() { echo "FAIL: $*" >&2; exit 1; }

reset() {
  unset STUB_DOCKER_DOWN STUB_RUNNING STUB_UNHEALTHY STUB_NETMODE_receiver STUB_NETS_receiver STUB_DB \
    STUB_LISTEN_8448 STUB_LISTEN_8449 STUB_LISTEN_8450 STUB_CURL_EXIT STUB_GUARD_DOWN STUB_GUARD_STATUS
  cp "$tele/funnel/testdata/serve-baseline.json" "$TS_STATE"; : >"$TS_LOG"
  chmod -R u+w "$work/certs" "$work/secrets"; rm -f "$work/certs/"* "$work/secrets/"*
  for f in tls.crt ca-chain.pem; do echo cert >"$work/certs/$f"; done
  echo key >"$work/certs/tls.key"; chmod 400 "$work/certs/tls.key"
  for f in vehicles.json database-url status-secret; do
    echo "CANARY-SECRET-$f" >"$work/secrets/$f"; chmod 400 "$work/secrets/$f"
  done
  echo 'CANARY-OPERATOR-SECRET' >"$COMMANDER_CURL_CONFIG"; chmod 600 "$COMMANDER_CURL_CONFIG"
}

# expect CODE PATTERN: run check, require exit CODE and a line matching
# PATTERN, and that nothing secret or address-like is printed.
expect() {
  local want="$1" pat="$2" out code
  set +e; out="$("$here/check.sh" 2>&1)"; code=$?; set -e
  [[ "$code" == "$want" ]] || { printf '%s\n' "$out" >&2; fail "case '$case': exit $code, want $want"; }
  grep -Eq -- "$pat" <<<"$out" || { printf '%s\n' "$out" >&2; fail "case '$case': no line matching '$pat'"; }
  if grep -Eq 'CANARY|192\.168\.|0\.0\.0\.0|127\.0\.0\.1|100\.64\.|DNS:' <<<"$out"; then
    printf '%s\n' "$out" >&2; fail "case '$case': printed a value"
  fi
  if [[ "$want" != 0 ]] && grep -q 'RESULT: READY' <<<"$out"; then fail "case '$case': reported READY"; fi
}

case=healthy-guard-enabled; reset
expect 0 '^RESULT: READY'

case=guard-unavailable; reset; export STUB_GUARD_DOWN=1
expect 2 '^RESULT: NOT READY .*commander budget guard unavailable'

case=guard-wrong-budget; reset; export STUB_GUARD_STATUS='{"enabled":true,"budget":{"warnUsd":20,"stopUsd":23,"capUsd":25,"pollingUsd":10,"totalUsd":30}}'
expect 2 '^RESULT: NOT READY .*commander budget guard unavailable'

case=operator-config-insecure; reset; chmod 644 "$COMMANDER_CURL_CONFIG"
expect 2 '^RESULT: NOT READY .*commander budget guard unavailable'

case=docker-down; reset; export STUB_DOCKER_DOWN=1
expect 1 '^FAIL  docker is not reachable'

case=none-running; reset; export STUB_RUNNING=""
expect 1 '^FAIL  consumer is not running'

case=partial; reset; export STUB_RUNNING="redpanda receiver"
expect 1 '^FAIL  consumer is not running'

case=unhealthy; reset; export STUB_UNHEALTHY="consumer"
expect 1 '^FAIL  consumer is not healthy'

case=wrong-network-extra; reset; export STUB_NETS_receiver="volta-telemetry volta-telemetry-edge teslamate_default"
expect 1 '^FAIL  receiver is on the wrong network'

case=wrong-network-host; reset; export STUB_NETMODE_receiver=host
expect 1 '^FAIL  receiver is on the wrong network'

case=wildcard-listener; reset; export STUB_LISTEN_8448="0.0.0.0:8448"
expect 1 '^FAIL  8448 listens on all interfaces'

case=private-address; reset; export STUB_LISTEN_8448="127.0.0.1:8448 192.168.1.20:8448"
expect 1 '^FAIL  8448 listens on a non-loopback address'

case=receiver-down; reset; export STUB_LISTEN_8448=""
expect 1 '^FAIL  receiver port 8448 is not listening'

case=usage-published; reset; export STUB_LISTEN_8449="127.0.0.1:8449"
expect 1 '^FAIL  8449 is published on the host'

case=no-client-cert-accepted; reset; export STUB_CURL_EXIT=0
expect 1 '^FAIL  receiver answered a client without a certificate'

case=missing-secret; reset; rm -f "$work/secrets/status-secret"
expect 1 '^FAIL  missing secret status-secret'

case=secret-mode; reset; chmod 644 "$work/secrets/database-url"
expect 1 '^FAIL  secret database-url mode is not 0400'

case=missing-cert; reset; rm -f "$work/certs/ca-chain.pem"
expect 1 '^FAIL  missing certificate file ca-chain.pem'

case=db-down; reset; export STUB_DB=down
expect 1 '^FAIL  database not reachable'

case=no-schema; reset; export STUB_DB=noschema
expect 1 '^FAIL  volta_telemetry schema missing'

case=bad-permissions; reset; export STUB_DB=badperm
expect 1 '^FAIL  role privileges or log settings differ'

case=serve-drift; reset
python3 - "$TS_STATE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["TCP"]["8448"] = {"HTTPS": True}; json.dump(d, open(sys.argv[1], "w"))
PY
expect 1 '^FAIL  serve ports differ'

echo "check script tests: PASS"
