#!/usr/bin/env bash
# Summarize one workspace; emit Markdown after every read succeeds.
# Without --ws: the silta workspace, printed for a reviewed commit under docs/dogfood/reports.
# With --ws: any workspace, written privately under $SILTA_HOME/reports/<slug>/.
set -euo pipefail
fail() { echo "dogfood-report: $*" >&2; exit 1; }
usage='usage: scripts/dogfood-report.sh [--ws <slug>] [--since YYYY-MM-DD]'
# The workspace identifier shape of the core, matched byte-wise.
identifier() { local LC_ALL=C; [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?$ ]]; }
private=no ws=silta since=
while (( $# )); do
  case "$1" in
    --ws) [[ $private == no ]] && (( $# >= 2 )) || fail "$usage"
      identifier "$2" || fail 'invalid workspace slug; use letters, digits, _ or -, starting and ending with a letter or digit; silta ws ls lists them.'
      private=yes ws="$2"; shift 2;;
    --since) [[ -z "$since" ]] && (( $# >= 2 )) && [[ -n "$2" ]] || fail "$usage"
      since="$2"; shift 2;;
    *) fail "$usage";;
  esac
done
[[ -x /usr/bin/jq ]] || fail '/usr/bin/jq is missing; it ships with macOS 15 or later.'
command -v silta >/dev/null || fail 'silta is missing from PATH.'
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
home="${SILTA_HOME:-$HOME/.silta}"
# A slug past the 255-byte file name limit names its folder by a prefix and a hash;
# `.` never occurs in a slug, so the shortened name cannot be another workspace's.
folder() {
  if (( ${#1} <= 255 )); then echo "$1"; return; fi
  local hash
  hash="$(printf '%s' "$1" | /usr/bin/shasum -a 256)" || return 1
  echo "${1:0:200}.${hash:0:16}"
}
# Prints the work tree holding the physical location of path, judged from its nearest
# existing ancestor; status 1 when no ancestor holds a .git entry.
work_tree() {
  local dir="$1"
  while [[ ! -d "$dir" ]]; do dir="$(dirname "$dir")"; done
  dir="$(cd -P "$dir" && pwd -P)" || return 2
  while true; do
    [[ -e "$dir/.git" ]] && { echo "$dir"; return 0; }
    [[ "$dir" == / ]] && return 1
    dir="$(dirname "$dir")"
  done
}
if [[ $private == yes ]]; then
  umask 077
  name="$(folder "$ws")" || fail 'could not name the report folder.'
  reports="$home/reports/$name"
  if repo="$(work_tree "$reports")"; then
    fail "$reports is inside the git work tree $repo; set SILTA_HOME outside every repository."
  elif (( $? != 1 )); then
    fail "could not resolve $reports."
  fi
else
  reports="$root/docs/dogfood/reports"
fi
if [[ -z "$since" ]]; then
  since=1970-01-01
  for report in "$reports"/????-??-??.md; do
    [[ -f "$report" ]] || continue
    day="$(basename "$report" .md)"
    [[ "$day" > "$since" ]] && since="$day"
  done
fi
canonical="$(/bin/date -j -u -f '%Y-%m-%d' "$since" '+%Y-%m-%d' 2>/dev/null)" || fail 'invalid --since day.'
[[ "$canonical" == "$since" ]] || fail 'use a canonical YYYY-MM-DD day.'
asof="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
[[ "$since" > "${asof:0:10}" ]] && fail "--since $since is after the report day ${asof:0:10} (UTC)."
export SILTA_ACTOR=agent:silta:dogfood-report
temporary="$(mktemp -d)"
staged=
trap 'rm -rf "$temporary"; [[ -z "$staged" ]] || rm -f "$staged"' EXIT
shopt -s nullglob
files=("$home"/log/????-??-??.jsonl)
oldest=none
if (( ${#files[@]} )); then
  oldest="$(basename "${files[0]}" .jsonl)"
  for file in "${files[@]}"; do
    /usr/bin/jq -nR '[inputs | select(length > 0) | (fromjson? // "unreadable")]' "$file" \
      2>/dev/null || fail 'could not read command logs.'
  done | /usr/bin/jq -s 'add' > "$temporary/logs" || fail 'could not read command logs.'
else
  echo '[]' > "$temporary/logs"
fi
silta --ws "$ws" task ls --proposed --promoted --archived --json > "$temporary/tasks" || fail "task list failed; run silta --ws $ws task ls --proposed --promoted --archived."
/usr/bin/jq -e '.ok == true and (.data.tasks | type == "array")' "$temporary/tasks" >/dev/null || fail 'invalid task list.'
: > "$temporary/details"
while IFS= read -r ref; do
  [[ -n "$ref" ]] || continue
  silta --ws "$ws" task show "$ref" --timeline --json >> "$temporary/details" || fail 'task timeline read failed.'
done <<<"$(/usr/bin/jq -r '.data.tasks[].ref' "$temporary/tasks")"
/usr/bin/jq -s '[.[] | if .ok == true then .data else error("task read failed") end]' "$temporary/details" > "$temporary/detail-array" || fail 'invalid task timelines.'
silta --ws "$ws" schema --json > "$temporary/schema" || fail 'schema read failed.'
/usr/bin/jq -e '.ok == true and (.data.commands | type == "array")' "$temporary/schema" >/dev/null || fail 'invalid schema.'
/usr/bin/sqlite3 -readonly -json "$home/silta.db" "
SELECT created_at,command
FROM approval
WHERE workspace='$ws' AND actor<>'$SILTA_ACTOR' AND substr(created_at,1,10)>='$since';
" > "$temporary/approvals" 2>/dev/null || fail 'approval metadata read failed.'
[[ -s "$temporary/approvals" ]] || echo '[]' > "$temporary/approvals"
if ! /usr/bin/jq -nr --slurpfile raw "$temporary/logs" --slurpfile tasks "$temporary/detail-array" \
  --slurpfile schema "$temporary/schema" --slurpfile approvals "$temporary/approvals" \
  --arg since "$since" --arg asof "$asof" --arg oldest "$oldest" --arg actor "$SILTA_ACTOR" --arg ws "$ws" '
  def seconds: (capture("^(?<whole>[^.]+)(?<fraction>\\.[0-9]+)?Z$") // error("invalid timestamp")) |
    ((.whole+"Z"|fromdateiso8601) + ((.fraction // "0")|tonumber));
  def stamp: if type == "object" and (.timestamp|type) == "string"
    then (try (.timestamp|seconds) catch null) else null end;
  def readable: stamp != null and (.actor|type) == "string" and (.command|type) == "string"
    and (.exit_code|type) == "number" and (.milliseconds|type) == "number"
    and (.warnings|type) == "array" and all(.warnings[]; type == "string")
    and (.error_code == null or (.error_code|type) == "string");
  def median: sort | length as $n | if $n % 2 == 1 then .[($n/2|floor)] else (.[($n/2)-1] + .[$n/2])/2 end;
  def cell: tostring | gsub("\\|";"\\|") | gsub("[\r\n]";" ");
  def table($head;$rows):
    if ($rows|length) == 0 then "None." else
      ("| " + ($head | join(" | ")) + " |"),
      ("|" + ($head | map("---") | join("|")) + "|"),
      ($rows[] | "| " + (map(cell) | join(" | ")) + " |")
    end;
  def list($items): if ($items|length) == 0 then "None." else $items[] end;
  def stats($values; $unit):
    if ($values|length) == 0 then "median n/a; maximum n/a"
    else "median \($values|median) \($unit); maximum \($values|max) \($unit)" end;
  ($asof | seconds) as $now |
  ($since + "T00:00:00Z" | seconds) as $start |
  def after($time): $time >= $start;
  ([$approvals[0][] | select(.command|startswith("silta task triage")) | .created_at|seconds]) as $triaged |
  def proposals:
    $tasks[0][] | .ref as $ref | .timeline as $events |
    ($events | map(select(.kind == "created" and .body == "proposed")) | .[0]) as $created |
    select($created != null) |
    ($events | map(select(.kind == "status" and (.body == "todo" or .body == "dropped"))) | .[0]) as $decision |
    {ref:$ref, born:($created.at|seconds), decision:$decision,
      decided:(if $decision == null then null else ($decision.at|seconds) end),
      withdrawn:($decision != null and $decision.body == "dropped"
        and $decision.actor == $created.actor and ($created.actor|startswith("agent:"))
        and ($decision.at|seconds) as $at | $triaged | index($at) == null)};
  ($raw[0] | map(select(type != "object" or .workspace == null or .workspace == $ws))) as $own |
  ($own | map(select(readable|not)) | length) as $unreadable |
  ($own | map(select(readable and .actor != $actor and (stamp|after(.))))) as $selected |
  ($selected | map(select(.workspace == $ws))) as $logs |
  ($schema[0].data.commands | map(.name)) as $commands |
  ($logs | group_by(.command)) as $groups |
  ($logs | map(select(.actor | startswith("agent:"))) | group_by(.actor)) as $sessions |
  [proposals] as $proposals |
  ($proposals | map(select(.withdrawn|not))) as $triage |
  ($triage | map(select(.decided != null and (.decided|after(.))) | ((.decided-.born)/60|floor))) as $waits |
  ($proposals | map(select(.decision == null))) as $pending |
  [$tasks[0][] | . as $task |
    ([.timeline[]? | select(.kind == "status" and .body == "done")] | last) as $done |
    select($done != null and ($done.at|seconds|after(.))) |
    ($task.result // "" | split("\n") | map(select(test("\\S"))) | last // "") as $line |
    {ref:$task.ref, day:$done.at[0:10],
      friction:($line | if startswith("Friction: ") then ltrimstr("Friction: ") | sub("\\s+$";"") else "" end)}
  ] as $done |
  ($done | map(select(.friction == "")) | map(.ref)) as $missing |
  "# Silta dogfood report", "",
  "Since: \($since) (UTC, inclusive).",
  "Until: \($asof) (UTC, report time).",
  "Logs available from: \($oldest).",
  (if $oldest != "none" and $since < $oldest
    then "Warning: --since predates the oldest log; calls before \($oldest) are missing." else empty end),
  "Untagged log lines: \($selected | map(select(.workspace == null)) | length). Unreadable log lines: \($unreadable). Report calls excluded.",
  "", "## Calls", "",
  table(["Command","Calls","Error rate","Common error codes","Usage errors","Max ms"];
    [$groups[] | . as $group | map(select(.exit_code != 0)) as $errors |
      ($errors | group_by(.error_code) | map({code:.[0].error_code,n:length}) |
        sort_by(-.n,.code) | map("\(.code): \(.n)") | join(", ")) as $codes |
      [.[0].command,length,((1000*($errors|length)/length|round)/10|tostring)+"%",
        (if $codes == "" then "-" else $codes end),
        (map(select(.error_code == "usage"))|length), (map(.milliseconds)|max)]]),
  "", "## Repeated failures", "",
  "Consecutive failures within the selected \($ws) stream; flag values are unavailable.", "",
  table(["Actor session","Command","Code","Calls"];
    [$sessions[] | sort_by(.timestamp) |
      reduce .[] as $entry ([];
        if length > 0 and .[-1].command == $entry.command and
          .[-1].code == $entry.error_code and $entry.exit_code != 0 then .[-1].n += 1
        else . + [{actor:$entry.actor,command:$entry.command,code:$entry.error_code,n:1,failed:($entry.exit_code != 0)}] end) |
      .[] | select(.failed and .n >= 2) | [.actor,.command,.code,.n]]),
  "", "## Agent sessions", "",
  "\($sessions|length) sessions; \(stats($sessions|map(length); "calls"))" + ".",
  "", "## Warnings", "",
  table(["Code","Calls"]; [$logs[] | .warnings | unique[]] | group_by(.) | map([.[0],length])),
  "", "## Unused commands", "",
  list([$commands | sort[] | . as $command | select([$selected[].command] | index($command) == null) | "- `\($command)`"]),
  "", "## Friction in the \($ws) workspace", "",
  if $ws != "silta" then
    "Not collected: `Friction:` lines and dogfood tasks belong to the silta workspace only (D36)."
  else
    list([$done[] | select(.friction != "" and .friction != "none") | "- \(.day) \(.ref): \(.friction|cell)"]),
    "",
    "Done tasks without a Friction line: \($missing|length)"
      + (if ($missing|length) > 0 then " (\($missing|join(", ")))" else "" end) + ".",
    "", "Open dogfood tasks:", "",
    list([$tasks[0][] | select(.status != "done" and .status != "dropped") |
      select(any(.links[]; .rel == "about" and .target == "topic:dogfood")) |
      "- \(.ref) \(.status): \(.title|cell)"])
  end,
  "", "## Human load", "", "Approvals per ISO week by command:", "",
  table(["Week","Command","Approvals"];
    [$approvals[0][] | select(.created_at|seconds|after(.)) | . as $approval |
      ($commands | map(. as $candidate | select($approval.command == $candidate or ($approval.command|startswith($candidate + " ")))) |
        sort_by(length) | last // "other") as $command |
      {week:(.created_at|seconds|strftime("%G-W%V")), command:$command}] |
    group_by([.week,.command]) | map([.[0].week,.[0].command,length])),
  "",
  "Proposals accepted: \($proposals | map(select(.decision.body == "todo" and (.decided|after(.)))) | length); dropped: \($triage | map(select(.decision.body == "dropped" and (.decided|after(.)))) | length); left untriaged past 14 days: \($pending | map(select((.born+1209600) as $expiry | ($expiry|after(.)) and $expiry <= $now)) | length).",
  "Oldest pending proposal: \(if ($pending|length) == 0 then "none" else "\($pending | map(($now-.born)/86400|floor) | max) days" end).",
  "Triage wait: \(stats($waits; "min")).",
  "Questions to @me: n/a (S11).", "Inbox size and oldest item: n/a (S11).",
  "Target: under 12 inbox items, none older than one week."
' > "$temporary/report" 2> "$temporary/error"; then
  fail 'could not summarize collected data; no report was published.'
fi
if [[ $private == no ]]; then
  cat "$temporary/report"
  exit 0
fi
# Publish without ever replacing a report: a second run's default range starts at its day.
target="$reports/${asof:0:10}.md"
mkdir -p "$reports" || fail "could not create $reports."
staged="$(mktemp "$reports/.report.XXXXXX")" || fail "could not write in $reports."
cat "$temporary/report" > "$staged" || fail "could not write in $reports."
if ! ln "$staged" "$target" 2>/dev/null; then
  [[ -e "$target" ]] && fail "$target already exists; keep it, or move it away to regenerate."
  fail "could not write $target."
fi
echo "$target"
