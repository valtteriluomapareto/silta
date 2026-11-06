#!/usr/bin/env bash
# Offline: Evals/run.sh --silta .build/debug/silta --stub Evals/tests/stub_harness.py --output artifacts/evals/stub
# Live is explicitly opt-in; see docs/dogfood/agent-evals.md.
set -euo pipefail
exec python3 -B "$(dirname "$0")/evals.py" "$@"
