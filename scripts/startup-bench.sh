#!/usr/bin/env bash
# Run StartupBenchmarkTests/testDashboardReadiness against the synthetic
# fixture on one dedicated simulator while recording the app's `startup` log
# milestones, then print per-launch timings. See docs/STARTUP.md.
#
# usage: scripts/startup-bench.sh <simulator-id> <derived-data> <profile> <out-dir> [ca-cert]
set -euo pipefail
sim=$1 derived=$2 profile=$3 out=$4 ca=${5:-/tmp/localhost.crt}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"
curl -fsS --cacert "$ca" https://127.0.0.1:9443/__benchmark/profile \
  -H 'Content-Type: application/json' -d "{\"profile\":\"$profile\"}" >/dev/null
xcrun simctl spawn "$sim" log stream --style ndjson --level info \
  --predicate 'subsystem == "com.georgenijo.volta" AND category == "startup"' \
  >"$out/milestones.ndjson" 2>/dev/null &
logger=$!
trap 'kill $logger 2>/dev/null || true' EXIT
sleep 2
rm -rf "$out/readiness.xcresult"
TEST_RUNNER_VOLTA_STARTUP_BENCHMARK=1 xcodebuild test-without-building \
  -project "$root/ios/Volta.xcodeproj" -scheme VoltaCI -configuration Release \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$derived" \
  -parallel-testing-enabled NO \
  -only-testing:VoltaUITests/StartupBenchmarkTests/testDashboardReadiness \
  -resultBundlePath "$out/readiness.xcresult" >"$out/xcodebuild.log" 2>&1
sleep 2
kill $logger 2>/dev/null || true
rm -rf "$out/attachments"
xcrun xcresulttool export attachments --path "$out/readiness.xcresult" --output-path "$out/attachments" >/dev/null
python3 "$root/scripts/startup-report.py" "$out"
