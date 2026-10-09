#!/bin/sh
# Volta.xcodeproj is ignored; generate it before Xcode Cloud's Archive action.
set -eu

: "${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud must supply the repository path}"
: "${CI_BUILD_NUMBER:?Xcode Cloud must supply the build number}"
: "${CI_TEAM_ID:?Xcode Cloud must supply the selected Apple development team}"
case "$CI_BUILD_NUMBER" in
    *[!0-9]* | 0* | '')
        echo 'CI_BUILD_NUMBER must be a positive integer without leading zeros.' >&2
        exit 1
        ;;
esac
case "$CI_TEAM_ID" in
    *[!A-Z0-9]*)
        echo 'CI_TEAM_ID must contain ten uppercase letters or digits.' >&2
        exit 1
        ;;
esac
if [ "${#CI_TEAM_ID}" -ne 10 ]; then
    echo 'CI_TEAM_ID must contain ten uppercase letters or digits.' >&2
    exit 1
fi

cd "$CI_PRIMARY_REPOSITORY_PATH/ios"
# AppSide supplies types used by the app; a widget-less Cloud build is invalid.
test -f project.widgets.yml
export VOLTA_INCLUDE_WIDGETS=true
export VOLTA_INCLUDE_UITESTS=false

# Pin XcodeGen while preserving ios-build.sh's existing include-flag contract.
# Prebuilt releases avoid the Homebrew DNS failure seen by HomeOS on Cloud.
xcodegen_version=2.46.0
xcodegen_sha256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/volta-xcodegen.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
curl --fail --location --silent --show-error --retry 3 \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$xcodegen_version/xcodegen.zip" \
    --output "$work_dir/xcodegen.zip"
printf '%s  %s\n' "$xcodegen_sha256" "$work_dir/xcodegen.zip" | shasum -a 256 -c -
unzip -q "$work_dir/xcodegen.zip" -d "$work_dir"
xcodegen_bin="$work_dir/xcodegen/bin/xcodegen"
chmod +x "$xcodegen_bin"
"$xcodegen_bin" --version

# Apply the selected Cloud team and one build number to the app and extension.
# Keep the checked-in local default at 1; no signing file or source edits needed.
cat > "$work_dir/cloud.yml" <<EOF
include:
  - path: '$PWD/project.yml'
settings:
  base:
    DEVELOPMENT_TEAM: '$CI_TEAM_ID'
    CURRENT_PROJECT_VERSION: '$CI_BUILD_NUMBER'
EOF
"$xcodegen_bin" generate --spec "$work_dir/cloud.yml" --project-root "$PWD" --project "$PWD"
test -f Volta.xcodeproj/xcshareddata/xcschemes/Volta.xcscheme
