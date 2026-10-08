#!/bin/sh
# Never print key contents or overwrite keys paired with a vehicle.
set -eu
umask 077
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 /absolute/private/key-directory" >&2
  exit 2
fi
case "$1" in /*) ;; *) echo "Use an absolute directory outside a Git checkout" >&2; exit 2 ;; esac
mkdir -p "$1"
dest=$(cd "$1" && pwd -P)
if git -C "$dest" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "Refusing to generate private keys inside a Git checkout" >&2
  exit 2
fi
for name in fleet-key.pem public-key.pem tls-key.pem tls-cert.pem; do
  if [ -e "$dest/$name" ]; then
    echo "Refusing to overwrite existing key material" >&2
    exit 2
  fi
done
tmp=$(mktemp -d "$dest/.keygen.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/fleet-key.pem"
openssl ec -in "$tmp/fleet-key.pem" -pubout -out "$tmp/public-key.pem" 2>/dev/null
# TLS key is distinct from Tesla's command-signing key. The leaf certificate is
# explicitly trusted by commander and contains only loopback subject names.
openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 365 \
  -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,DNS:tesla-command-proxy,IP:127.0.0.1,IP:::1' \
  -keyout "$tmp/tls-key.pem" -out "$tmp/tls-cert.pem" 2>/dev/null
for name in fleet-key.pem public-key.pem tls-key.pem tls-cert.pem; do
  mv "$tmp/$name" "$dest/$name"
done
chmod 600 "$dest/fleet-key.pem" "$dest/tls-key.pem"
chmod 644 "$dest/public-key.pem" "$dest/tls-cert.pem"
echo "Created signing key, public export and private proxy TLS certificate."
echo "Publish ONLY public-key.pem at /.well-known/appspecific/com.tesla.3p.public-key.pem"
