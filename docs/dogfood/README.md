# Building Silta with Silta

These instructions take effect after the DF PR merges and an agent completes setup
with the maintainer in chat. The current stage stays **before DF0** until that has
happened. The maintainer does not run CLI commands.

## Setup with an agent

1. Use a clean checkout of `main`. Run `scripts/install-dev.sh`; it prints the built
   commit and installs `silta` into `~/.local/bin`. Tests use `SILTA_INSTALL_DIR` and
   temporary homes. Put `~/.local/bin` on PATH for these scripts.
2. From the repository root, run `silta init --scan "$PWD"`. Show
   [workspace.yaml](workspace.yaml) to the maintainer and name the exact next
   command: `silta ws edit silta -F docs/dogfood/workspace.yaml`. After their reply,
   run it with `--approved "<their actual reply>"`. Then run `silta ws use silta`.
   Local repo paths stay in the database and are absent from this YAML.
3. Run `scripts/dogfood-import-issues.sh`. It enumerates all open slice issues,
   creates app-bound proposals and links their URLs. It skips links that already
   exist, including archived tasks and proposals from other sessions. If linking
   fails after creation, run the printed repair before rerunning the import.
4. Show the imported proposals in one batch with
   `silta --ws silta task ls --proposed`. Name the printed `task triage --accept`
   command with its concrete refs, ask once, and run it with the maintainer's actual
   reply in `--approved`. Never invent approval words or claim every imported task.
5. In a fresh agent session, exercise the installed binary on the chosen slice:
   start its existing task, store a plan, tick a step and finish with a result.
   Only after real setup works should the stage line in AGENTS.md change to DF0
   through a PR.

Do not add `proposals` or `ask_about` to the workspace YAML until S11 and S13 ship
those keys. The maintainer can choose them with the agent then. The initial import
runs before that choice; it does not implement those policies itself.

## Work a slice

Use `~/.local/bin/silta`, never a binary built in your feature worktree. Find the
slice's imported task in `silta --ws silta task ls` and run
`silta --ws silta task start <ref>`. Only if it is absent, create it with
`silta --ws silta task add --start "<slice>: <title>" --app silta`, then
`silta --ws silta task link <ref> url:<issue-url>`. Keep one dogfood task per slice.

Keep the plan with `task plan <ref> -F <file>`, tick with
`task plan <ref> --step N --done`, and finish with `task done <ref> -F <file>`.
Use the `silta --ws silta` prefix for each command. Follow
[Working for the human](../spec.md#silta-guide) until `silta guide` ships: batch
human decisions in chat, name gated commands before asking, and quote only the
human's actual reply. Questions and handoffs stay on the slice issue until DF1.

Every `done` result in the `silta` workspace ends with exactly one line:
`Friction: none`, or `Friction: <what was awkward>`. A problem needing its own fix
also becomes `silta --ws silta task add "<what was awkward>" --topic dogfood`.
The rule is for this workspace. It does not impose friction reporting on others.

Post the result on the slice issue and close it when the task is done.

## Review friction

Once per wave, and at least every 60 days, an agent runs
`scripts/dogfood-report.sh` with the maintainer. It prints Markdown from the `silta`
workspace. It counts untagged log lines without printing their content, excludes
its own actor, and includes approvals per ISO week and command. “Repeated failures”
means adjacent failures within the selected Silta stream for one agent actor/session;
other workspaces are omitted. A historical proposal window expiry remains counted
if it was triaged later. Questions and inbox measurements are `n/a` until S11.

`--since YYYY-MM-DD` is inclusive in UTC. Without it, the newest date-named file in
[reports](reports/README.md) supplies the date; without a prior report, all retained
logs and task history are considered. Logs retain only 90 days. Failures before
CLI environment setup are not logged and cannot appear here.

Generate into a temporary file **outside** the reports directory, so a newly
created filename cannot change the default range. Review it with the maintainer,
then add it as `docs/dogfood/reports/YYYY-MM-DD.md` through a PR. Decide whether
findings need an issue, guide correction or no change. The script neither saves a
report nor creates issues.
