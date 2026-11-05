#!/usr/bin/env bash
# Apply swift-format and SwiftLint auto-fixes. Run scripts/lint-check.sh afterwards.
#
#   scripts/lint-fix.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

paths=(Sources Tests)

swift-format format --in-place --recursive --configuration .swift-format.json "${paths[@]}"
swiftlint lint --fix --quiet --config .swiftlint.yml
echo "lint-fix: done"
