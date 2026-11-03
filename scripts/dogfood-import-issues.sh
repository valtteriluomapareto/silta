#!/usr/bin/env bash
# Link every open slice issue to one task in the silta workspace.
set -euo pipefail
for tool in gh silta; do
  command -v "$tool" >/dev/null || { echo "import: missing $tool on PATH." >&2; exit 1; }
done
cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
pages="$(gh api --paginate --slurp 'repos/{owner}/{repo}/issues?state=open&per_page=100')"
issues="$(/usr/bin/jq -ce '[.[][] | select(.pull_request == null) | select(.title | test("^S[0-9]+|^DF")) | {title,url:.html_url}]' <<<"$pages")"
tasks="$(silta --ws silta task ls --proposed --archived --json)"
urls="$(/usr/bin/jq -ce '[.data.tasks[].links[] | .target | select(startswith("url:"))]' <<<"$tasks")"
created=()
while IFS= read -r issue; do
  [[ -n "$issue" ]] || continue
  title="$(/usr/bin/jq -r '.title' <<<"$issue")"
  url="$(/usr/bin/jq -r '.url' <<<"$issue")"
  if /usr/bin/jq -e --arg ref "url:$url" 'index($ref) != null' <<<"$urls" >/dev/null; then
    printf 'Skipped linked issue %s.\n' "$url"
    continue
  fi
  added="$(silta --ws silta task add "$title" --app silta --json)"
  ref="$(/usr/bin/jq -er '.data.ref' <<<"$added")"
  if ! silta --ws silta task link "$ref" "url:$url" --json >/dev/null; then
    printf 'Import stopped after creating %s. Repair its link before rerunning.\n' "$ref" >&2
    printf 'Next: silta --ws silta task link %q %q\n' "$ref" "url:$url" >&2
    exit 1
  fi
  created+=("$ref")
  urls="$(/usr/bin/jq -c --arg ref "url:$url" '. + [$ref]' <<<"$urls")"
  printf 'Created %s and linked %s.\n' "$ref" "$url"
done <<<"$(/usr/bin/jq -c '.[]' <<<"$issues")"
if (( ${#created[@]} > 0 )); then
  printf 'Next: show the imported proposals to the maintainer and request one triage batch: silta --ws silta task triage --accept'
  printf ' %q' "${created[@]}"
  printf ' --approved "<the maintainer\x27s words>"\n'
else
  echo 'Next: use silta --ws silta task ls --proposed to find the existing slice task.'
fi
