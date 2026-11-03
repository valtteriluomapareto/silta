#!/usr/bin/env bash
# Summarize only Silta's own workspace; emit Markdown after every read succeeds.
set -euo pipefail
fail() { echo "dogfood-report: $*" >&2; exit 1; }
command -v silta >/dev/null || fail 'silta is missing from PATH.'
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
since=1970-01-01
if (( $# == 0 )); then
  for report in "$root"/docs/dogfood/reports/????-??-??.md; do
    [[ -f "$report" ]] || continue
    day="$(basename "$report" .md)"
    [[ "$day" > "$since" ]] && since="$day"
  done
elif (( $# == 2 )) && [[ "$1" == --since ]]; then
  since="$2"
else
  fail 'usage: scripts/dogfood-report.sh [--since YYYY-MM-DD]'
fi
canonical="$(/bin/date -j -u -f '%Y-%m-%d' "$since" '+%Y-%m-%d' 2>/dev/null)" || fail 'invalid --since day.'
[[ "$canonical" == "$since" ]] || fail 'use a canonical YYYY-MM-DD day.'
asof="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
export SILTA_ACTOR=agent:codex:dogfood-report
home="${SILTA_HOME:-$HOME/.silta}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
shopt -s nullglob
files=("$home"/log/????-??-??.jsonl)
if (( ${#files[@]} )); then
  /usr/bin/jq -s . "${files[@]}" > "$temporary/logs" 2>/dev/null || fail 'could not parse command logs.'
else
  echo '[]' > "$temporary/logs"
fi
silta --ws silta task ls --proposed --archived --json > "$temporary/tasks" || fail 'task list failed; run silta --ws silta task ls --proposed --archived.'
/usr/bin/jq -e '.ok == true and (.data.tasks | type == "array")' "$temporary/tasks" >/dev/null || fail 'invalid task list.'
: > "$temporary/details"
while IFS= read -r ref; do
  [[ -n "$ref" ]] || continue
  silta --ws silta task show "$ref" --timeline --json >> "$temporary/details" || fail 'task timeline read failed.'
done <<<"$(/usr/bin/jq -r '.data.tasks[].ref' "$temporary/tasks")"
/usr/bin/jq -s '[.[] | if .ok == true then .data else error("task read failed") end]' "$temporary/details" > "$temporary/detail-array" || fail 'invalid task timelines.'
silta --ws silta schema --json > "$temporary/schema" || fail 'schema read failed.'
/usr/bin/jq -e '.ok == true and (.data.commands | type == "array")' "$temporary/schema" >/dev/null || fail 'invalid schema.'
/usr/bin/sqlite3 -readonly -json "$home/silta.db" "
SELECT created_at,command
FROM approval
WHERE workspace='silta' AND actor<>'agent:codex:dogfood-report' AND substr(created_at,1,10)>='$since';
" > "$temporary/approvals" 2>/dev/null || fail 'approval metadata read failed.'
[[ -s "$temporary/approvals" ]] || echo '[]' > "$temporary/approvals"
if ! /usr/bin/jq -nr --slurpfile raw "$temporary/logs" --slurpfile tasks "$temporary/detail-array" \
  --slurpfile schema "$temporary/schema" --slurpfile approvals "$temporary/approvals" \
  --arg since "$since" --arg asof "$asof" --arg actor "$SILTA_ACTOR" '
  def seconds: sub("\\.[0-9]+Z$";"Z") | fromdateiso8601;
  def median: sort | length as $n | if $n == 0 then 0 elif $n % 2 == 1 then .[($n/2|floor)] else (.[($n/2)-1] + .[$n/2])/2 end;
  def cell: tostring | gsub("\\|";"\\|") | gsub("[\r\n]";" ");
  def table($head;$rows):
    ("| " + ($head | join(" | ")) + " |"),
    ("|" + ($head | map("---") | join("|")) + "|"),
    ($rows[] | "| " + (map(cell) | join(" | ")) + " |");
  def inrange($time): $time >= ($since + "T00:00:00Z" | seconds) and $time <= ($asof | seconds);
  def proposals:
    $tasks[0][] | .timeline as $events |
    ($events | map(select(.kind == "created" and .body == "proposed")) | .[0]) as $created |
    select($created != null) |
    ($events | map(select(.kind == "status" and (.body == "todo" or .body == "dropped"))) | .[0]) as $decision |
    {born:($created.at|seconds), decision:$decision,
      decided:(if $decision == null then null else ($decision.at|seconds) end)};
  ($raw[0] | map(select(.workspace == "silta" or .workspace == null)) |
    map(select(.actor != $actor and (.timestamp|seconds|inrange(.))))) as $selected |
  ($selected | map(select(.workspace == "silta"))) as $logs |
  ($schema[0].data.commands | map(.name)) as $commands |
  ($logs | group_by(.command)) as $groups |
  ($logs | map(select(.actor | startswith("agent:"))) | group_by(.actor)) as $sessions |
  [proposals] as $proposals |
  ($proposals | map(select(.decided != null and (.decided|inrange(.))) | ((.decided-.born)/60|floor))) as $waits |
  "# Silta dogfood report", "", "Since: \($since) (UTC, inclusive).",
  "Untagged log lines: \($selected | map(select(.workspace == null)) | length). Report calls excluded.",
  "", "## Calls", "",
  table(["Command","Calls","Error rate","Common error codes","Usage errors","Max ms"];
    [$groups[] | . as $group | map(select(.exit_code != 0)) as $errors |
      ($errors | group_by(.error_code) | map({code:.[0].error_code,n:length}) |
        sort_by(-.n,.code) | map("\(.code): \(.n)") | join(", ")) as $codes |
      [.[0].command,length,((1000*($errors|length)/length|round)/10|tostring)+"%",
        (if $codes == "" then "-" else $codes end),
        (map(select(.error_code == "usage"))|length), (map(.milliseconds)|max)]]),
  "", "## Repeated failures", "",
  "Consecutive failures within the selected silta stream; flag values are unavailable.", "",
  table(["Actor session","Command","Code","Calls"];
    [$sessions[] | sort_by(.timestamp) |
      reduce .[] as $entry ([];
        if length > 0 and .[-1].command == $entry.command and
          .[-1].code == $entry.error_code and $entry.exit_code != 0 then .[-1].n += 1
        else . + [{actor:$entry.actor,command:$entry.command,code:$entry.error_code,n:1,failed:($entry.exit_code != 0)}] end) |
      .[] | select(.failed and .n >= 2) | [.actor,.command,.code,.n]]),
  "", "## Agent sessions", "",
  "\($sessions|length) sessions; median \($sessions|map(length)|median) calls; maximum \($sessions|map(length)|max // 0) calls.",
  "", "## Warnings", "",
  table(["Code","Calls"]; [$logs[] | .warnings | unique[]] | group_by(.) | map([.[0],length])),
  "", "## Unused commands", "",
  ($commands | sort[] | . as $command | select([$logs[].command] | index($command) == null) | "- `\($command)`"),
  "", "## Friction in the silta workspace", "",
  ($tasks[0][] | . as $task | .timeline[]? |
    select(.kind == "status" and .body == "done" and (.at|seconds|inrange(.))) |
    ($task.result // "" | split("\n") | map(select(length > 0)) | last // "") as $line |
    select($line | startswith("Friction: ")) | ($line | ltrimstr("Friction: ") | sub("\\s+$";"")) as $friction |
    select($friction != "none") | "- \(.at[0:10]) \($task.ref): \($friction|cell)"),
  "", "Open dogfood tasks:", "",
  ($tasks[0][] | select(.status != "done" and .status != "dropped") |
    select(any(.links[]; .rel == "about" and .target == "topic:dogfood")) |
    "- \(.ref) \(.status): \(.title|cell)"),
  "", "## Human load", "", "Approvals per ISO week by command:", "",
  table(["Week","Command","Approvals"];
    [$approvals[0][] | select(.created_at|seconds|inrange(.)) | . as $approval |
      ($commands | map(. as $candidate | select($approval.command == $candidate or ($approval.command|startswith($candidate + " ")))) |
        sort_by(length) | last // "other") as $command |
      {week:(.created_at|seconds|strftime("%G-W%V")), command:$command}] |
    group_by([.week,.command]) | map([.[0].week,.[0].command,length])),
  "",
  "Proposals accepted: \($proposals | map(select(.decision.body == "todo" and (.decided|inrange(.)))) | length); dropped: \($proposals | map(select(.decision.body == "dropped" and (.decided|inrange(.)))) | length); 14-day window expiries: \($proposals | map(select((.born+1209600|inrange(.)) and (.decided == null or .decided >= .born+1209600))) | length) (including later triage).",
  "Triage wait: median \($waits|median) min; maximum \($waits|max // 0) min.",
  "Questions to @me: n/a (S11).", "Inbox size and oldest item: n/a (S11).",
  "Target: under 12 inbox items, none older than one week."
' > "$temporary/report" 2> "$temporary/error"; then
  fail 'could not summarize collected data; no report was published.'
fi
cat "$temporary/report"
