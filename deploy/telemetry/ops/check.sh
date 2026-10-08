#!/usr/bin/env bash
# Read-only operator check for the telemetry stack.
#   sudo deploy/telemetry/ops/check.sh
#
# Exit 0 only when every check passes AND the private commander guard is
# enabled with the expected budget. A healthy capture stack with no guard
# exits 2 ("NOT READY"): it is never reported as good for streaming.
# Exit 1 when anything is wrong, including Docker being unreachable or no
# service running.
#
# Prints check names and verdicts only: no VINs, locations, payloads,
# secret contents, addresses or row counts. Secrets are checked for
# presence and mode, never read.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
. "$here/node-host.sh"
ENV_FILE="${TELEMETRY_ENV_FILE:-/opt/volta-telemetry/telemetry.env}"
HOST="${TELEMETRY_HOST:-$(env_value "$ENV_FILE" TELEMETRY_HOST)}"
HOST="${HOST:-$(node_host)}"
[[ -n $HOST ]] || { echo "check: set TELEMETRY_HOST or log in to tailscale" >&2; exit 1; }
BIND="${TELEMETRY_RECEIVER_BIND:-$(env_value "$ENV_FILE" TELEMETRY_RECEIVER_BIND)}"
BIND="${BIND:-127.0.0.1}"
CERT_DIR="${TELEMETRY_CERT_DIR:-/opt/volta-telemetry/certs}"
SECRET_DIR="${TELEMETRY_SECRET_DIR:-/opt/volta-telemetry/secrets}"
DB_CONTAINER="${TELEMETRY_DB_CONTAINER:-teslamate-database-1}"

COMMANDER_CURL_CONFIG="${COMMANDER_CURL_CONFIG:-/etc/volta/commander-operator.curl}"

compose=(docker compose --env-file "$ENV_FILE" -f "$here/compose.yaml")
bad=0
ok()   { printf 'ok    %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; bad=1; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

if ! docker info >/dev/null 2>&1; then
  fail "docker is not reachable"
  echo "RESULT: FAIL"
  exit 1
fi
"${compose[@]}" config -q >/dev/null 2>&1 && ok "compose config valid" || fail "compose config invalid"

# Certificates and secrets: presence and mode only.
for f in tls.crt tls.key ca-chain.pem; do
  [[ -s "$CERT_DIR/$f" ]] || fail "missing certificate file $f"
done
if [[ -s "$CERT_DIR/tls.crt" ]]; then
  openssl x509 -in "$CERT_DIR/tls.crt" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:$HOST" \
    && ok "certificate names the host" || fail "certificate does not name the host"
  openssl x509 -in "$CERT_DIR/tls.crt" -noout -checkend 1209600 >/dev/null 2>&1 \
    && ok "certificate valid > 14 days" || fail "certificate expires within 14 days"
fi
[[ ! -e "$CERT_DIR/tls.key" || "$(mode "$CERT_DIR/tls.key")" == 400 ]] || fail "certificate key mode is not 0400"
for f in vehicles.json database-url status-secret; do
  if [[ ! -s "$SECRET_DIR/$f" ]]; then
    fail "missing secret $f"
  elif [[ "$(mode "$SECRET_DIR/$f")" != 400 ]]; then
    fail "secret $f mode is not 0400"
  fi
done

# Services: each must run and report healthy (the receiver guard, the
# Redpanda cluster health and the consumer's fresh usage evaluation), on
# exactly its own networks.
want_nets() {
  case "$1" in
    receiver) echo "volta-telemetry volta-telemetry-edge" ;;
    redpanda) echo "volta-telemetry" ;;
    consumer) echo "teslamate_default volta-telemetry volta-telemetry-usage" ;;
  esac
}
running=0
for svc in redpanda receiver consumer; do
  id="$("${compose[@]}" ps -q "$svc" 2>/dev/null | head -n1)"
  if [[ -z "$id" ]]; then
    fail "$svc is not running"
    continue
  fi
  running=$((running + 1))
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null)"
  [[ "$health" == healthy ]] && ok "$svc healthy" || fail "$svc is not healthy (${health:-unknown})"
  netmode="$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$id" 2>/dev/null)"
  nets="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$id" 2>/dev/null | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')"
  if [[ "$netmode" == host || "$nets" != "$(want_nets "$svc")" ]]; then
    fail "$svc is on the wrong network"
  else
    ok "$svc networks as deployed"
  fi
done

# Exposure: 8448 on exactly the configured address (loopback by default,
# or one LAN address that a router forwards); never on all interfaces. The
# usage (8449) and liveness (8450) ports are never published on the host.
listeners="$(ss -Hltn 'sport = :8448' 2>/dev/null | awk '{print $4}' | sort -u)"
if ! [[ $BIND =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || [[ $BIND == 0.0.0.0 ]]; then
  fail "receiver bind address is not one IPv4 address"
  listeners=""
elif [[ -z "$listeners" ]]; then
  fail "receiver port 8448 is not listening"
elif [[ "$listeners" != "$BIND:8448" ]]; then
  if grep -Eq '^(0\.0\.0\.0|\*|\[::\]|::):8448$' <<<"$listeners"; then
    fail "8448 listens on all interfaces"
  else
    fail "8448 listens on an unexpected address"
  fi
elif [[ $BIND == 127.0.0.1 ]]; then
  ok "8448 listens on loopback only"
else
  ok "8448 listens on the configured LAN address only"
fi
for p in 8449 8450; do
  [[ -z "$(ss -Hltn "sport = :$p" 2>/dev/null)" ]] && ok "$p not published on the host" || fail "$p is published on the host"
done
if [[ -n "$listeners" ]]; then
  served="$(openssl s_client -connect "$BIND:8448" -servername "$HOST" </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null)"
  grep -q "DNS:$HOST" <<<"$served" && ok "receiver serves the host certificate" || fail "receiver certificate mismatch"
  if curl -sk --max-time 5 -o /dev/null "https://$BIND:8448/" 2>/dev/null; then
    fail "receiver answered a client without a certificate"
  else
    ok "receiver refuses clients without a certificate"
  fi
fi

# Queue configuration.
if "${compose[@]}" ps -q redpanda 2>/dev/null | grep -q .; then
  cfg="$("${compose[@]}" exec -T redpanda rpk topic describe tesla_telemetry_V -c 2>/dev/null)"
  topic_ok=1
  for want in 'retention\.ms[[:space:]]+604800000' 'retention\.bytes[[:space:]]+1073741824' 'cleanup\.policy[[:space:]]+delete' 'write\.caching[[:space:]]+false'; do
    grep -Eq "^${want}([[:space:]]|$)" <<<"$cfg" || topic_ok=0
  done
  (( topic_ok )) && ok "queue topic config as deployed" || fail "queue topic config differs or unreadable"
  "${compose[@]}" exec -T redpanda rpk cluster config get auto_create_topics_enabled 2>/dev/null | grep -qx false \
    && ok "auto topic creation off" || fail "auto topic creation not off"
fi

# Database: reachable, schema applied, role privileges and log hygiene as
# shipped. Booleans only.
psql_q() { docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -XAt -c "$1" 2>/dev/null; }
if [[ "$(psql_q 'SELECT 1')" != 1 ]]; then
  fail "database not reachable"
else
  ok "database reachable"
  [[ "$(psql_q "SELECT to_regclass('volta_telemetry.receipts') IS NOT NULL AND to_regclass('volta_telemetry.stream_health') IS NOT NULL
      AND to_regclass('volta_telemetry.drive_points') IS NOT NULL AND to_regclass('volta_telemetry.power_calibration') IS NOT NULL")" == t ]] \
    && ok "schema applied" || fail "volta_telemetry schema missing or incomplete"
  [[ "$(psql_q "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'volta_telemetry_ingest')
      AND has_table_privilege('volta_telemetry_ingest', 'volta_telemetry.receipts', 'INSERT')
      AND NOT has_table_privilege('volta_telemetry_ingest', 'volta_telemetry.power_calibration', 'INSERT')
      AND NOT has_table_privilege('volta_telemetry_ingest', 'volta_telemetry.power_calibration', 'UPDATE')
      AND CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'volta_readonly')
               THEN NOT has_table_privilege('volta_readonly', 'volta_telemetry.records', 'SELECT') ELSE true END
      AND (SELECT count(*) FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole
           WHERE r.rolname = 'volta_telemetry_ingest'
             AND s.setconfig @> ARRAY['log_error_verbosity=terse', 'log_min_error_statement=panic', 'log_parameter_max_length_on_error=0']) = 1")" == t ]] \
    && ok "role privileges and log settings as shipped" || fail "role privileges or log settings differ"
fi

# Tailscale Serve: the existing ports, plus at most the owned route.
FUNNEL_HOST="$HOST" "$here/funnel/check.sh" >/dev/null 2>&1 && ok "serve ports as expected" || fail "serve ports differ (run funnel/check.sh)"

if (( bad )) || (( running == 0 )); then
  echo "RESULT: FAIL"
  exit 1
fi
guard_ready=0
if [[ -s "$COMMANDER_CURL_CONFIG" && ! -L "$COMMANDER_CURL_CONFIG" && "$(mode "$COMMANDER_CURL_CONFIG")" == 600 ]]; then
  # Credentials are read by curl from a protected file, never process argv.
  status="$(curl --fail --silent --max-time 10 --config "$COMMANDER_CURL_CONFIG" http://127.0.0.1:8090/v1/telemetry/status 2>/dev/null)"
  if python3 -c 'import json,sys; x=json.load(sys.stdin); b=x["budget"]; assert x["enabled"] is True; assert b["warnUsd"]==20 and b["stopUsd"]==23 and b["capUsd"]==25 and b["pollingUsd"]<=5 and b["totalUsd"]<=30' <<<"$status" >/dev/null 2>&1; then
    guard_ready=1
  fi
fi
if (( ! guard_ready )); then
  echo "RESULT: NOT READY - stack healthy, commander budget guard unavailable or misconfigured; streaming must stay off"
  exit 2
fi
echo "RESULT: READY"
exit 0
