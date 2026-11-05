#!/usr/bin/env bash
# The verify ladder (AGENTS.md).
#   quick  guards, lint, build with warnings as errors, tests (a run with zero tests fails)
#   full   quick plus stress/scenarios, then the wall-clock deadline tier alone and serially
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

SILTA_HOME="$(mktemp -d "${TMPDIR:-/tmp}/silta-verify.XXXXXX")"
export SILTA_HOME
last_test_log=""
trap 'rm -rf "$SILTA_HOME"; rm -f "$last_test_log"' EXIT

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
  rm -f "$last_test_log"
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
  last_test_log="$test_log"
}

step "test"
if [[ "$mode" == full ]]; then
  export SILTA_SLOW_TESTS=1
  SILTA_DEADLINE_TESTS='' run_tests
  # Wall-clock deadline checks can't tell a slow process from a busy machine, so the
  # parallel suite skips them; they run here alone and one at a time.
  step "wall-clock deadlines (isolated, serial)"
  SILTA_DEADLINE_TESTS=1 run_tests --no-parallel --filter 'WallClock'
  # Skipped tests still count as run, so a broken gate would otherwise pass silently.
  if grep -q ' skipped' "$last_test_log"; then
    echo "verify ${mode}: a wall-clock deadline test was skipped" >&2
    exit 1
  fi
  for suite in WallClockHookTests WallClockGitTests WallClockWhereTests; do
    if ! grep -q "Suite ${suite} passed" "$last_test_log"; then
      echo "verify ${mode}: ${suite} did not run" >&2
      exit 1
    fi
  done
else
  SILTA_DEADLINE_TESTS='' run_tests
fi

echo
echo "verify ${mode}: passed"
