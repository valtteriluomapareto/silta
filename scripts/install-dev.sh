#!/usr/bin/env bash
# Install a release built from clean main that matches origin/main; never prompt.
#
#   scripts/install-dev.sh
#
# Takes no arguments. Installs into SILTA_INSTALL_DIR (default ~/.local/bin).
set -euo pipefail
root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
cd "$root"
branch="$(git symbolic-ref --quiet --short HEAD || true)"
if [[ "$branch" != main ]]; then
  echo 'install-dev: use a clean checkout of main.' >&2
  exit 1
fi
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  echo 'install-dev: commit or remove changes before building from main.' >&2
  exit 1
fi
git fetch --quiet origin main || { echo 'install-dev: could not fetch origin main.' >&2; exit 1; }
read -r ahead behind < <(git rev-list --left-right --count main...origin/main)
if (( ahead != 0 || behind != 0 )); then
  printf 'install-dev: local main is %s ahead and %s behind origin/main; pull or reset it first.\n' \
    "$ahead" "$behind" >&2
  exit 1
fi
commit="$(git rev-parse HEAD)"
swift build -c release --only-use-versions-from-resolved-file
binary="$root/.build/release/silta"
[[ -f "$binary" ]] || { echo 'install-dev: release binary is missing.' >&2; exit 1; }
destination="${SILTA_INSTALL_DIR:-$HOME/.local/bin}"
mkdir -p "$destination"
temporary="$(mktemp "$destination/.silta.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
install -m 755 "$binary" "$temporary"
mv -f "$temporary" "$destination/silta"
printf 'Installed %s from commit %s.\n' "$destination/silta" "$commit"
printf 'Next: follow %s/docs/dogfood/README.md with the maintainer.\n' "$root"
