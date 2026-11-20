#!/usr/bin/env bash
# The verify ladder (AGENTS.md).
#   quick       guards, lint, build with warnings as errors, tests (a run with zero tests fails)
#   full        full-swift, evals and app: everything CI runs
#   app         guards, lint, native Debug tests and Release build
#   full-swift  quick plus the slow tiers (stress, scenarios, prior-writer compatibility),
#               then the wall-clock deadline tier alone and serially
#   evals       build the CLI, then the offline agent eval replays, one process per module
# CI runs full-swift, evals and app in parallel; full runs them in sequence.
# Tests always run against a temporary SILTA_HOME, never the real ~/.silta.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mode="${1:-quick}"
case "$mode" in
  quick|full|full-swift|evals|app) ;;
  *) echo "usage: scripts/verify.sh [quick|full|full-swift|evals|app]" >&2; exit 64 ;;
esac

step() { echo; echo "=== $* ==="; }

if [[ -n "${CI:-}" && -n "${SILTA_UPDATE_GOLDENS:-}" ]]; then
  echo "verify: SILTA_UPDATE_GOLDENS is set in CI; goldens are only regenerated locally, on purpose" >&2
  exit 1
fi

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

guards_and_lint() {
  step "guards"
  scripts/run-guards.sh
  step "lint"
  scripts/lint-check.sh
}

# Dependencies come only from Package.resolved (D18): fail instead of re-resolving.
build() {
  step "build (warnings as errors)"
  swift build ${swiftpm[@]+"${swiftpm[@]}"} --only-use-versions-from-resolved-file \
    -Xswiftc -warnings-as-errors "$@"
}

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

# Skipped tests still count as run, so a gate that stopped enabling a test would otherwise
# pass silently. Fails unless each named test passed in the last run.
require_passed() {
  local name
  for name in "$@"; do
    if ! grep -Eq "Test ${name}\([^)]*\)( with [0-9]+ test cases?)? passed" "$last_test_log"; then
      echo "verify ${mode}: ${name} did not run and pass" >&2
      exit 1
    fi
  done
}

full_swift() {
  guards_and_lint
  step "build prior writers (isolated compatibility test)"
  export SILTA_PRIOR_BINARY="$SILTA_HOME/prior/silta"
  bash scripts/build-prior-writer.sh "$SILTA_HOME/prior" prior
  export SILTA_V6_BINARY="$SILTA_HOME/prior-v6/silta"
  bash scripts/build-prior-writer.sh "$SILTA_HOME/prior-v6" v6
  build --build-tests

  step "test (with slow tiers)"
  export SILTA_SLOW_TESTS=1
  # Bound competing subprocess and filesystem work on the CI runner.
  SILTA_DEADLINE_TESTS='' run_tests --experimental-maximum-parallelization-width 4
  # Scenario replay, concurrency guarantees and every prior-writer compatibility check.
  require_passed twentyProcessesAddFiveHundredTasksWithoutSequenceGaps \
    allScenariosReplayByteIdentically \
    tenDistinctSessionsHaveExactlyOneSuccessfulClaim \
    busyRetryNamesOnlyFailedCommandPath \
    deterministicFixturesCoverHistoryAndCloneStates \
    policyReplayStoresOnlyScriptedOutcomes \
    restoredProposalsHaveDeterministicReadOnlyDiscovery \
    scenariosCannotPassWithoutADeclaredStepOrWithAnEmptyJsonMatcher \
    scenarioLogsActorPrecedenceAndSessions \
    nestedCwdSharesSessionButDistinctWorktreeDoesNot \
    twentyConnectionsCommitFourThousandAdds \
    concurrentExportsOfOneWorkspaceAllSucceed \
    locationScenarioSurvivesRestart \
    actualPriorWriterRefusesUpgradedDatabaseWithoutChangingIt \
    actualMetadataWriterCannotWriteAfterNamespaceUpgrade \
    actualV6WriterKeepsPopulatedAuditFields \
    actualV6WriterRefusesTargetSnapshotFloorWithoutMutation \
    actualV6ExporterRefusesUnknownCounterOnlySchema

  # Wall-clock deadline checks can't tell a slow process from a busy machine, so the
  # parallel suite skips them; they run here alone and one at a time.
  step "wall-clock deadlines (isolated, serial)"
  if ! SILTA_DEADLINE_TESTS=1 run_tests --no-parallel --filter 'WallClock'; then
    # Processes outside this run can still delay a wall-clock check on a shared machine,
    # while a real regression fails every attempt. Measure once more before failing.
    step "wall-clock deadlines (second attempt after a failure)"
    SILTA_DEADLINE_TESTS=1 run_tests --no-parallel --filter 'WallClock'
  fi
  if grep -q ' skipped' "$last_test_log"; then
    echo "verify ${mode}: a wall-clock deadline test was skipped" >&2
    exit 1
  fi
  for suite in WallClockHookTests WallClockGitTests WallClockWhereTests WallClockBodyInputTests; do
    if ! grep -q "Suite ${suite} passed" "$last_test_log"; then
      echo "verify ${mode}: ${suite} did not run" >&2
      exit 1
    fi
  done
}

# The replays drive .build/debug/silta, so this builds at least that product.
evals() {
  step "offline agent eval replays (no models)"
  python3 -B scripts/run-eval-tests.py
}

case "$mode" in
  quick)
    guards_and_lint
    build --build-tests
    step "test"
    SILTA_DEADLINE_TESTS='' run_tests
    ;;
  full-swift)
    full_swift
    ;;
  evals)
    build --product silta
    evals
    ;;
  app)
    guards_and_lint
    scripts/verify-app.sh
    ;;
  full)
    # Evals run after the wall-clock tier so their processes can't load the machine
    # during it.
    full_swift
    evals
    scripts/verify-app.sh
    ;;
esac

echo
echo "verify ${mode}: passed"
