#!/usr/bin/env bash
# Offline test of renew-cert.sh with stubbed tailscale and docker CLIs.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
w="$(mktemp -d)"
trap 'rm -rf "$w"' EXIT
mkdir "$w/bin"
cp "$here/testdata/tailscale-stub" "$w/bin/tailscale"
cp "$here/testdata/docker-stub" "$w/bin/docker"
export PATH="$w/bin:$PATH" DOCKER_LOG="$w/docker.log" TELEMETRY_CERT_DIR="$w/certs" \
  TELEMETRY_CERT_OWNER="$(id -u)" TELEMETRY_CERT_GROUP="$(id -g)" TELEMETRY_HOST=volta-node.example.ts.net \
  STUB_TRUST_DIR="$w/trust" TELEMETRY_SYSTEM_CERTS="$w/trust"
: >"$DOCKER_LOG"
fail() { echo "FAIL: $*" >&2; exit 1; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

STUB_RUNNING=0 "$here/renew-cert.sh" | grep -q "certificate installed" || fail "first install"
[[ "$(mode "$w/certs/tls.key")" == 400 ]] || fail "key mode $(mode "$w/certs/tls.key")"
[[ "$(grep -c BEGIN "$w/certs/ca-chain.pem")" == 2 ]] || fail "ca-chain should hold intermediate + root"
openssl verify -CAfile "$w/certs/ca-chain.pem" "$w/certs/tls.crt" >/dev/null || fail "chain does not verify the leaf"
grep -q restart "$DOCKER_LOG" && fail "restarted a receiver that was not running"

# Each stub run issues a new certificate, so this counts as a change.
STUB_RUNNING=1 "$here/renew-cert.sh" | grep -q "receiver restarted" || fail "no restart after change"
grep -q "restart receiver" "$DOCKER_LOG" || fail "restart not issued"

# A certificate that expires within 7 days is refused and nothing changes.
before="$(cat "$w/certs/tls.crt")"
if STUB_DAYS=3 "$here/renew-cert.sh" >/dev/null 2>&1; then fail "accepted a nearly expired certificate"; fi
[[ "$(cat "$w/certs/tls.crt")" == "$before" ]] || fail "installed a rejected certificate"

# Without the issuing root in the trust store the chain is incomplete: refuse.
before="$(cat "$w/certs/ca-chain.pem")"
if TELEMETRY_SYSTEM_CERTS="$w/empty" "$here/renew-cert.sh" >/dev/null 2>&1; then fail "accepted a chain without its root"; fi
[[ "$(cat "$w/certs/ca-chain.pem")" == "$before" ]] || fail "installed an incomplete chain"

echo "cert renewal tests: PASS"
