#!/usr/bin/env bash
# Finish a merged slice in the silta workspace (D41): done with the merge commit and the
# PR's draft result, then report on the slice issue and close it.
#
#   scripts/dogfood-finish.sh <ref> <pr>
#
# Run it from the main checkout after pulling main. It never pulls, merges or pushes.
set -euo pipefail
[[ -x /usr/bin/jq ]] || { echo 'finish: /usr/bin/jq is missing; it ships with macOS 15 or later.' >&2; exit 1; }
for tool in gh silta; do
  command -v "$tool" >/dev/null || { echo "finish: missing $tool on PATH." >&2; exit 1; }
done
[[ $# -eq 2 && "$2" =~ ^[0-9]+$ ]] || { echo 'usage: dogfood-finish.sh <ref> <pr>' >&2; exit 1; }
ref="$1" pr="$2"
cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

pull="$(gh pr view "$pr" --json state,mergeCommit,body)"
[[ "$(/usr/bin/jq -r '.state' <<<"$pull")" == MERGED ]] \
  || { echo "finish: PR #$pr is not merged; merge it first." >&2; exit 1; }
sha="$(/usr/bin/jq -er '.mergeCommit.oid' <<<"$pull")"
git merge-base --is-ancestor "$sha" HEAD 2>/dev/null \
  || { echo "finish: this checkout lacks merge commit ${sha:0:7}." >&2; echo 'Next: git pull' >&2; exit 1; }

# The draft result runs from "## Draft result" through its last Friction: line, so a
# trailer after it, or a later heading, is left out.
section="$(/usr/bin/jq -r '.body' <<<"$pull" | tr -d '\r' | awk '
  /^## / { inside = (tolower($0) ~ /^## draft result[[:space:]]*$/); if (inside) found = 1; next }
  inside { print }
  END { if (!found) exit 3 }')" \
  || { echo "finish: PR #$pr has no \"## Draft result\" section; ask its author to add one." >&2; exit 1; }
friction="$(printf '%s\n' "$section" | grep '^Friction:' | tail -n 1 || true)"
[[ -n "$friction" ]] || {
  echo "finish: PR #$pr's draft result has no Friction: line; ask its author to add one." >&2
  exit 1
}
body="$(printf '%s\n' "$section" | awk -v last="$(printf '%s\n' "$section" | grep -n '^Friction:' | tail -n 1 | cut -d: -f1)" \
  'NR < last && (started || NF) { started = 1; print }')"
result="${body:+$body
}Merged in #$pr (${sha:0:7}).
$friction"

task="$(silta --ws silta task show "$ref" --json 2>&1)" \
  || { echo "finish: silta could not show $ref:" >&2; printf '%s\n' "$task" >&2; exit 1; }
status="$(/usr/bin/jq -r '.data.status // empty' <<<"$task")"
# Only app tasks record a commit (spec §8); the result names the merge either way.
sha_args=()
[[ -n "$(/usr/bin/jq -r '.data.app // empty' <<<"$task")" ]] && sha_args=(--sha "$sha")
issue="$(/usr/bin/jq -r '[.data.links[]?.target | select(startswith("url:")) | ltrimstr("url:")
  | select(test("/issues/[0-9]+$"))] | first // empty' <<<"$task")"
case "$status" in
  done) echo "$ref is already done." ;;
  review) printf '%s\n' "$result" | silta --ws silta task done "$ref" ${sha_args[@]+"${sha_args[@]}"} -F - ;;
  *) echo "finish: $ref is ${status:-unreadable}, not review; its author submits it first (D41)." >&2
    exit 1 ;;
esac
if [[ -z "$issue" ]]; then
  echo "finish: $ref links no GitHub issue; nothing to close."
elif [[ "$(gh issue view "$issue" --json state -q .state)" == CLOSED ]]; then
  echo "Issue $issue is already closed."
else
  gh issue comment "$issue" --body "Done in #$pr (${sha:0:7}); Silta task $ref has this result:

$result"
  gh issue close "$issue"
fi
echo 'Next: scripts/install-dev.sh'
