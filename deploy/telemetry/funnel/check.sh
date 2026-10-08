#!/usr/bin/env bash
# Read-only. Exit 0 when the Serve config is in a known state: the expected
# ports plus, optionally, the owned route. Prints that state.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh
state="$(owned_route_state)"
ports="$(serve_ports)"
expected="$EXPECTED_SERVE_PORTS"
[[ "$state" == "on" ]] && expected="$(tr ' ' '\n' <<<"$EXPECTED_SERVE_PORTS $FUNNEL_PORT" | sort -n | tr '\n' ' ' | sed 's/ $//')"
echo "owned route :$FUNNEL_PORT: $state"
echo "serve ports: $ports"
[[ "$state" != "foreign" ]] || die ":$FUNNEL_PORT is configured but not as the owned route"
[[ "$ports" == "$expected" ]] || die "serve ports differ from expected '$expected'"
