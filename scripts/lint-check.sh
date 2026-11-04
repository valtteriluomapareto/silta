#!/usr/bin/env bash
# Check formatting and lint without changing files (what CI runs).
# With no Swift sources yet, reports "skipped" and succeeds.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

paths=()
for dir in Sources Tests; do
  [[ -d "$dir" ]] && paths+=("$dir")
done
if (( ${#paths[@]} == 0 )) || [[ -z "$(find "${paths[@]}" -name '*.swift' -print -quit)" ]]; then
  echo "lint: no Swift sources yet; skipped"
  exit 0
fi

for tool in swift-format swiftlint; do
  command -v "$tool" >/dev/null || { echo "lint: $tool not found (brew install $tool)" >&2; exit 1; }
done

swift-format lint --strict --recursive --configuration .swift-format.json "${paths[@]}"
# SwiftLint caches under ~/Library/Caches, which Codex's sandbox (CODEX_SANDBOX) can't write.
cache=()
if [[ -n "${CODEX_SANDBOX:-}" ]]; then
  cache=(--no-cache)
fi
swiftlint lint --strict --quiet --config .swiftlint.yml ${cache[@]+"${cache[@]}"}
echo "lint: passed"
