#!/usr/bin/env bash
# Fails when the public repo would receive personal data.
#   privacy-check.sh            scan the index (the next commit; in CI it equals HEAD)
#   privacy-check.sh <commit>   scan that commit's tree (used by the pre-push hook)
#   privacy-check.sh --stdin    scan text such as raw commit or tag objects
# Generic patterns run everywhere, CI included. Exact private strings come from a
# denylist kept outside the repo: $VOLTA_PRIVATE_DENYLIST, default
# ~/.config/volta/private-denylist (one fixed string per line, # comments).
# File contents (binary included) and file paths are both searched, and every
# image, video, archive or database must be listed by blob hash in
# scripts/privacy-allowed-binaries.txt after review.
# Exit status: 0 clean, 1 private data found, 2 the scan itself failed.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
status=0
fail() { echo "privacy-check: $*" >&2; status=1; }
die() { echo "privacy-check: $*; refusing to pass" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Tree entries as NUL-terminated "<meta>\t<path>" records, written to $tmp/entries.
if [[ ${1:-} == --stdin ]]; then
  cat >"$tmp/text" || die 'cannot read stdin'
  content() { grep -a "$@" "$tmp/text"; }
  : >"$tmp/entries"
  blob_field=0
elif [[ $# -gt 0 ]]; then
  rev=$(git rev-parse --verify "$1^{commit}") || die "not a commit: $1"
  content() { git grep -a "$@" "$rev" -- .; }
  git ls-tree -r -z "$rev" >"$tmp/entries" || die "cannot list $rev"
  blob_field=3 # <mode> <type> <blob>
else
  content() { git grep -a --cached "$@" -- .; }
  git ls-files -s -z >"$tmp/entries" || die 'cannot list the index'
  blob_field=2 # <mode> <blob> <stage>
fi

# Paths are checked as text too. A path with a newline or other control
# character cannot be reviewed or pinned reliably, so it fails outright.
: >"$tmp/paths"
: >"$tmp/media"
media='\.(png|jpe?g|gif|heic|heif|webp|tiff?|bmp|ico|icns|mov|mp4|m4v|pdf|zip|ipa|sqlite3?|db|car)$'
shopt -s nocasematch
while IFS= read -r -d '' rec; do
  path=${rec#*$'\t'}
  if [[ $path == *[[:cntrl:]]* ]]; then fail 'path contains a control character'; continue; fi
  printf '%s\n' "$path" >>"$tmp/paths"
  if [[ $path =~ $media ]]; then
    read -r -a meta <<<"${rec%%$'\t'*}"
    printf '%s %s\n' "${meta[blob_field - 1]}" "$path" >>"$tmp/media"
  fi
done <"$tmp/entries"
shopt -u nocasematch

# hits <grep args...>: matches go to $tmp/hits. Returns 0 on a match, 1 on none,
# and stops the whole check on any search error rather than passing silently.
# (Commands in an if condition are exempt from set -e, so this must be explicit.)
target=content
hits() {
  local rc=0
  if [[ $target == content ]]; then
    content "$@" >"$tmp/hits" 2>"$tmp/err" || rc=$?
    # git grep reports unreadable objects on stderr yet still exits 1.
    [[ ! -s $tmp/err ]] || { cat "$tmp/err" >&2; die 'search reported errors'; }
  else
    grep -a "$@" "$tmp/paths" >"$tmp/hits" || rc=$?
  fi
  ((rc <= 1)) || die "search failed (exit $rc)"
  return "$rc"
}

denylist=${VOLTA_PRIVATE_DENYLIST:-$HOME/.config/volta/private-denylist}
: >"$tmp/deny"
if [[ -f $denylist ]]; then
  rc=0; grep -v -e '^#' -e '^$' "$denylist" >"$tmp/deny" || rc=$?
  ((rc <= 1)) || die "cannot read $denylist"
elif [[ -z ${CI:-} ]]; then
  echo "privacy-check: no denylist at $denylist; ran generic checks only" >&2
fi

for target in content paths; do
  # Real tailnet hostnames look like <host>.tail<hex>.ts.net; use example.ts.net.
  if hits -n -E '\.tail[0-9a-f]{4,}\.ts\.net'; then cat "$tmp/hits"; fail "real tailnet hostname ($target)"; fi
  # Tailscale addresses (100.64.0.0/10) other than the 100.64.0.0/24 test range.
  # Whole digit-and-dot tokens are extracted without consuming separators, so
  # adjacent addresses are each validated on their own; dots at either end are
  # sentence punctuation, not part of the address.
  if hits -n -o -E '[0-9.]*100\.[0-9]+\.[0-9]+\.[0-9]+[0-9.]*' && awk '{
      tok = $0; sub(/.*:/, "", tok); sub(/^\.+/, "", tok); sub(/\.+$/, "", tok)
      if (split(tok, o, ".") != 4) next
      for (i = 1; i <= 4; i++) if (o[i] !~ /^[0-9]+$/ || length(o[i]) > 3 || o[i] + 0 > 255) next
      if (o[1] == 100 && o[2] >= 64 && o[2] <= 127 && !(o[2] == 64 && o[3] == 0)) { print; bad = 1 }
    } END { exit !bad }' "$tmp/hits"; then fail "tailscale IP ($target)"; fi
  if [[ -s $tmp/deny ]] && hits -n -i -F -f "$tmp/deny"; then cat "$tmp/hits"; fail "string listed in $denylist ($target)"; fi
done

# The signing team belongs in the untracked ios/Config/Signing.local.xcconfig.
target=content
if hits -n -E "DEVELOPMENT_TEAM[\"']? *[:=] *[\"']?[A-Z0-9]{10}(\$|[^A-Z0-9])" \
  && grep -v -E '(^|:)ios/Config/Signing\.local\.xcconfig\.example:' "$tmp/hits"; then
  fail 'hard-coded DEVELOPMENT_TEAM'
fi

# Device and reference screenshots stay in the private repo.
if grep -E '^docs/(reference|screens)/' "$tmp/paths"; then fail 'screenshots belong in the private repo'; fi
# Screenshots and other media stay private unless reviewed and pinned by hash.
# Pins are content hashes, so in commit mode the current list also applies.
{
  if [[ -n ${rev:-} ]]; then git show "$rev:scripts/privacy-allowed-binaries.txt" 2>/dev/null || true; fi
  git show ':scripts/privacy-allowed-binaries.txt' 2>/dev/null || true
} | grep -v -e '^#' -e '^$' >"$tmp/allowed" || true
while IFS= read -r pin; do
  grep -qxF -e "$pin" "$tmp/allowed" || { echo "$pin"; fail 'unreviewed binary asset (review it, then pin "<blob> <path>" in scripts/privacy-allowed-binaries.txt)'; }
done <"$tmp/media"

exit "$status"
