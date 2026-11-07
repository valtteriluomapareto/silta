# DF3: Silta in a real multi-repo workspace

Status: proposed

## Goal

The maintainer and their agents use Silta every day for six weeks in a real
multi-repo workspace. At the end, decision rules written in advance say whether the
brief helps, whether agents use Silta correctly, and what costs too much. No
workspace data leaves the machine.

## Inputs

- Spec §19 (logs), §22.1 (dogfooding, DF3), §23 Q8 (code access), Appendix A
  (`init --scan`, `ws edit`).
- D36 (friction as data) and its update, D37 (human load), D38 (approval words), D39
  (settings; "Not now" rejects a `Friction:` setting).
- [M1 plan](m1-daily-use.md).

## Scope

- **In scope:** choosing the workspace's slug at scan time, a private report for any
  workspace, the onboarding run with its setup prompt, the check-in, and the decisions
  at the end.
- **Out of scope:**
  - A gap-review command. The setup prompt lists gaps from `ws show`. Build the command
    only if a second onboarding needs it.
  - A `Friction:` setting. D39 rejected it, and in employer repos agents copy task
    results into PRs, so Silta's complaints would reach the team. Friction comes from
    the check-in and the logs instead.
  - The `code` comparison. It belongs to §23 Q8 and S16; DF3 only counts `code` calls.
  - Harness transcripts. They are private and need their own tooling. Signals that
    only transcripts could show come from the check-in instead.

## Start

DF3 starts after S13 (agents install and guide) and SI-15 (inbox) merge, not after all
of M1. This changes §22.1 and the M1 plan, which said "M1 done":
- **S14 (export and restore) isn't needed.** Daily `VACUUM INTO` backups exist. Before
  real data goes in, the maintainer's agent drills one restore of a snapshot into a
  temporary `SILTA_HOME` and runs `doctor` on it. A restore replaces the whole
  database, the `silta` workspace included; that is acceptable for one maintainer.
- **S16 (evals) isn't needed.** Fixture evals and real use are separate signals.
- **M1 keeps changing during DF3.** Every check-in records the installed binary's
  commit, so a change in behaviour can be matched to a change in the numbers.

## What we decide, and from what

Each row gets its threshold during onboarding, before day zero. An agent may suggest
the numbers; the maintainer decides them.

| # | Question | Source | Decision rule (example) |
|---|---|---|---|
| E1 | Does the brief give agents the right context? | Brief audit: lines marked wrong, stale or missing | Change the brief if more than 1 in 5 audited lines is wrong or stale |
| E2 | Does the maintainer explain less? | Check-in tally, compared with the week without the hook | Keep the hook only if the tally is lower with it than without |
| E3 | Do agents use Silta correctly without reminders? | Logs: calls per session, `usage` error rate, retry loops | Fix guide text if `usage` errors exceed 10% of calls |
| E4 | What does it cost? | Logs (hook ms, approvals per week); check-in question 3 | Change whatever the maintainer names twice as nearly making them stop |
| E5 | Does the workspace data stay current? | Gap list at weeks 0, 2 and 6 | Rethink upkeep if gaps grow between reviews |

`code` calls per cross-repo task are counted for §23 Q8, which owns that decision.
Counts are normalised per agent session and per active day.

## Data and privacy

- **Everything stays local.** The workspace's tasks, comments, logs, reports and
  check-ins stay in `~/.silta`. Nothing from it goes into the Silta repo, its issues,
  fixtures or evals.
- **Private report.** `scripts/dogfood-report.sh --ws <slug>` reports on any
  workspace. It validates the slug before using it, and writes the report and its
  `--since` state under `$SILTA_HOME/reports/<slug>/`, outside every repository. The
  `silta` workspace keeps today's behaviour.
- **What may leave the machine:** a summary the agent writes by hand from the report,
  reviewed by the maintainer, containing only Silta's own words: command names, error
  and warning codes, counts and rates. No actors, sessions, task refs, slugs, app or
  repo names, dates of individual tasks, or friction text.
- **Check-in.** One task in the workspace, `DF3 check-in`, created during onboarding
  with the maintainer's words (so it is `todo` without triage), then blocked on
  `ext:maintainer` with `--follow-up 7d`, so the inbox shows it when it's due. A blocked task stays out of
  "work the backlog". Each week the agent asks three questions in one message, posts
  the answers as one comment and blocks the task again:

  ```text
  Check-in: week=N binary=<sha7> hook=on|off explained=N corrections=N
  Helped: <task ref or none>  Misled: <task ref or none>
  Nearly stopped because: <one line or none>
  ```

  A skipped week stays missing; it is never counted as zero. If two check-ins in a row
  are skipped, shorten the questions.
- **Misses as they happen (optional).** When the maintainer tells an agent "Silta
  missed this", the agent adds one line to the check-in task: `Miss: <what>`. That is
  more reliable than a weekly recall.
- **Brief audit.** Every two weeks the agent runs `brief` for one real task and shows
  it. The maintainer marks only the wrong, stale or missing lines.
- **A week without the hook.** In week 4, `silta agents uninstall` removes the hook;
  `agents install` restores it after that week. The same check-in runs, so E2
  compares with and without the hook on similar work, without a separate baseline
  period before the start.

## Taking it into use

1. **Choose a small scope:** two to four related repos with real cross-repo work, the
   workspace slug and the task prefix.
2. **Install and configure:** follow [getting started](../getting-started.md). Agent
   installation and removal are previews until rerunning the printed command with
   `--apply <token>`. Those changes write only user-level files, never the team's repos;
   check that a session in an unregistered repo prints nothing and that the hook stays
   inside its 1.5 s budget. A scan of a whole projects directory registers every clone
   under it.
3. **Fill the workspace with an agent,** using the setup prompt below.
4. **Turn on measurement:** create the check-in task, write the decision rules into
   it as its description, and run the first private report as week 0.
5. **Roll back if needed:** preview `silta agents uninstall`, then apply the preview's
   token; the hook and blocks are removed and the data stays.

**Setup prompt (draft; it becomes `silta guide setup` after it has worked once):**

```text
Help me fill the Silta workspace <slug>. Use `silta --ws <slug>` for every command.
Never put secrets, customer data or credentials into it: nothing scans this YAML.

1. Run `silta --ws <slug> ws show`. List the gaps: apps without a summary or prod
   ref, apps with no environments or edges, repos without apps.
2. For each app, read the first 60 lines of its README and AGENTS.md (or CLAUDE.md) with
   `silta --ws <slug> code show <app> --lines 1-60 -- README.md`. Draft its summary,
   environments, prod ref and the apps or services it calls. Don't search the repos
   further.
3. Ask me in one message about what you couldn't tell from the files, and about the
   settings `proposals` and `ask_about`. Don't apply anything yet.
4. Write the complete YAML, starting from `ws show` (omitted rows are deleted). Show
   it and name the exact command:
   `silta --ws <slug> ws edit -F - --approved "<your words>"`. Ask me to reply yes.
5. Run it only with my exact reply as the approval words. If validation fails and
   you change the YAML, show it and ask again.
6. List the gaps that remain once. Don't ask about them again.
```

## Slices

| Slice | Scope | Depends on | Verify with |
|---|---|---|---|
| DF3-a Slug at scan | `init --scan … --slug <slug> --prefix <XX>` for a new workspace; refused on a rescan or with `--ws` | S6 | Goldens: chosen slug and prefix, defaults unchanged, refusal on a rescan, invalid slug |
| DF3-b Private report | `--ws <slug>` on `dogfood-report.sh`; validated slug; output and `--since` state under `$SILTA_HOME/reports/<slug>/` | — | Existing report tests pass; output lands under `$SILTA_HOME/reports/<slug>/` and never in the repository; canary strings from another workspace never reach the `silta` report; an invalid slug is refused |
| DF3-c Onboarding run | The restore drill, the steps above, six weeks of use, two report reviews, the decisions | DF3-a, DF3-b, S13, SI-15 | The check-ins and the reports at weeks 0, 2 and 6 |
| DF3-d `silta guide setup` | The setup prompt as it worked in DF3-c | DF3-c | Guide golden |

DF3-a and DF3-b are small and can run in parallel with M1 slices. None blocks M1.

## Validation

- Before real data: the restore drill, DF3-b on the `silta` workspace, one check-in
  cycle there (create, answer, block again) to settle the exact commands, and one run
  of the setup prompt on the eval fixtures.
- At weeks 2 and 6: generate the private report, review it with the maintainer, apply
  the decision rules, and turn findings into Silta issues through the shareable
  summary only.
- **Unverified:** one maintainer is a small sample, the tally is self-reported, and
  the hook-off week is a single week. The decisions say how strong their evidence was.

## Risks

- **Workspace data leaks into this repo** through a report, an issue or a fixture. The
  report writes under `$SILTA_HOME`, and the shareable summary contains only Silta's
  own words.
- **The measurement burden ends the experiment.** One message a week, one brief audit
  every two weeks; skipped check-ins shorten the questions.
- **The hook disturbs work in other repos.** Step 2 checks silence outside
  registered repos, and rollback is one command.
- **A migration damages real data** while M1 keeps shipping. The restore drill comes
  first, and migrations are only ever added (§22.1).

## Done when

- Six weeks of use, with the check-ins, the hook-off week and reports at weeks 0, 2
  and 6.
- A keep, change or cut decision recorded for E1–E5, using the rules set at the start.
- The setup prompt lives in `silta guide setup` (DF3-d), the lasting rules are in
  §22.1, and the spec's other DF3 items (meeting-note tasks, secret guard and
  branch-as-app in real use) are either done or moved. Then delete this plan.
