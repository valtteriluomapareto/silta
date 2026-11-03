#!/usr/bin/env bash
# Install a release built from clean main; never prompt.
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
commit="$(git rev-parse HEAD)"
swift build -c release --only-use-versions-from-resolved-file
if [[ "$(git rev-parse HEAD)" != "$commit" || "$(git symbolic-ref --quiet --short HEAD || true)" != main || -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  echo 'install-dev: main changed during the build; nothing was installed.' >&2
  exit 1
fi
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
