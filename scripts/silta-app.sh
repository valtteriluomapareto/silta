#!/usr/bin/env bash
# Drive a Debug Silta fixture in its own private run directory.
set -euo pipefail
exec python3 -B "$(dirname "${BASH_SOURCE[0]}")/silta_app.py" "$@"
