#!/usr/bin/env bash
# Executable, model, prompt, optional conversation id. Environment comes from runner.
set -euo pipefail
client="$1"; model="$2"; prompt="$3"; conversation="${4:-}"
args=(-p "$prompt" --model "$model" --output-format stream-json --verbose
      --allowedTools Bash Read Edit Write Glob Grep)
if [[ -n "$conversation" ]]; then args+=(--resume "$conversation"); fi
exec "$client" "${args[@]}"
