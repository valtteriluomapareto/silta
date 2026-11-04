#!/usr/bin/env bash
# Run Codex non-interactively for a dogfood slice, as Codex rather than as the caller.
#
#   scripts/dogfood-codex.sh start <worktree> <log>   < prompt
#   scripts/dogfood-codex.sh resume <thread> <log>    < prompt
#
# The prompt comes from stdin. Codex's JSONL events go to <log>. On exit the script
# prints the thread id and Codex's last message, and exits with Codex's status.
set -euo pipefail
[[ -x /usr/bin/jq ]] || { echo 'codex: /usr/bin/jq is missing; it ships with macOS 15 or later.' >&2; exit 1; }
command -v codex >/dev/null || { echo 'codex: missing codex on PATH.' >&2; exit 1; }
usage='usage: dogfood-codex.sh start <worktree> <log> | resume <thread> <log>; prompt on stdin'
[[ $# -eq 3 ]] || { echo "$usage" >&2; exit 1; }
mode="$1" target="$2" log="$3"
[[ ! -t 0 ]] || { echo 'codex: pass the prompt on stdin.' >&2; exit 1; }

root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)"
case "$mode" in
  start)
    [[ -d "$target" ]] || { echo "codex: no directory $target." >&2; exit 1; }
    dir="$(cd "$target" && pwd -P)"
    [[ "$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" == "$common" ]] \
      || { echo "codex: $dir is not a worktree of $root." >&2; exit 1; }
    ;;
  resume)
    [[ "$target" =~ ^[0-9a-f-]{36}$ ]] || { echo "codex: $target is not a thread id." >&2; exit 1; }
    ;;
  *) echo "$usage" >&2; exit 1 ;;
esac

# The caller's agent markers would make Silta record Codex as the caller (spec §11),
# and its session tokens are not Codex's to see. Both the launch environment and
# Codex's shell policy drop them; resume reuses the thread's shell environment.
unset_args=()
while IFS='=' read -r name _; do
  case "$name" in CLAUDE*|CODEX_COMPANION*|SILTA_ACTOR|SILTA_SESSION) unset_args+=(-u "$name") ;; esac
done < <(env)
config=(
  -c 'approval_policy="never"'
  -c 'sandbox_mode="workspace-write"'
  -c "sandbox_workspace_write.writable_roots=[\"$HOME/.silta\",\"$common\"]"
  -c 'sandbox_workspace_write.network_access=true'
  -c 'shell_environment_policy.exclude=["CLAUDE*","CODEX_COMPANION*","SILTA_ACTOR","SILTA_SESSION"]'
)
if [[ "$mode" == start ]]; then
  command=(codex exec --json "${config[@]}" -C "$dir" -)
else
  command=(codex exec resume "$target" --json "${config[@]}" -)
fi
status=0
env ${unset_args[@]+"${unset_args[@]}"} "${command[@]}" >"$log" || status=$?

thread="$(/usr/bin/jq -r 'select(.type == "thread.started") | .thread_id' "$log" | head -n 1)"
[[ -n "$thread" || "$mode" == start ]] || thread="$target"
printf 'Thread: %s\n' "${thread:-unknown}"
/usr/bin/jq -rs '[.[] | select(.type == "item.completed" and .item.type == "agent_message")
  | .item.text] | last // empty' "$log"
exit "$status"
