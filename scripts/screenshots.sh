#!/usr/bin/env bash
# Run the synthetic demo UI suite and export its named screenshot attachments.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

usage() {
  cat <<'EOF'
Usage: scripts/screenshots.sh [--skip-build | --print-destination | --export-only RESULT.xcresult]

Default: generate the Xcode project, run VoltaUITests, and export named PNGs.
--skip-build: reuse VoltaCI build-for-testing products (used by GitHub Actions).
--print-destination: print an available iOS 26+ iPhone destination and exit.
--export-only: export an existing result without building or running tests.

Environment overrides:
  DEVELOPER_DIR        Xcode 26.x Contents/Developer path
  IOS_DESTINATION     full xcodebuild simulator destination
  SIMULATOR_UDID      specific simulator UUID (otherwise select automatically)
  DERIVED_DATA_PATH   default ios/DerivedData
  RESULT_BUNDLE_PATH  default build/screenshots.xcresult; must not already exist
  SCREENSHOTS_DIR     default docs/screens/latest (replaced by this run's export)
EOF
}

select_destination() {
  if [[ -n "${IOS_DESTINATION:-}" ]]; then
    printf '%s\n' "$IOS_DESTINATION"
  elif [[ -n "${SIMULATOR_UDID:-}" ]]; then
    printf 'platform=iOS Simulator,id=%s\n' "$SIMULATOR_UDID"
  else
    xcrun simctl list devices available --json | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
candidates = []
for runtime, entries in devices.items():
    match = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
    if not match or int(match[1]) < 26:
        continue
    version = tuple(int(n or 0) for n in match.groups())
    for device in entries:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            candidates.append((version, device["name"] == "iPhone 17 Pro", device["name"], device["udid"]))
if not candidates:
    sys.exit("No available iOS 26+ iPhone simulator. Install an iOS runtime in Xcode or set IOS_DESTINATION.")
version, _, name, udid = max(candidates)
print(f"Selected {name}, iOS {version[0]}.{version[1]}, UUID {udid}", file=sys.stderr)
print("platform=iOS Simulator,id=" + udid)
'
  fi
}

mode=run
skip_build=false
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --print-destination) [[ $# == 1 ]] || { usage >&2; exit 2; }; select_destination; exit 0 ;;
  --skip-build) skip_build=true; [[ $# == 1 ]] || { usage >&2; exit 2; } ;;
  --export-only) [[ $# == 2 ]] || { usage >&2; exit 2; }; mode='export'; result_bundle=$2 ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac

screenshots_dir=${SCREENSHOTS_DIR:-"$repo_root/docs/screens/latest"}
test_status=0
if [[ "$mode" == run ]]; then
  result_bundle=${RESULT_BUNDLE_PATH:-"$repo_root/build/screenshots.xcresult"}
  derived_data=${DERIVED_DATA_PATH:-"$repo_root/ios/DerivedData"}
  if [[ -e "$result_bundle" ]]; then
    echo "Result already exists: $result_bundle. Set RESULT_BUNDLE_PATH to a fresh path." >&2
    exit 2
  fi
  [[ -f ios/project.yml ]] || { echo 'Missing ios/project.yml; integrate feat/ios-frame and include project.uitests.yml first.' >&2; exit 2; }
  destination=$(select_destination)
  echo "Screenshot destination: $destination" >&2
  mkdir -p "$(dirname "$result_bundle")" build
  action='test'
  if [[ "$skip_build" == true ]]; then
    action=test-without-building
  else
    if [[ -f ios/project.widgets.yml ]]; then export VOLTA_INCLUDE_WIDGETS=true; else export VOLTA_INCLUDE_WIDGETS=false; fi
    export VOLTA_INCLUDE_UITESTS=true
    xcodegen generate --spec ios/project.yml
  fi
  set +e
  xcodebuild "$action" -project ios/Volta.xcodeproj -scheme VoltaCI \
    -destination "$destination" -destination-timeout 60 -derivedDataPath "$derived_data" \
    -only-testing:VoltaUITests -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
    -resultBundlePath "$result_bundle" COMPILATION_CACHE_ENABLE_CACHING=YES 2>&1 | tee build/screenshots.log
  test_status=${PIPESTATUS[0]}
  set -e
fi

if [[ ! -d "$result_bundle" ]]; then
  echo "No result bundle to export: $result_bundle" >&2
  [[ "$test_status" != 0 ]] || test_status=1
  exit "$test_status"
fi
export_dir=$(mktemp -d "${TMPDIR:-/tmp}/volta-attachments.XXXXXX")
trap 'rm -rf "$export_dir"' EXIT
xcrun xcresulttool export attachments --path "$result_bundle" --output-path "$export_dir"

# xcresulttool exports UUID filenames plus manifest.json. Preserve the attachment
# names set by XCTest, so screenshots line up with the reference screenshot names rather than UUIDs.
python3 - "$export_dir" "$screenshots_dir" "$test_status" "$mode" <<'PY'
import json
import pathlib
import re
import shutil
import sys

source, output = map(pathlib.Path, sys.argv[1:3])
manifest_path = source / "manifest.json"
if not manifest_path.exists():
    sys.exit("xcresulttool exported no manifest.json")
manifest = json.loads(manifest_path.read_text())
screens = []
def visit(value):
    if isinstance(value, dict):
        filename = value.get("exportedFileName")
        name = value.get("suggestedHumanReadableName")
        if filename and name and pathlib.Path(filename).suffix.lower() == ".png":
            # Xcode may append an extension to the human-readable attachment name.
            stem = re.sub(r"\.png$", "", name, flags=re.IGNORECASE)
            stem = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", stem)
            stem = re.sub(r"[^A-Za-z0-9._-]+", "-", stem).strip(".-")
            attachment = (source / filename).resolve()
            if attachment.parent != source.resolve() or not attachment.is_file():
                sys.exit("Invalid screenshot export path in manifest")
            screens.append((stem or "screenshot", attachment))
        for child in value.values():
            visit(child)
    elif isinstance(value, list):
        for child in value:
            visit(child)
visit(manifest)
if not screens:
    sys.exit("No PNG screenshot attachments in result; UI capture did not run")
# Replace only the PNGs owned by the prior capture, never unrelated files.
output.mkdir(parents=True, exist_ok=True)
index_path = output / "screenshots.json"
if index_path.exists():
    previous = json.loads(index_path.read_text())
    for filename in previous.get("files", []):
        if pathlib.Path(filename).name == filename and filename.endswith(".png"):
            (output / filename).unlink(missing_ok=True)
counts = {}
files = []
for stem, attachment in screens:
    counts[stem] = counts.get(stem, 0) + 1
    suffix = "" if counts[stem] == 1 else f"-{counts[stem]}"
    filename = f"{stem}{suffix}.png"
    shutil.copyfile(attachment, output / filename)
    files.append(filename)
shutil.copyfile(manifest_path, output / "manifest.json")
index_path.write_text(json.dumps({
    "testExitCode": int(sys.argv[3]) if sys.argv[4] == "run" else None,
    "mode": sys.argv[4],
    "files": files,
}, indent=2) + "\n")
print(f"Exported {len(files)} screenshots to {output}")
PY

# Export partial screenshots on failure, but never convert failed UI tests to green.
exit "$test_status"
