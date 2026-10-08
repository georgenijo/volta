#!/bin/sh
# Fail closed until this node's configured Tailscale IPv4 actually exists.
set -eu
expected=${1:?expected Tailscale IPv4 required}
attempt=0
while [ "$attempt" -lt 120 ]; do
  if ip -4 -o addr show dev tailscale0 2>/dev/null | awk -v expected="$expected" '
    { split($4,address,"/"); if (address[1]==expected) found=1 }
    END { exit !found }'; then
    exit 0
  fi
  attempt=$((attempt+1))
  sleep 1
done
echo 'Volta startup: configured Tailscale IP is not assigned; retry later' >&2
exit 1
