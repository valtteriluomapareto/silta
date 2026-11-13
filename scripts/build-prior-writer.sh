#!/usr/bin/env bash
# Build the pinned pre-docs writer for the full compatibility acceptance test.
# Usage: scripts/build-prior-writer.sh <scratch-directory> [pinned-commit]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ $# -ge 1 && $# -le 2 ]] || { echo 'usage: build-prior-writer.sh <scratch-directory> [pinned-commit]' >&2; exit 64; }
prior_commit="${2:-dc868192e3877a29d79dc54681f0f57b72c3f56f}"
[[ "$prior_commit" =~ ^[0-9a-f]{40}$ ]] || { echo 'prior writer requires a full commit id' >&2; exit 64; }
prior_root="$1"
mkdir -p "$prior_root/source"
git archive "$prior_commit" | tar -x -C "$prior_root/source"
swiftpm=()
if [[ -n "${CODEX_SANDBOX:-}" ]]; then
  swiftpm=(--disable-sandbox)
fi
swift build --package-path "$prior_root/source" ${swiftpm[@]+"${swiftpm[@]}"} \
  -c release --only-use-versions-from-resolved-file >&2
cp "$prior_root/source/.build/release/silta" "$prior_root/silta"
