#!/usr/bin/env bash
# Renews the receiver's server certificate, installs it for uid 65532 with
# mode 0400, and restarts the receiver only when the certificate changed.
# Run as root (systemd timer, see volta-telemetry-cert.timer).
#
# TELEMETRY_CERT_SOURCE (environment, else telemetry.env) selects the issuer:
#   private    A local CA kept in TELEMETRY_CA_DIR (root-only, created on
#              first run) signs a short-lived leaf for TELEMETRY_HOST, the
#              receiver's public name under the Tesla partner domain. The CA
#              is long-lived, so renewals never change the vehicle config.
#   tailscale  `tailscale cert` (Let's Encrypt) for the node's ts.net name.
#              Tesla rejects hostnames outside the partner domain, so this
#              only suits a partner account registered on that name.
#
# The issuing chain must be in the vehicle's fleet_telemetry_config "ca"
# field; commander re-reads $CERT_DIR/ca-chain.pem when building a config.
set -euo pipefail
. "$(dirname "$0")/../node-host.sh"
ENV_FILE="${TELEMETRY_ENV_FILE:-/opt/volta-telemetry/telemetry.env}"
SOURCE="${TELEMETRY_CERT_SOURCE:-$(env_value "$ENV_FILE" TELEMETRY_CERT_SOURCE)}"
SOURCE="${SOURCE:-tailscale}"
HOST="${TELEMETRY_HOST:-$(env_value "$ENV_FILE" TELEMETRY_HOST)}"
case "$SOURCE" in
  tailscale) HOST="${HOST:-$(node_host)}" ;;
  private) ;;
  *) echo "renew-cert: TELEMETRY_CERT_SOURCE must be private or tailscale" >&2; exit 1 ;;
esac
[[ -n $HOST ]] || { echo "renew-cert: set TELEMETRY_HOST (or log in to tailscale for the tailscale source)" >&2; exit 1; }
[[ $HOST =~ ^[A-Za-z0-9.-]+$ ]] || { echo "renew-cert: TELEMETRY_HOST is not a DNS name" >&2; exit 1; }
CERT_DIR="${TELEMETRY_CERT_DIR:-/opt/volta-telemetry/certs}"
CA_DIR="${TELEMETRY_CA_DIR:-/opt/volta-telemetry/private-ca}"
COMPOSE_FILE="${TELEMETRY_COMPOSE_FILE:-/opt/volta/deploy/telemetry/compose.yaml}"
OWNER="${TELEMETRY_CERT_OWNER:-65532}"
GROUP="${TELEMETRY_CERT_GROUP:-65532}"
# Marks an installed certificate the running receiver has not loaded yet; it
# is cleared only after a successful restart (or when the receiver is off).
RESTART_MARK="${TELEMETRY_RESTART_MARK:-$(dirname "$CERT_DIR")/.receiver-restart-pending}"
LEAF_DAYS=90
RENEW_DAYS="${TELEMETRY_RENEW_BEFORE_DAYS:-30}"

# Ownership is set with chown, not install -o/-g: Ubuntu 26.04's install
# (uutils) rejects numeric ids that have no passwd/group entry, like 65532.
install -d -m 0750 "$CERT_DIR"
chown "$(id -u):$GROUP" "$CERT_DIR"
chmod 0750 "$CERT_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The receiver loads the certificate at start. Restart only if it runs, so
# renewal never starts a staged-off stack; a failed restart stays pending and
# fails this run so the next timer run retries it.
finish() {
  if [[ -e $RESTART_MARK ]]; then
    local running
    running="$(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps --status running --services 2>/dev/null)" \
      || { echo "error: cannot read receiver state; restart still pending" >&2; exit 1; }
    if grep -qx receiver <<<"$running"; then
      docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" restart receiver >/dev/null \
        || { echo "error: receiver restart failed; still pending" >&2; exit 1; }
      echo "receiver restarted"
    fi
    rm -f "$RESTART_MARK"
  fi
  exit 0
}

# The installed key belongs to the installed certificate (an interrupted
# install can leave them mismatched).
pair_ok() {
  [[ -s $1 && -s $2 ]] || return 1
  local a b
  a="$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null)" && b="$(openssl pkey -in "$2" -pubout 2>/dev/null)" \
    && [[ -n $a && $a == "$b" ]]
}

names_host() {
  openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed 's/^[[:space:]]*//' | grep -qxF "DNS:$HOST"
}

if [[ $SOURCE == private ]]; then
  install -d -m 0700 "$CA_DIR"
  chmod 0700 "$CA_DIR"
  if [[ ! -s "$CA_DIR/ca.key" ]]; then
    [[ ! -e "$CA_DIR/ca.crt" ]] || { echo "error: $CA_DIR has ca.crt without ca.key" >&2; exit 1; }
    (umask 077; openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/ca.key")
    openssl req -x509 -new -key "$tmp/ca.key" -sha256 -days 3650 -subj "/CN=Volta telemetry receiver CA" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -out "$tmp/ca.crt" 2>/dev/null
    install -m 0600 "$tmp/ca.key" "$CA_DIR/ca.key"
    install -m 0644 "$tmp/ca.crt" "$CA_DIR/ca.crt"
    echo "private CA created; expires $(openssl x509 -in "$CA_DIR/ca.crt" -noout -enddate | cut -d= -f2)"
  fi
  [[ -s "$CA_DIR/ca.crt" ]] || { echo "error: $CA_DIR has ca.key without ca.crt" >&2; exit 1; }
  # The CA must outlive the next leaf; replacing it changes the vehicle
  # config, so that is an operator step (see docs/TELEMETRY_RUNBOOK.md).
  openssl x509 -in "$CA_DIR/ca.crt" -noout -checkend $(( (LEAF_DAYS + 1) * 86400 )) >/dev/null \
    || { echo "error: private CA expires within $((LEAF_DAYS + 1)) days; rotate it" >&2; exit 1; }
  # Keep the installed leaf while it names the host, chains to this CA and
  # has more than RENEW_DAYS left.
  if pair_ok "$CERT_DIR/tls.crt" "$CERT_DIR/tls.key" && cmp -s "$CA_DIR/ca.crt" "$CERT_DIR/ca-chain.pem" \
    && names_host "$CERT_DIR/tls.crt" \
    && openssl verify -CAfile "$CA_DIR/ca.crt" "$CERT_DIR/tls.crt" >/dev/null 2>&1 \
    && openssl x509 -in "$CERT_DIR/tls.crt" -noout -checkend $(( RENEW_DAYS * 86400 )) >/dev/null 2>&1; then
    echo "certificate unchanged"
    finish
  fi
  (umask 077; openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/tls.key")
  openssl req -new -key "$tmp/tls.key" -subj "/CN=$HOST" -out "$tmp/tls.csr" 2>/dev/null
  printf '%s\n' "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" \
    "extendedKeyUsage=serverAuth" "subjectAltName=DNS:$HOST" >"$tmp/ext"
  openssl x509 -req -in "$tmp/tls.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
    -set_serial "0x$(openssl rand -hex 16)" -sha256 -days "$LEAF_DAYS" -extfile "$tmp/ext" -out "$tmp/tls.crt" 2>/dev/null
  cp "$CA_DIR/ca.crt" "$tmp/ca-chain.pem"
else
  tailscale cert --cert-file "$tmp/tls.crt" --key-file "$tmp/tls.key" "$HOST" >/dev/null
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
fi

# Sanity: the leaf names the host, is valid for at least 7 more days and
# verifies against the chain the vehicle will be given.
names_host "$tmp/tls.crt" || { echo "error: certificate does not name the host" >&2; exit 1; }
openssl x509 -in "$tmp/tls.crt" -noout -checkend 604800 >/dev/null
openssl verify -CAfile "$tmp/ca-chain.pem" "$tmp/tls.crt" >/dev/null \
  || { echo "error: certificate does not verify against ca-chain.pem" >&2; exit 1; }

if cmp -s "$tmp/tls.crt" "$CERT_DIR/tls.crt" 2>/dev/null && cmp -s "$tmp/ca-chain.pem" "$CERT_DIR/ca-chain.pem" \
  && pair_ok "$CERT_DIR/tls.crt" "$CERT_DIR/tls.key"; then
  echo "certificate unchanged"
  finish
fi
install -m 0400 "$tmp/tls.key" "$CERT_DIR/tls.key.new"
install -m 0444 "$tmp/tls.crt" "$CERT_DIR/tls.crt.new"
install -m 0444 "$tmp/ca-chain.pem" "$CERT_DIR/ca-chain.pem.new"
chown "$OWNER:$GROUP" "$CERT_DIR/tls.key.new" "$CERT_DIR/tls.crt.new" "$CERT_DIR/ca-chain.pem.new"
touch "$RESTART_MARK"
mv -f "$CERT_DIR/ca-chain.pem.new" "$CERT_DIR/ca-chain.pem"
mv -f "$CERT_DIR/tls.key.new" "$CERT_DIR/tls.key"
mv -f "$CERT_DIR/tls.crt.new" "$CERT_DIR/tls.crt"
echo "certificate installed; expires $(openssl x509 -in "$CERT_DIR/tls.crt" -noout -enddate | cut -d= -f2)"

finish
