#!/usr/bin/env bash
# Fails when the public repo would receive personal data. With no argument it
# scans the index (what the next commit contains; in CI the index equals HEAD).
# With a commit argument it scans that commit's tree (used by the pre-push hook).
# Generic patterns run everywhere, CI included. Exact private strings come from a
# denylist kept outside the repo: $VOLTA_PRIVATE_DENYLIST, default
# ~/.config/volta/private-denylist (one fixed string per line, # comments).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
status=0
fail() { echo "privacy-check: $*" >&2; status=1; }

if [[ $# -gt 0 ]]; then
  rev=$(git rev-parse --verify "$1^{commit}")
  scan() { git grep -I "$@" "$rev" -- .; }
  files() { git ls-tree -r --name-only "$rev"; }
else
  scan() { git grep -I --cached "$@" -- .; }
  files() { git ls-files; }
fi

# Real tailnet hostnames look like <host>.tail<hex>.ts.net; use example.ts.net.
if scan -n -E '\.tail[0-9a-f]{4,}\.ts\.net'; then fail 'real tailnet hostname'; fi
# Tailscale addresses (100.64.0.0/10) other than the 100.64.0.0/24 test range.
# Each address is checked on its own so an allowed one cannot mask another.
if scan -n -o -E '(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}($|[^0-9])' \
  | grep -v -E ':[^0-9]?100\.64\.0\.[0-9]{1,3}[^0-9]?$'; then fail 'tailscale IP'; fi
# The signing team belongs in the untracked ios/Config/Signing.local.xcconfig.
if scan -n -E "DEVELOPMENT_TEAM[\"']? *[:=] *[\"']?[A-Z0-9]{10}(\$|[^A-Z0-9])" \
  | grep -v -E '(^|:)ios/Config/Signing\.local\.xcconfig\.example:'; then
  fail 'hard-coded DEVELOPMENT_TEAM'
fi
# Device and reference screenshots stay in the private repo.
if files | grep -E '^docs/(reference|screens)/'; then fail 'screenshots belong in the private repo'; fi

denylist=${VOLTA_PRIVATE_DENYLIST:-$HOME/.config/volta/private-denylist}
if [[ -f $denylist ]]; then
  patterns=$(grep -v -e '^#' -e '^$' "$denylist" || true)
  if [[ -n $patterns ]] && scan -n -i -F -f <(printf '%s\n' "$patterns"); then fail "string listed in $denylist"; fi
elif [[ -z ${CI:-} ]]; then
  echo "privacy-check: no denylist at $denylist; ran generic checks only" >&2
fi
exit "$status"
