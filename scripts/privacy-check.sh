#!/usr/bin/env bash
# Fails when the public repo would receive personal data.
#   privacy-check.sh            scan the index (the next commit; in CI it equals HEAD)
#   privacy-check.sh <commit>   scan that commit's tree (used by the pre-push hook)
#   privacy-check.sh --stdin    scan text such as raw commit or tag objects
# Generic patterns run everywhere, CI included. Exact private strings come from a
# denylist kept outside the repo: $VOLTA_PRIVATE_DENYLIST, default
# ~/.config/volta/private-denylist (one fixed string per line, # comments).
# Binary files are searched too, and every image, video, archive or database must
# be listed by blob hash in scripts/privacy-allowed-binaries.txt after review.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
status=0
fail() { echo "privacy-check: $*" >&2; status=1; }

if [[ ${1:-} == --stdin ]]; then
  text=$(cat)
  scan() { printf '%s\n' "$text" | grep -a "$@"; }
  blobs() { :; }
  allowed() { :; }
elif [[ $# -gt 0 ]]; then
  rev=$(git rev-parse --verify "$1^{commit}")
  scan() { git grep -a "$@" "$rev" -- .; }
  blobs() { git ls-tree -r "$rev" | awk '{ sub(/^[^ ]+ [^ ]+ /, ""); print }'; }
  # Pins are content hashes, so the current list also covers older commits.
  allowed() { { git show "$rev:scripts/privacy-allowed-binaries.txt"; git show ':scripts/privacy-allowed-binaries.txt'; } 2>/dev/null || true; }
else
  scan() { git grep -a --cached "$@" -- .; }
  blobs() { git ls-files -s | awk '{ sub(/^[^ ]+ /, ""); sub(/ [0-9]+\t/, "\t"); print }'; }
  allowed() { git show ':scripts/privacy-allowed-binaries.txt' 2>/dev/null || true; }
fi

# Real tailnet hostnames look like <host>.tail<hex>.ts.net; use example.ts.net.
if scan -n -E '\.tail[0-9a-f]{4,}\.ts\.net'; then fail 'real tailnet hostname'; fi
# Tailscale addresses (100.64.0.0/10) other than the 100.64.0.0/24 test range.
# Whole digit-and-dot tokens are extracted without consuming separators, so
# adjacent addresses are each validated on their own.
if scan -n -o -E '[0-9.]*100\.[0-9]+\.[0-9]+\.[0-9]+[0-9.]*' | awk '{
    tok = $0; sub(/.*:/, "", tok)
    if (split(tok, o, ".") != 4) next
    for (i = 1; i <= 4; i++) if (o[i] !~ /^[0-9]+$/ || length(o[i]) > 3 || o[i] + 0 > 255) next
    if (o[1] == 100 && o[2] >= 64 && o[2] <= 127 && !(o[2] == 64 && o[3] == 0)) { print; bad = 1 }
  } END { exit !bad }'; then fail 'tailscale IP'; fi
# The signing team belongs in the untracked ios/Config/Signing.local.xcconfig.
if scan -n -E "DEVELOPMENT_TEAM[\"']? *[:=] *[\"']?[A-Z0-9]{10}(\$|[^A-Z0-9])" \
  | grep -v -E '(^|:)ios/Config/Signing\.local\.xcconfig\.example:'; then
  fail 'hard-coded DEVELOPMENT_TEAM'
fi
# Screenshots and other media stay private unless reviewed and pinned by hash.
media='\.(png|jpe?g|gif|heic|heif|webp|tiff?|bmp|ico|icns|mov|mp4|m4v|pdf|zip|ipa|sqlite3?|db|car)$'
if blobs | grep -iE "$media" | awk -F'\t' '{ print $1 " " $2 }' \
  | grep -vxF -f <(allowed | grep -v -e '^#' -e '^$'; echo '#'); then
  fail 'unreviewed binary asset (review it, then pin "<blob> <path>" in scripts/privacy-allowed-binaries.txt)'
fi

denylist=${VOLTA_PRIVATE_DENYLIST:-$HOME/.config/volta/private-denylist}
if [[ -f $denylist ]]; then
  patterns=$(grep -v -e '^#' -e '^$' "$denylist" || true)
  if [[ -n $patterns ]] && scan -n -i -F -f <(printf '%s\n' "$patterns"); then fail "string listed in $denylist"; fi
elif [[ -z ${CI:-} ]]; then
  echo "privacy-check: no denylist at $denylist; ran generic checks only" >&2
fi
exit "$status"
