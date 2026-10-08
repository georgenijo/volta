#!/usr/bin/env bash
# Stages the ONLY public route for Fleet Telemetry: raw TCP Funnel
# :10000 -> 127.0.0.1:8448. TLS is not terminated by Tailscale; the
# receiver does mutual TLS itself. Dry run unless --apply.
#
# Preconditions checked here: the existing Serve ports are exactly the
# expected set, :10000 is free, the receiver answers on loopback with a
# certificate for the Funnel host. Postcondition: the other routes are
# unchanged (normalized JSON equality) and :10000 is the expected forward.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

apply=0
[[ "${1:-}" == "--apply" ]] && apply=1

state="$(owned_route_state)"
case "$state" in
  on) echo "route already staged: :$FUNNEL_PORT -> $FUNNEL_TARGET"; exit 0 ;;
  foreign) die ":$FUNNEL_PORT is configured differently; inspect manually" ;;
esac
ports="$(serve_ports)"
[[ "$ports" == "$EXPECTED_SERVE_PORTS" ]] \
  || die "serve ports are '$ports', expected '$EXPECTED_SERVE_PORTS'; refusing"

# The receiver must already serve the Funnel hostname's certificate.
if [[ "${FUNNEL_TEST_SKIP_CERT_PROBE:-}" != "1" ]]; then
subject="$(openssl s_client -connect 127.0.0.1:8448 -servername "$FUNNEL_HOST" </dev/null 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName 2>/dev/null || true)"
grep -q "DNS:$FUNNEL_HOST" <<<"$subject" \
  || die "receiver on 127.0.0.1:8448 is not serving a certificate for $FUNNEL_HOST"
fi

before="$(serve_without_owned)"
cmd=(tailscale funnel --bg --yes --tcp "$FUNNEL_PORT" "$FUNNEL_TARGET")
if (( ! apply )); then
  echo "dry run; would run: ${cmd[*]}"
  exit 0
fi
"${cmd[@]}"
after="$(serve_without_owned)"
if [[ "$before" != "$after" ]]; then
  echo "other routes changed; rolling back the owned route" >&2
  ./rollback-funnel.sh --apply || true
  die "staging aborted"
fi
[[ "$(owned_route_state)" == "on" ]] || die ":$FUNNEL_PORT not in the expected state after staging"
echo "staged: $FUNNEL_HOST:$FUNNEL_PORT -> $FUNNEL_TARGET (raw TCP, Funnel on)"
