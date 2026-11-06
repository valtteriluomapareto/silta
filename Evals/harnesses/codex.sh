#!/usr/bin/env bash
# Executable, model, prompt, optional conversation id. No global profile is consulted.
set -euo pipefail
client="$1"; model="$2"; prompt="$3"; conversation="${4:-}"
if [[ -n "$conversation" ]]; then
  exec "$client" --ask-for-approval never exec resume --json --model "$model" "$conversation" "$prompt"
fi
exec "$client" --ask-for-approval never exec --json --sandbox workspace-write --model "$model" "$prompt"
