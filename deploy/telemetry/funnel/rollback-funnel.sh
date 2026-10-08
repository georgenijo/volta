#!/usr/bin/env bash
# Removes ONLY the owned :10000 route and verifies every other Serve route
# is unchanged. Dry run unless --apply. Safe to run when already absent.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

apply=0
[[ "${1:-}" == "--apply" ]] && apply=1

state="$(owned_route_state)"
if [[ "$state" == "absent" ]]; then
  echo "owned route :$FUNNEL_PORT already absent"
  exit 0
fi
[[ "$state" == "on" ]] || die ":$FUNNEL_PORT does not match the owned route; not touching it"

before="$(serve_without_owned)"
cmd=(tailscale funnel --tcp="$FUNNEL_PORT" off)
if (( ! apply )); then
  echo "dry run; would run: ${cmd[*]}"
  exit 0
fi
"${cmd[@]}"
# Some versions keep the serve entry after funnel off; remove it too.
if [[ "$(owned_route_state)" != "absent" ]]; then
  tailscale serve --tcp="$FUNNEL_PORT" off
fi
after="$(serve_without_owned)"
[[ "$before" == "$after" ]] || die "other routes differ after rollback; inspect 'tailscale serve status --json'"
[[ "$(owned_route_state)" == "absent" ]] || die ":$FUNNEL_PORT still present"
[[ "$(serve_ports)" == "$EXPECTED_SERVE_PORTS" ]] || die "serve ports are not the expected set"
echo "rolled back: :$FUNNEL_PORT removed; other routes unchanged"
