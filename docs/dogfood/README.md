# Building Silta with Silta

These instructions take effect after the DF PR merges and an agent completes setup
with the maintainer in chat. The current stage stays **before DF0** until that has
happened. The maintainer does not run CLI commands.

The scripts need `/usr/bin/jq`, which ships with macOS 15 or later. The import
also needs `gh` 2.48 or later, for `gh api --slurp`.

## Setup with an agent

1. Work in the maintainer's main checkout, in a directory named `silta`:
   `init --scan` names the workspace after the directory. It must be a clean `main`
   that matches `origin/main`. Run `scripts/install-dev.sh`; it refuses anything
   else, prints the built commit and installs `silta` into `~/.local/bin`. Put
   `~/.local/bin` on PATH for these scripts.
2. From the repository root, run `silta init --scan "$PWD"`, then `silta ws ls`. It
   must list `silta`. If it lists another slug, stop and tell the maintainer: that
   workspace can't be renamed or removed. Show [workspace.yaml](workspace.yaml) to
   the maintainer and name the exact next command:
   `silta ws edit silta -F docs/dogfood/workspace.yaml`. After their yes, run it with
   `--approved "<their exact words>"`. Then run `silta ws use silta`. Local repo
   paths stay in the database and are absent from this YAML.
3. Run `scripts/dogfood-import-issues.sh`. It enumerates every open issue whose
   title starts with a slice id (`S7: …`), creates app-bound proposals and links
   their URLs. `DF:` issues are not imported. It skips issues a task already links,
   including archived tasks and proposals from other sessions. A failed `silta`
   call prints its error and next step; if linking fails after creation, run the
   printed repair before rerunning.
4. The import ends with a `Next:` line naming every imported proposal still waiting
   for triage. Show them in one batch with `silta --ws silta task ls --proposed`,
   name that `task triage --accept` command to the maintainer, ask once, and run it
   with their exact words in `--approved`. Never invent approval words or accept
   tasks they didn't name.
5. Check the setup in a fresh agent session using only `~/.local/bin/silta`, without
   touching a real slice (`done` is terminal):
   - `silta ws ls` lists `silta`;
     `silta --ws silta task ls --proposed --promoted --archived --json` lists the
     imported slices with their links, and `silta --ws silta task show <ref>` shows a
     slice's `url:` link.
   - Run the work loop on a scratch task:
     `silta --ws silta task add --start "DF setup check" --app silta`, then
     `silta --ws silta task plan <ref> -m "- [ ] Check the loop"`,
     `silta --ws silta task plan <ref> --step 1 --done` and
     `silta --ws silta task drop <ref> -m "Setup check only."`.

   Only after this works should a PR change the stage line in AGENTS.md to DF0.

Do not add `proposals` or `ask_about` to the workspace YAML until S11 and S13 ship
those keys. The maintainer can choose them with the agent then. The initial import
runs before that choice; it does not implement those policies itself.

## Work a slice

Follow the DF0 rules in [AGENTS.md](../../AGENTS.md#dogfooding). Questions and
handoffs stay on the slice issue until DF1.

## Review friction

Once per wave, and at least every 60 days, an agent runs
`scripts/dogfood-report.sh` with the maintainer. It prints Markdown from the `silta`
workspace and excludes its own actor's calls and approvals.

- **Range.** `--since YYYY-MM-DD` is inclusive in UTC. Without it, the newest
  date-named file in [reports](reports/README.md) supplies the date; without a
  prior report, all retained logs and task history are considered. `Until:` is the
  UTC report time. Logs are kept 90 days: `Logs available from:` names the oldest
  one, and a warning says when `--since` is earlier, so the call counts are
  incomplete. The first report always shows that warning, because it starts at
  1970-01-01. Task and approval history is complete. A `--since` after the report
  day is refused.
- **Log lines.** Lines tagged with another workspace are omitted. Untagged lines
  and unreadable lines (malformed, or missing the expected fields) are only counted;
  untagged lines also count toward "Unused commands", since a command name is no
  workspace data. The report runs as `agent:silta:dogfood-report`, whichever tool
  runs it.
  Failures before CLI environment setup are not logged and cannot appear here.
- **Repeated failures** means adjacent failures within the selected Silta stream for
  one agent actor/session.
- **Human load.** Approvals per ISO week and command. Proposals are accepted,
  dropped, or left untriaged past 14 days, each counted once; an agent withdrawing
  its own proposal is not triage and isn't counted; the oldest pending
  proposal shows what still waits. The first report's numbers are mostly the setup
  triage. Questions and inbox measurements are `n/a` until S11.

Generate into a temporary file **outside** the reports directory, so a newly
created filename cannot change the default range. Review it with the maintainer,
then add it as `docs/dogfood/reports/<Until date>.md` through a PR. Decide whether
findings need an issue, guide correction or no change. The script neither saves a
report nor creates issues.
