#!/usr/bin/env bash
# Link every open slice issue to one task in the silta workspace.
set -euo pipefail
[[ -x /usr/bin/jq ]] || { echo 'import: /usr/bin/jq is missing; it ships with macOS 15 or later.' >&2; exit 1; }
for tool in gh silta; do
  command -v "$tool" >/dev/null || { echo "import: missing $tool on PATH." >&2; exit 1; }
done
cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

# Prints a failed silta call's error code, message and next steps on stderr.
report_error() {
  /usr/bin/jq -er '.error | "import: \(.code): \(.message)", ((.next // [])[] | "Next: \(.)")' \
    <<<"$1" >&2 2>/dev/null || echo 'import: silta failed without a JSON error.' >&2
}

# Runs one silta --json command in the silta workspace; stops with its error on failure.
silta_json() {
  local out
  out="$(silta --ws silta "$@" --json)" || true
  if ! /usr/bin/jq -e '.ok == true' <<<"$out" >/dev/null 2>&1; then
    report_error "$out"
    exit 1
  fi
  printf '%s\n' "$out"
}

pages="$(gh api --paginate --slurp 'repos/{owner}/{repo}/issues?state=open&per_page=100')"
issues="$(/usr/bin/jq -ce '[.[][] | select(.pull_request == null) | select(.title | test("^S[0-9]+")) | {title,url:.html_url}]' <<<"$pages")"
tasks="$(silta_json task ls --proposed --promoted --archived)"
urls="$(/usr/bin/jq -ce '[.data.tasks[].links[] | .target | select(startswith("url:"))]' <<<"$tasks")"
while IFS= read -r issue; do
  [[ -n "$issue" ]] || continue
  title="$(/usr/bin/jq -r '.title' <<<"$issue")"
  url="$(/usr/bin/jq -r '.url' <<<"$issue")"
  if /usr/bin/jq -e --arg ref "url:$url" 'index($ref) != null' <<<"$urls" >/dev/null; then
    printf 'Skipped linked issue %s.\n' "$url"
    continue
  fi
  added="$(silta_json task add "$title" --app silta)"
  ref="$(/usr/bin/jq -er '.data.ref' <<<"$added")"
  linked="$(silta --ws silta task link "$ref" "url:$url" --json)" || true
  if ! /usr/bin/jq -e '.ok == true' <<<"$linked" >/dev/null 2>&1; then
    report_error "$linked"
    printf 'Import stopped after creating %s. Repair its link before rerunning.\n' "$ref" >&2
    printf 'Next: silta --ws silta task link %q %q\n' "$ref" "url:$url" >&2
    exit 1
  fi
  urls="$(/usr/bin/jq -c --arg ref "url:$url" '. + [$ref]' <<<"$urls")"
  printf 'Created %s and linked %s.\n' "$ref" "$url"
done <<<"$(/usr/bin/jq -c '.[]' <<<"$issues")"
tasks="$(silta_json task ls --proposed --promoted --archived)"
pending="$(/usr/bin/jq -r --argjson issues "$issues" '
  ($issues | map("url:" + .url)) as $links |
  [.data.tasks[] | select(.status == "proposed") |
    select(any(.links[]; .target as $target | $links | index($target) != null)) | .ref] |
  join(" ")' <<<"$tasks")"
if [[ -n "$pending" ]]; then
  printf 'Next: show these proposals to the maintainer and ask for one triage batch: silta --ws silta task triage --accept %s --approved "<the maintainer\x27s words>"\n' "$pending"
else
  echo 'Next: no imported slice waits for triage; find a slice with silta --ws silta task ls --proposed --promoted --archived.'
fi
