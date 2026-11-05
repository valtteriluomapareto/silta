# Building Silta with Silta

Setup was completed with the maintainer on 2026-11-04, which started DF0. Rerun
these steps only for a new machine or a fresh `~/.silta`. The maintainer does not
run CLI commands.

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

Follow the current stage's rules in [AGENTS.md](../../AGENTS.md#dogfooding). Since
DF1, questions, handoffs and review findings are `silta comment` threads on the
task; GitHub keeps the PR, its `Review:` pointer comment and the slice issue.

## Drive Codex from another agent

A coordinating agent can run Codex itself instead of asking the maintainer to paste
prompts:

1. Create Codex's worktree outside the repository, e.g.
   `git worktree add --detach ~/.codex/worktrees/<slice>/silta origin/main`. Tell Codex
   to create each branch with `git switch -c codex/<name> --no-track origin/main`:
   tracking a remote branch writes `.git/config`, which the sandbox refuses, and the
   switch then stops halfway. Codex pushes with `git push origin HEAD` and opens PRs
   with `--head`, so no upstream is needed.
2. Start Codex with `scripts/dogfood-codex.sh start <worktree> <log> <<'EOF'`, giving
   the slice prompt on stdin. Run it in the background: it returns when Codex's turn
   ends, then prints the thread id and Codex's last message.
3. That return is the signal, not polling. Check `silta --ws silta task show <ref>`:
   `review` means a PR is ready, and Codex's last message says what it did or needs.
   Review the PR, post each finding as a Silta thread on the task and a `Review:`
   pointer comment on the PR (see Reviews in AGENTS.md).
4. Send each review round to the same session, telling it to answer the open
   threads in `task show`, with
   `scripts/dogfood-codex.sh resume <worktree> <thread> <log> <<'EOF'`. It runs in the
   same worktree, so Silta sees the same actor and session.
5. After the merge, run `scripts/dogfood-finish.sh <ref> <pr>`, then
   `scripts/install-dev.sh`.

What the script fixes:
- **Identity.** It removes the caller's agent markers, session variables and tokens,
  and sets `SILTA_ACTOR=agent:codex`, so Silta records `agent:codex:<session>`.
- **Sandbox.** Codex runs with `approval_policy=never` in a workspace-write sandbox
  with network access. It may write its worktree, `SILTA_HOME` (default `~/.silta`),
  the repository's git objects, refs and logs, and its own worktree's git directory.
  It can't write git hooks or config, which would run outside the sandbox, so it
  pushes with `git push origin HEAD`, not `-u`. `scripts/verify.sh` turns off
  SwiftPM's and SwiftLint's own sandbox and cache when `CODEX_SANDBOX` is set.
- **Approvals.** Codex has no chat with the maintainer, and approval words relayed in a
  prompt never count (D38). So Codex never runs human-only commands in this mode: it
  stops and names them in its last message. The coordinating agent asks the maintainer
  in chat and runs them itself with `--approved "<their exact words>"`. A command that
  acts on Codex's own claim, such as `task start --steal`, runs from Codex's worktree
  with `SILTA_ACTOR=agent:codex`, so the claim stays Codex's.
- **Git setup.** After each run the script checks the worktree's `config.worktree` and
  git links. If Codex added any setting outside `codex.*`, or changed a link, it exits
  70: don't run git in that worktree, because git would read that setting outside the
  sandbox. Inspect it, then delete the worktree and run `git worktree prune`.
- **Interrupted git operations.** `packed-refs.lock` permission errors in Codex runs
  are expected noise: the repository's common git dir is outside the sandbox. If a run
  stops inside a cherry-pick, revert, merge, rebase or am, the script reports the
  leftover markers on stderr and the `--quit` commands that clear them outside the
  sandbox; run those before the next resume.
- **Split slices.** When a slice ships in parts, Codex starts and submits the part's
  subtask, and `dogfood-finish.sh` runs on that subtask. A subtask links no issue, so
  the slice issue stays open until its own task is done.

Driven runs use `gpt-6.1-sol` at `high` effort, set in the script, whatever the
maintainer's own Codex configuration says. With
`DOGFOOD_MODEL=fireworks:<model id>` and `FIREWORKS_API_KEY` set, the run uses that
Fireworks model through Codex's Responses API support instead, in the same sandbox;
Codex's shell commands never see the key. Verified with
`accounts/fireworks/models/deepseek-v4p1-flash-1017`.

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
