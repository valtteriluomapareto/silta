#!/usr/bin/env bash
# Run Codex non-interactively in its worktree for a dogfood slice, as Codex rather
# than as the caller.
#
#   scripts/dogfood-codex.sh start <worktree> <log>            < prompt
#   scripts/dogfood-codex.sh resume <worktree> <thread> <log>  < prompt
#
# The prompt comes from stdin. Codex's JSONL events go to <log>. The command returns
# when Codex's turn ends, then prints the thread id and Codex's last message and exits
# with Codex's status.
set -euo pipefail
[[ -x /usr/bin/jq ]] || { echo 'codex: /usr/bin/jq is missing; it ships with macOS 15 or later.' >&2; exit 1; }
command -v codex >/dev/null || { echo 'codex: missing codex on PATH.' >&2; exit 1; }
usage='usage: dogfood-codex.sh start <worktree> <log> | resume <worktree> <thread> <log>; prompt on stdin'
case "${1:-} $#" in
  'start 3') target="$2" thread='' log="$3" ;;
  'resume 4') target="$2" thread="$3" log="$4"
    [[ "$thread" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "codex: $thread is not a thread id." >&2; exit 1; } ;;
  *) echo "$usage" >&2; exit 1 ;;
esac

# Codex works only in a linked worktree of this repository, never in the main checkout.
root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)"
[[ -d "$target" ]] || { echo "codex: no directory $target." >&2; exit 1; }
dir="$(cd "$target" && pwd -P)"
gitdir="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null || true)"
[[ "$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" == "$common" \
  && "$gitdir" != "$common" ]] \
  || { echo "codex: $dir is not a linked worktree of $root." >&2; exit 1; }

# The caller's agent markers would make Silta record Codex as the caller (spec §11),
# and its session tokens are not Codex's to see: the launch environment keeps them from
# the Codex process, the shell policy from its commands. Git may write objects, refs and
# this worktree's own git directory, but not hooks or config, which run outside Codex.
unset_args=()
while IFS='=' read -r name _; do
  case "$name" in CLAUDE*|CODEX_COMPANION*|SILTA_ACTOR|SILTA_SESSION) unset_args+=(-u "$name") ;; esac
done < <(env)
roots="\"${SILTA_HOME:-$HOME/.silta}\",\"$common/objects\",\"$common/refs\",\"$common/logs\",\"$gitdir\""
# The maintainer's choice for driven runs, independent of their own Codex settings.
config=(
  -c 'model="gpt-6.1-sol"'
  -c 'model_reasoning_effort="high"'
  -c 'approval_policy="never"'
  -c 'sandbox_mode="workspace-write"'
  -c "sandbox_workspace_write.writable_roots=[$roots]"
  -c 'sandbox_workspace_write.network_access=true'
  -c 'shell_environment_policy.exclude=["CLAUDE*","CODEX_COMPANION*","SILTA_ACTOR","SILTA_SESSION"]'
  -c 'shell_environment_policy.set.SILTA_ACTOR="agent:codex"'
)
if [[ -z "$thread" ]]; then
  command=(codex exec --json "${config[@]}" -C "$dir" -)
else
  command=(codex exec resume "$thread" --json "${config[@]}" -)
fi
# Files git trusts when it later runs in this worktree outside the sandbox.
links() { cat "$dir/.git" "$gitdir/commondir" "$gitdir/gitdir" 2>/dev/null || true; }
before="$(links)"
status=0
(cd "$dir" && env ${unset_args[@]+"${unset_args[@]}"} "${command[@]}") >"$log" || status=$?

# Lines that aren't JSON, such as a truncated last event, are skipped.
started="$(/usr/bin/jq -rR 'fromjson? | select(.type == "thread.started") | .thread_id' "$log" | head -n 1)"
printf 'Thread: %s\n' "${started:-${thread:-unknown}}"
/usr/bin/jq -rRn '[inputs | fromjson? | select(.type == "item.completed" and .item.type == "agent_message")
  | .item.text] | last // empty' "$log"

# With extensions.worktreeConfig, the worktree's config.worktree is read by every git
# command run there, so a core.fsmonitor or hooksPath in it would run outside the
# sandbox. Codex's own settings live under codex.*; anything else stops the flow.
config_keys="$(git config --file "$gitdir/config.worktree" --name-only --list 2>/dev/null \
  | grep -v '^codex\.' || true)"
if [[ -n "$config_keys" || "$(links)" != "$before" ]]; then
  echo "codex: the worktree's git setup changed (${config_keys:-its links}); don't run git in $dir." >&2
  echo "Next: inspect $gitdir, then remove the worktree with rm -rf $dir && git worktree prune" >&2
  exit 70
fi
exit "$status"
