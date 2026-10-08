#!/usr/bin/env bash
# Renews the receiver's server certificate with `tailscale cert` (Let's
# Encrypt, public trust) for the Funnel hostname, installs it for uid 65532
# with mode 0400, and restarts the receiver only when the certificate
# changed. Run as root (systemd timer, see volta-telemetry-cert.timer).
#
# The same chain must be in the vehicle's fleet_telemetry_config "ca" field;
# Let's Encrypt intermediates rotate, so commander re-reads
# $CERT_DIR/ca-chain.pem when building a config (see docs).
set -euo pipefail
. "$(dirname "$0")/../node-host.sh"
HOST="${TELEMETRY_HOST:-$(node_host)}"
[[ -n $HOST ]] || { echo "renew-cert: set TELEMETRY_HOST or log in to tailscale" >&2; exit 1; }
CERT_DIR="${TELEMETRY_CERT_DIR:-/opt/volta-telemetry/certs}"
COMPOSE_FILE="${TELEMETRY_COMPOSE_FILE:-/opt/volta/deploy/telemetry/compose.yaml}"
ENV_FILE="${TELEMETRY_ENV_FILE:-/opt/volta-telemetry/telemetry.env}"
OWNER="${TELEMETRY_CERT_OWNER:-65532}"
GROUP="${TELEMETRY_CERT_GROUP:-65532}"

# Ownership is set with chown, not install -o/-g: Ubuntu 26.04's install
# (uutils) rejects numeric ids that have no passwd/group entry, like 65532.
install -d -m 0750 "$CERT_DIR"
chown "$(id -u):$GROUP" "$CERT_DIR"
chmod 0750 "$CERT_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tailscale cert --cert-file "$tmp/tls.crt" --key-file "$tmp/tls.key" "$HOST" >/dev/null

# Sanity: the leaf names the host and is valid for at least 7 more days.
openssl x509 -in "$tmp/tls.crt" -noout -ext subjectAltName | grep -q "DNS:$HOST"
openssl x509 -in "$tmp/tls.crt" -noout -checkend 604800 >/dev/null
# Chain minus the leaf, completed with its self-signed root from the system
# trust store, for the vehicle config's "ca" field (the car needs an anchor).
awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++} n>1' "$tmp/tls.crt" >"$tmp/ca-chain.pem"
[[ -s "$tmp/ca-chain.pem" ]] || { echo "error: tailscale cert returned no intermediate" >&2; exit 1; }
awk -v d="$tmp" '/BEGIN CERTIFICATE/{n++} {print > (d "/chain-" n ".pem")}' "$tmp/ca-chain.pem"
top="$(ls "$tmp"/chain-*.pem | sort -t- -k2 -n | tail -1)"
if [[ "$(openssl x509 -in "$top" -noout -subject_hash)" != "$(openssl x509 -in "$top" -noout -issuer_hash)" ]]; then
  root="${TELEMETRY_SYSTEM_CERTS:-/etc/ssl/certs}/$(openssl x509 -in "$top" -noout -issuer_hash).0"
  [[ -s "$root" ]] || { echo "error: issuing root not in the system trust store" >&2; exit 1; }
  openssl x509 -in "$root" >>"$tmp/ca-chain.pem"
fi
openssl verify -CAfile "$tmp/ca-chain.pem" "$tmp/tls.crt" >/dev/null \
  || { echo "error: certificate does not verify against ca-chain.pem" >&2; exit 1; }

if cmp -s "$tmp/tls.crt" "$CERT_DIR/tls.crt" 2>/dev/null; then
  echo "certificate unchanged"
  exit 0
fi
install -m 0400 "$tmp/tls.key" "$CERT_DIR/tls.key.new"
install -m 0444 "$tmp/tls.crt" "$CERT_DIR/tls.crt.new"
install -m 0444 "$tmp/ca-chain.pem" "$CERT_DIR/ca-chain.pem.new"
chown "$OWNER:$GROUP" "$CERT_DIR/tls.key.new" "$CERT_DIR/tls.crt.new" "$CERT_DIR/ca-chain.pem.new"
mv -f "$CERT_DIR/ca-chain.pem.new" "$CERT_DIR/ca-chain.pem"
mv -f "$CERT_DIR/tls.key.new" "$CERT_DIR/tls.key"
mv -f "$CERT_DIR/tls.crt.new" "$CERT_DIR/tls.crt"
echo "certificate installed; expires $(openssl x509 -in "$CERT_DIR/tls.crt" -noout -enddate | cut -d= -f2)"

# The receiver loads the certificate at start. Restart only if it runs, so
# renewal never starts a staged-off stack.
if docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps --status running --services 2>/dev/null | grep -qx receiver; then
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" restart receiver >/dev/null
  echo "receiver restarted"
fi
