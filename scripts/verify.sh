#!/usr/bin/env bash
# The verify ladder (AGENTS.md).
#   quick  guards, lint, build with warnings as errors, tests (a run with zero tests fails)
#   full   quick plus the slow tiers (stress, scenarios) via SILTA_SLOW_TESTS=1
# Tests always run against a temporary SILTA_HOME, never the real ~/.silta.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mode="${1:-quick}"
case "$mode" in
  quick|full) ;;
  *) echo "usage: scripts/verify.sh [quick|full]" >&2; exit 64 ;;
esac

step() { echo; echo "=== $* ==="; }

step "guards"
scripts/run-guards.sh

step "lint"
scripts/lint-check.sh

if [[ ! -f Package.swift ]]; then
  step "build and test"
  echo "no Package.swift yet; skipped"
  echo
  echo "verify ${mode}: passed (guards and lint only)"
  exit 0
fi

SILTA_HOME="$(mktemp -d "${TMPDIR:-/tmp}/silta-verify.XXXXXX")"
export SILTA_HOME
trap 'rm -rf "$SILTA_HOME"' EXIT

step "build (warnings as errors)"
swift build --build-tests -Xswiftc -warnings-as-errors

step "test"
if [[ "$mode" == full ]]; then
  export SILTA_SLOW_TESTS=1
fi
log="$(mktemp "${TMPDIR:-/tmp}/silta-test-log.XXXXXX")"
set +e
swift test --skip-build 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e
if (( status != 0 )); then
  echo "verify ${mode}: tests failed" >&2
  exit "$status"
fi
# An empty suite must not pass: require at least one Swift Testing or XCTest test.
if ! grep -Eq 'Test run with [1-9][0-9]* tests?|Executed [1-9][0-9]* tests?' "$log"; then
  echo "verify ${mode}: no tests ran" >&2
  exit 1
fi
rm -f "$log"

echo
echo "verify ${mode}: passed"
