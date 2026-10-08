#!/usr/bin/env bash
# Runs the offline acceptance suite on a Docker host. Expects a bundle
# produced by remote-acceptance.sh (or run from a repo checkout with Go):
#   <bundle>/acceptance.test   go test -c -tags acceptance ./acceptance
#   <bundle>/deploy/telemetry  this directory
#   <bundle>/ingestion         source for the consumer and guarded receiver
#                              images (ingestion/Dockerfile targets)
# Owns only resources named volta-telemetry-test-*; removes them on exit.
set -euo pipefail
bundle="$(cd "${1:-$(dirname "$0")/../../..}" && pwd)"
image=volta-telemetry-test-consumer:local
receiver_image=volta-telemetry-test-receiver:local

cleanup() {
  ids="$(docker ps -aq --filter 'name=^/volta-telemetry-test-')"
  [[ -n "$ids" ]] && docker rm -f -v $ids >/dev/null
  docker network rm volta-telemetry-test-net >/dev/null 2>&1 || true
  docker volume rm volta-telemetry-test-redpanda-data >/dev/null 2>&1 || true
  docker image rm "$image" "$receiver_image" >/dev/null 2>&1 || true
  # Test PKI/config dirs left by an interrupted run (fake material only).
  find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'volta-telemetry-test-[0-9]*' -user "$(id -u)" -exec rm -rf {} + 2>/dev/null || true
}
trap cleanup EXIT
cleanup

docker build -q --target consumer -t "$image" "$bundle/ingestion" >/dev/null
docker build -q --target receiver -t "$receiver_image" "$bundle/ingestion" >/dev/null
bin="$bundle/acceptance.test"
if [[ ! -x "$bin" ]]; then
  (cd "$bundle/ingestion" && CGO_ENABLED=0 go test -c -tags acceptance -o "$bin" ./acceptance)
fi
cd "$bundle/ingestion/acceptance"
VT_DEPLOY_DIR="$bundle/deploy/telemetry" VT_CONSUMER_IMAGE="$image" VT_RECEIVER_IMAGE="$receiver_image" \
VT_POSTGRES_IMAGE="postgres:17@sha256:2d2b8998d31037bf721cfdf764d76ba74171b4fab3431b7f72c27c56ddbdf9e3" \
  "$bin" -test.v -test.timeout 20m
