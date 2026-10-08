#!/usr/bin/env bash
# From a dev machine: cross-compile the acceptance binary, ship a bundle to
# a Fleet Docker node, run it there, and remove the bundle.
#   deploy/telemetry/test/remote-acceptance.sh [node]   (default: ubuntu)
set -euo pipefail
node="${1:-ubuntu}"
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
b="$stage/volta-telemetry-test-bundle"
mkdir -p "$b/deploy"
(cd "$repo/ingestion" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go test -c -tags acceptance -o "$b/acceptance.test" ./acceptance)
cp -R "$repo/deploy/telemetry" "$b/deploy/telemetry"
rsync -a --exclude '*.test' "$repo/ingestion/" "$b/ingestion/"
remote=/tmp/volta-telemetry-test-bundle
fleet exec "$node" -- rm -rf "$remote"
fleet cp -r "$b" "$node:/tmp/" >/dev/null
status=0
fleet exec --timeout 1800 "$node" -- bash "$remote/deploy/telemetry/test/run-acceptance.sh" "$remote" || status=$?
fleet exec "$node" -- rm -rf "$remote"
exit "$status"
