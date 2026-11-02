#!/usr/bin/env bash
# Apply swift-format and SwiftLint auto-fixes. Run scripts/lint-check.sh afterwards.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

paths=()
for dir in Sources Tests; do
  [[ -d "$dir" ]] && paths+=("$dir")
done
if (( ${#paths[@]} == 0 )); then
  echo "lint-fix: no Swift sources yet; nothing to do"
  exit 0
fi

swift-format format --in-place --recursive --configuration .swift-format.json "${paths[@]}"
swiftlint lint --fix --quiet --config .swiftlint.yml
echo "lint-fix: done"
