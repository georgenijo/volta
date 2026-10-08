#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -f /Users/macbook/Applications-staging/.xcode-ready ]]; then
  export DEVELOPER_DIR=/Users/macbook/Applications-staging/Xcode.app/Contents/Developer
fi
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen' >&2; exit 1; }
xcodebuild -version
cd "$repo_dir/ios"
# XcodeGen 2.46 has include enable flags, but no missing-file optional flag.
if [[ -f project.widgets.yml ]]; then export VOLTA_INCLUDE_WIDGETS=true; else export VOLTA_INCLUDE_WIDGETS=false; fi
if [[ -f project.uitests.yml ]]; then export VOLTA_INCLUDE_UITESTS=true; else export VOLTA_INCLUDE_UITESTS=false; fi
xcodegen generate
if [[ -z "${VOLTA_SIMULATOR_ID:-}" ]]; then
  VOLTA_SIMULATOR_ID="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); phones=[v for runtime,values in d["devices"].items() if "iOS" in runtime and any(int(n)>=26 for n in runtime.replace("-",".").split(".") if n.isdigit()) for v in values if v.get("isAvailable") and "iPhone" in v["name"]]; phones.sort(key=lambda v:(v["state"]!="Booted", "iPhone 17 Pro" not in v["name"])); print(phones[0]["udid"] if phones else "")')"
fi
[[ -n "$VOLTA_SIMULATOR_ID" ]] || { echo 'No available iPhone simulator for iOS 26+. Run xcodebuild -downloadPlatform iOS.' >&2; exit 1; }
simulator_state="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; target=sys.argv[1]; devices=[d for values in json.load(sys.stdin)["devices"].values() for d in values if d["udid"] == target]; print(devices[0]["state"] if devices else "")' "$VOLTA_SIMULATOR_ID")"
[[ -n "$simulator_state" ]] || { echo "Simulator $VOLTA_SIMULATOR_ID is unavailable." >&2; exit 1; }
if [[ "$simulator_state" == "Shutdown" ]]; then xcrun simctl boot "$VOLTA_SIMULATOR_ID"; fi
xcrun simctl bootstatus "$VOLTA_SIMULATOR_ID" -b
destination="platform=iOS Simulator,id=$VOLTA_SIMULATOR_ID"
echo "Building and testing on $destination"
xcodebuild -project Volta.xcodeproj -scheme Volta -destination "$destination" -derivedDataPath DerivedData build
xcodebuild -project Volta.xcodeproj -scheme Volta -destination "$destination" -derivedDataPath DerivedData -resultBundlePath "${VOLTA_TEST_RESULTS:-$repo_dir/ios/build/VoltaTests-$(date +%Y%m%d-%H%M%S).xcresult}" test
