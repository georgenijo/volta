#!/usr/bin/env bash
# Installs the privacy hooks into the repository's git directory, outside the
# worktree, so checking out an older branch cannot remove or weaken them.
set -euo pipefail
top=$(git rev-parse --show-toplevel)
dest="$(git rev-parse --git-common-dir)/volta-hooks"
dest=$(cd "$(dirname "$dest")" && pwd)/volta-hooks
mkdir -p "$dest"
install -m 0755 "$top/.githooks/pre-commit" "$top/.githooks/pre-push" "$top/scripts/privacy-check.sh" "$dest/"
git config core.hooksPath "$dest"
echo "privacy hooks installed in $dest (rerun after the hooks or checker change)"
