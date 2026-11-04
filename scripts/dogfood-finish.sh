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

# The draft result is everything under "## Draft result" up to the next heading.
draft="$(/usr/bin/jq -r '.body' <<<"$pull" | tr -d '\r' | awk '
  /^## / { inside = ($0 ~ /^## Draft result[[:space:]]*$/); next }
  inside { print }')"
draft="$(printf '%s\n' "$draft" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
friction="$(printf '%s\n' "$draft" | tail -n 1)"
[[ "$friction" == Friction:* ]] || {
  echo "finish: PR #$pr's \"## Draft result\" must end with a Friction: line." >&2
  exit 1
}
result="$(printf '%s\n' "$draft" | sed '$d')
Merged in #$pr (${sha:0:7}).
$friction"

task="$(silta --ws silta task show "$ref" --json)"
status="$(/usr/bin/jq -r '.data.status // empty' <<<"$task")"
issue="$(/usr/bin/jq -r '[.data.links[]?.target | select(startswith("url:")) | ltrimstr("url:")
  | select(test("/issues/[0-9]+$"))] | first // empty' <<<"$task")"
case "$status" in
  done) echo "$ref is already done." ;;
  review | doing | todo)
    printf '%s\n' "$result" | silta --ws silta task done "$ref" --sha "$sha" -F - ;;
  *) echo "finish: $ref is ${status:-unreadable}; ask the maintainer." >&2; exit 1 ;;
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
