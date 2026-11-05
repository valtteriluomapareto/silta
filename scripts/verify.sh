#!/usr/bin/env bash
# The verify ladder (AGENTS.md).
#   quick  guards, lint, build with warnings as errors, tests (a run with zero tests fails)
#   full   quick plus stress/scenarios and isolated strict process-deadline checks
# Tests always run against a temporary SILTA_HOME, never the real ~/.silta.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mode="${1:-quick}"
case "$mode" in
  quick|full) ;;
  *) echo "usage: scripts/verify.sh [quick|full]" >&2; exit 64 ;;
esac

step() { echo; echo "=== $* ==="; }

if [[ -n "${CI:-}" && -n "${SILTA_UPDATE_GOLDENS:-}" ]]; then
  echo "verify: SILTA_UPDATE_GOLDENS is set in CI; goldens are only regenerated locally, on purpose" >&2
  exit 1
fi

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

# SwiftPM sandboxes manifest builds, which macOS refuses inside another sandbox such as
# Codex's seatbelt (it sets CODEX_SANDBOX). That outer sandbox already confines the build.
swiftpm=()
if [[ -n "${CODEX_SANDBOX:-}" ]]; then
  swiftpm=(--disable-sandbox)
fi

step "build (warnings as errors)"
# Dependencies come only from Package.resolved (D18): fail instead of re-resolving.
swift build ${swiftpm[@]+"${swiftpm[@]}"} --build-tests --only-use-versions-from-resolved-file \
  -Xswiftc -warnings-as-errors

run_tests() {
  local test_log
  local test_exit
  test_log="$(mktemp "${TMPDIR:-/tmp}/silta-test-log.XXXXXX")"
  set +e
  swift test ${swiftpm[@]+"${swiftpm[@]}"} --skip-build "$@" 2>&1 | tee "$test_log"
  test_exit=${PIPESTATUS[0]}
  set -e
  if (( test_exit != 0 )); then
    echo "verify ${mode}: tests failed" >&2
    return "$test_exit"
  fi
  # Each invocation must run tests, including a filtered isolated check.
  if ! grep -Eq 'Test run with [1-9][0-9]* tests?|Executed [1-9][0-9]* tests?' "$test_log"; then
    echo "verify ${mode}: no tests ran" >&2
    return 1
  fi
  rm -f "$test_log"
}

step "test"
if [[ "$mode" == full ]]; then
  export SILTA_SLOW_TESTS=1
  # A deadline-based scale check must not compete with hundreds of CLI subprocesses.
  run_tests --skip 'hookWithTwentyThousandTasks|timeoutKillsAChildIgnoringTermination'
  step "hook scale (isolated)"
  run_tests --filter hookWithTwentyThousandTasks
  step "git deadline (isolated)"
  run_tests --filter timeoutKillsAChildIgnoringTermination
else
  run_tests
fi

echo
echo "verify ${mode}: passed"
