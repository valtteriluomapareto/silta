#!/usr/bin/env bash
# Print the Actions cache key for the prior-writer binaries as `key=<key>`, for
# $GITHUB_OUTPUT. Every job that reads or fills that cache uses this script, so the
# keys can't drift apart. The key changes with the CPU, the Swift toolchain and
# scripts/build-prior-writer.sh, which pins the commits; there is no prefix fallback.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
version="$(swift --version 2>/dev/null | sed -n 1p)"
# An empty line would hash to a constant and hide every later toolchain change.
[[ -n "$version" ]] || { echo 'prior-writer-cache-key: swift --version printed nothing' >&2; exit 1; }
toolchain="$(printf '%s' "$version" | shasum -a 256 | cut -c1-16)"
recipe="$(shasum -a 256 scripts/build-prior-writer.sh | cut -c1-16)"
echo "key=prior-writers-$(uname -m)-${toolchain}-${recipe}"
