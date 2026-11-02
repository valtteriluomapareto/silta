#!/usr/bin/env bash
# Run the guard self-tests, then every repository guard. Keeps going after a failure
# and lists all failures at the end. Needs only python3; no build.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

failed=()
run_guard() {
  local name="$1"
  shift
  echo "=== ${name} ==="
  if "$@"; then
    echo "PASS: ${name}"
  else
    local result=$?
    echo "FAIL: ${name} (exit ${result})"
    failed+=("${name}")
  fi
}

run_guard guard-selftests python3 -B -m unittest discover -s scripts/tests -q
run_guard core-boundary python3 -B scripts/guards/check_core_boundary.py
run_guard core-determinism python3 -B scripts/guards/check_core_determinism.py
run_guard test-waits python3 -B scripts/guards/check_test_waits.py
run_guard no-plan-refs python3 -B scripts/guards/check_no_plan_refs.py
run_guard core-hygiene python3 -B scripts/guards/check_core_hygiene.py
run_guard try-optional python3 -B scripts/guards/check_try_optional.py
run_guard docs-links python3 -B scripts/guards/check_docs_links.py
run_guard plans-board python3 -B scripts/guards/check_plans_board.py

if (( ${#failed[@]} )); then
  echo "Guards failed: ${failed[*]}"
  exit 1
fi
echo "All guards passed."
