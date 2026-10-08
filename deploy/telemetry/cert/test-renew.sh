#!/usr/bin/env bash
# Offline test of renew-cert.sh (both certificate sources) with stubbed
# tailscale and docker CLIs.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
w="$(mktemp -d)"
trap 'rm -rf "$w"' EXIT
mkdir "$w/bin"
cp "$here/testdata/tailscale-stub" "$w/bin/tailscale"
cp "$here/testdata/docker-stub" "$w/bin/docker"
REAL_INSTALL="$(command -v install)"
cp "$here/testdata/install-stub" "$w/bin/install"
export REAL_INSTALL PATH="$w/bin:$PATH" DOCKER_LOG="$w/docker.log" TELEMETRY_CERT_DIR="$w/certs" \
  TELEMETRY_CERT_OWNER="$(id -u)" TELEMETRY_CERT_GROUP="$(id -g)" TELEMETRY_HOST=volta-node.example.ts.net \
  STUB_TRUST_DIR="$w/trust" TELEMETRY_SYSTEM_CERTS="$w/trust" TELEMETRY_ENV_FILE=/dev/null
: >"$DOCKER_LOG"
fail() { echo "FAIL: $*" >&2; exit 1; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

STUB_RUNNING=0 "$here/renew-cert.sh" | grep -q "certificate installed" || fail "first install"
[[ "$(mode "$w/certs/tls.key")" == 400 ]] || fail "key mode $(mode "$w/certs/tls.key")"
[[ "$(mode "$w/certs")" == 750 ]] || fail "cert dir mode $(mode "$w/certs")"
ls "$w/certs" | grep -q '\.new$' && fail "left a staged .new file"
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

# --- private CA source ---------------------------------------------------
# tailscale must never be called: shadow the stub with one that fails.
mkdir "$w/nots"; printf '#!/bin/sh\necho "tailscale called" >&2; exit 9\n' >"$w/nots/tailscale"; chmod +x "$w/nots/tailscale"
pv() { PATH="$w/nots:$PATH" TELEMETRY_CERT_SOURCE=private TELEMETRY_HOST=telemetry.example.com \
  TELEMETRY_CERT_DIR="$w/pcerts" TELEMETRY_CA_DIR="$w/pca" "$here/renew-cert.sh"; }
san() { openssl x509 -in "$1" -noout -ext subjectAltName | grep -o 'DNS:[^,]*' | tr -d ' '; }
: >"$DOCKER_LOG"

out="$(STUB_RUNNING=1 pv)" || fail "private first install"
grep -q "private CA created" <<<"$out" || fail "private CA not created"
grep -q "certificate installed" <<<"$out" || fail "private leaf not installed"
[[ "$(mode "$w/pca")" == 700 ]] || fail "CA dir mode $(mode "$w/pca")"
[[ "$(mode "$w/pca/ca.key")" == 600 ]] || fail "CA key mode $(mode "$w/pca/ca.key")"
[[ ! -e "$w/pcerts/ca.key" ]] || fail "CA key copied into the receiver's cert dir"
[[ "$(mode "$w/pcerts/tls.key")" == 400 ]] || fail "private leaf key mode"
cmp -s "$w/pca/ca.crt" "$w/pcerts/ca-chain.pem" || fail "ca-chain.pem is not the private CA"
[[ "$(san "$w/pcerts/tls.crt")" == "DNS:telemetry.example.com" ]] || fail "leaf SAN $(san "$w/pcerts/tls.crt")"
openssl verify -CAfile "$w/pcerts/ca-chain.pem" "$w/pcerts/tls.crt" >/dev/null || fail "private chain does not verify"
openssl x509 -in "$w/pcerts/tls.crt" -noout -ext extendedKeyUsage | grep -q "TLS Web Server Authentication" || fail "leaf lacks serverAuth"
openssl x509 -in "$w/pca/ca.crt" -noout -checkend $((3000 * 86400)) >/dev/null || fail "CA is not long-lived"
grep -q "restart receiver" "$DOCKER_LOG" || fail "no restart after private install"

# A valid leaf is kept: no reissue, no restart.
: >"$DOCKER_LOG"; leaf="$(cat "$w/pcerts/tls.crt")"; ca="$(cat "$w/pca/ca.crt")"
STUB_RUNNING=1 pv | grep -qx "certificate unchanged" || fail "valid private leaf was reissued"
[[ "$(cat "$w/pcerts/tls.crt")" == "$leaf" ]] || fail "leaf changed without need"
grep -q restart "$DOCKER_LOG" && fail "restarted for an unchanged leaf"

# Inside the renewal window the leaf is reissued from the same CA.
TELEMETRY_RENEW_BEFORE_DAYS=100 STUB_RUNNING=1 pv | grep -q "receiver restarted" || fail "no reissue inside the renewal window"
[[ "$(cat "$w/pcerts/tls.crt")" != "$leaf" ]] || fail "leaf not reissued"
[[ "$(cat "$w/pca/ca.crt")" == "$ca" ]] || fail "renewal replaced the CA"

# A different host (exact match, not a prefix) gets a new leaf.
pv >/dev/null
TELEMETRY_HOST=telemetry.example.com.evil.test PATH="$w/nots:$PATH" TELEMETRY_CERT_SOURCE=private \
  TELEMETRY_CERT_DIR="$w/pcerts" TELEMETRY_CA_DIR="$w/pca" "$here/renew-cert.sh" | grep -q "certificate installed" \
  || fail "host change did not reissue"
pv | grep -q "certificate installed" || fail "SAN prefix match kept a leaf for another host"
[[ "$(san "$w/pcerts/tls.crt")" == "DNS:telemetry.example.com" ]] || fail "wrong host after reissue"

# Settings come from telemetry.env when not in the environment.
printf 'TELEMETRY_CERT_SOURCE=private\nTELEMETRY_HOST="telemetry.example.com"\n' >"$w/telemetry.env"
env -u TELEMETRY_HOST PATH="$w/nots:$PATH" TELEMETRY_ENV_FILE="$w/telemetry.env" TELEMETRY_CERT_DIR="$w/pcerts" TELEMETRY_CA_DIR="$w/pca" \
  "$here/renew-cert.sh" | grep -qx "certificate unchanged" || fail "telemetry.env settings ignored"

# Refusals: missing host, bad host, half a CA, unknown source.
if env -u TELEMETRY_HOST PATH="$w/nots:$PATH" TELEMETRY_CERT_SOURCE=private TELEMETRY_CERT_DIR="$w/pcerts" TELEMETRY_CA_DIR="$w/pca" \
  "$here/renew-cert.sh" >/dev/null 2>&1; then fail "private source accepted no host"; fi
if PATH="$w/nots:$PATH" TELEMETRY_CERT_SOURCE=private TELEMETRY_HOST='bad host;x' TELEMETRY_CERT_DIR="$w/bh" \
  TELEMETRY_CA_DIR="$w/pca" "$here/renew-cert.sh" >/dev/null 2>&1; then fail "accepted a malformed host"; fi
mkdir "$w/halfca"; cp "$w/pca/ca.crt" "$w/halfca/"
if PATH="$w/nots:$PATH" TELEMETRY_CERT_SOURCE=private TELEMETRY_HOST=telemetry.example.com TELEMETRY_CERT_DIR="$w/hc" \
  TELEMETRY_CA_DIR="$w/halfca" "$here/renew-cert.sh" >/dev/null 2>&1; then fail "accepted ca.crt without ca.key"; fi
if TELEMETRY_CERT_SOURCE=acme "$here/renew-cert.sh" >/dev/null 2>&1; then fail "accepted an unknown source"; fi

echo "cert renewal tests: PASS"
