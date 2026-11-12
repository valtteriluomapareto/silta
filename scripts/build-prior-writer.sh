#!/usr/bin/env bash
# Build the pinned pre-docs writer for the full compatibility acceptance test.
# Usage: scripts/build-prior-writer.sh <scratch-directory>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
prior_commit=b13f6062bf43ff2d79680a324a5288a90d0aed83
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
