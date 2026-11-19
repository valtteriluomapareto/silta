# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, OpenCode, …) working in this
repository. This file is the single source of truth; `CLAUDE.md` only points here.
When this file and a linked document disagree, fix one of them in the same change.
Don't leave the contradiction in place.

## What this repo is

Silta is a local context hub and backlog for coding agents: a Swift core library
(`SiltaCore`), a CLI (`silta`) that agents call through their shell, and later a
macOS app. The design is in [`docs/spec.md`](docs/spec.md). **Status: M1 in
progress.** The first milestone (M1) is broken into slices in
[`docs/plans/m1-daily-use.md`](docs/plans/m1-daily-use.md). What each target and
folder holds is in [coding guidelines §5](docs/coding-guidelines.md#5-layout-and-naming-d25).

## Where to find what

| Doing this… | Read this |
|---|---|
| Understanding the product or a behaviour | [`docs/spec.md`](docs/spec.md); the section numbers (§n) are stable |
| Writing Swift code (concurrency, errors, seams, tests, logging) | [`docs/coding-guidelines.md`](docs/coding-guidelines.md) |
| Checking why something is the way it is | [`docs/decisions.md`](docs/decisions.md) (D1, D2, …) |
| Picking up work | [`docs/plans/m1-daily-use.md`](docs/plans/m1-daily-use.md): take a slice whose dependencies are done |
| Writing or updating a plan | [`docs/plans/README.md`](docs/plans/README.md) and [`_template.md`](docs/plans/_template.md) |
| Building, testing, linting, merging | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| Reviewing a plan or an implementation | [`skills/persona-review/SKILL.md`](skills/persona-review/SKILL.md) |
| Handing a slice to another agent | [`docs/agent-brief.md`](docs/agent-brief.md) |
| Using Silta on this repo, driving Codex, friction reports | [`docs/dogfood/README.md`](docs/dogfood/README.md) |
| Finding any other doc | [`docs/README.md`](docs/README.md) |

## Verify ladder

Run the cheapest step that covers your change, and go by the exit code. Don't parse
verbose output.

| Change | Run |
|---|---|
| Markdown only | `scripts/run-guards.sh` (link check, plans board) |
| App UI or Xcode project | `scripts/verify.sh app` (guards, lint, native Debug acceptance, Release build) |
| Swift code outside `App/` | `scripts/verify.sh quick` (guards, lint, build with warnings as errors, tests) |
| Storage, concurrency, location, agent-facing output | `scripts/verify.sh full` (adds stress, scenario and compatibility tiers, the wall-clock deadline tier alone, then the eval replays) |
| `Evals/` (offline eval tooling) | `scripts/verify.sh evals` (builds the CLI, then the eval replay tests) |
| A guard script | `python3 -B -m unittest discover -s scripts/tests` (self-tests) |

Before saying something works, state which step you ran and what it doesn't prove.

## Hard invariants

Each invariant names the guard that enforces it. Don't weaken a guard to get a change
through. Fix the change, or propose a decision first.

1. **`SiltaCore` imports no UI or CLI frameworks.** That means no AppKit, SwiftUI,
   UIKit, Cocoa or ArgumentParser. Enforced by `check_core_boundary.py`, and in
   `Package.swift` by `check_package_graph.py`: `SiltaCore` depends only on GRDB and
   Yams. The app imports SiltaAppSupport and Apple frameworks, enforced by
   `check_app_boundary.py`. `check_app_pins.py` keeps shared dependency pins aligned.
   `check_control_release.py` requires whole-file DEBUG isolation for control sources.
2. **Core code gets time and ids from injected seams**, never from `Date()`,
   `Date.now` or `UUID()`. Enforced by `check_core_determinism.py`. Mark a deliberate
   exception with `// guard:allow-nondeterminism <reason>`.
3. **Tests never wait on the wall clock.** That means no `sleep`, `Task.sleep` or
   `asyncAfter`; use the fake clock. This covers `Tests/`, `App/SiltaAppTests` and `SiltaTestSupport`.
   Enforced by `check_test_waits.py`.
4. **Code comments don't refer to plans, phases, milestones or review rounds.**
   Enforced by `check_no_plan_refs.py`.
5. **No crashes or hidden state in shipped code.** That means:
   - no stored `static var` or top-level `var` in `SiltaCore`
   - no `print`/`os` logging in `SiltaCore`
   - `try?` only with a reason on the same line
   - no `try!`, `as!`, force unwraps or IUOs in `Sources/`

   Enforced by `check_core_hygiene.py`, `check_try_optional.py` and SwiftLint
   (D21, D22, D27).
   Errors in `SiltaCore` and the CLI conform to `CodedError`, never to `Error`
   directly; enforced by `check_coded_errors.py` (D22, D30).
   Every SwiftPM target and native app configuration enables the six Swift 7 upcoming
   features. SwiftPM experimental features require a decision. `check_package_features.py`
   enforces both (D29).
6. **Relative links in markdown resolve.** Enforced by `check_docs_links.py`.
7. **The plans board in `docs/README.md` mirrors `docs/plans/` one-to-one.** Enforced
   by `check_plans_board.py`.
8. **Agent-facing output is a contract.** This covers `silta guide` text, `--json`
   shapes, error codes and exit codes. They change only together with their golden
   tests and an agent-experience review (spec §16, §20, §21; D16).
9. **Test support stays out of production.** Only test targets depend on
   `SiltaTestSupport`, no product exposes it, and nothing depends on the `silta`
   executable: CLI tests run the built binary. Enforced by `check_package_graph.py`
   (D23).

## Never

- Run anything against your real `~/.silta`. Tests and scripts set `SILTA_HOME` to a
  temporary directory.
- Edit a migration that has shipped. Add a new one.
- Regenerate golden files to make a failing test pass without understanding why.
  Golden updates are deliberate and called out in the commit.
- Add fixtures, fake knobs or JSON fields only to make a scenario pass.
- Commit customer or employer data: real repo names, hosts, people or notes. Examples
  use the fictional Acme workspace.
- Push, force-push, change GitHub settings or create issues and releases unless the
  user asks.

## Writing code comments and docs

- Describe what the code must do and why, as it is now. Don't narrate how it got
  there ("previously", "now uses", "after the refactor").
- No plan or review references in code ("phase 2", "review item 4", "per M1").
  Stable ids like `D12` or `spec §7` are fine in docs.
- Prefer one place for each fact. Link instead of copying.

## Workflow

1. **Pick a slice** from the active plan whose dependencies are done. One slice is
   one PR, in its own worktree and branch.
2. **Plan briefly** in the slice's Silta task (see Dogfooding below), or in
   `docs/plans/` if the work spans several slices. Get the plan reviewed before
   coding only when the change adds a target or package dependency, touches storage,
   migrations or concurrency, changes agent-facing output, or adds a mechanism other
   code will build on. Anything else goes straight to tests.
3. **Tests first** ([test-first flow](docs/coding-guidelines.md#test-first-flow)):
   - **A bug fix starts with a reproduction.** Write a test that fails for the
     reported reason and commit it first, wrapped in `withKnownIssue`. Then fix it.
   - **A feature starts from its acceptance tests.** It needs no separate red commit;
     name the tests in the PR.
   - **SwiftUI views** get view-model tests written with the view. Check the layout by
     looking at it.
   - **Goldens are written from the spec**, not generated from the code. Help goldens are
     reviewed against the help standard in [coding guidelines](docs/coding-guidelines.md).
4. **Implement, verify, then get one implementation review** (see Reviews below).
5. **Commit** in imperative sentence case, under ~72 characters, ending with the
   `Co-Authored-By` trailer the harness gives you.
   - Branches are `<agent>/<slice>-<slug>`, e.g. `claude/s4-output-contract`.
   - Every change reaches `main` through a pull request, docs included. `main` is
     protected: squash merges only, and CI must pass on a branch that is up to date.
6. **Report briefly and honestly:** what someone can run now, what changed, what you
   verified, what remains unverified and what's next.

## Keep it lean

- **Write the smallest change that passes the acceptance tests.** Add options,
  routes, fields, protocols and edge-case handling when a caller or a test needs
  them, not for a later slice.
- **Split only when you must.** A slice that will go past about 1,000 lines may
  become subtasks, one PR each. Subtasks don't get subtasks.
- **Plant a fault only to prove a guard or a safety test isn't vacuous** (isolation,
  limits, refusals), once per rule. Ordinary behaviour doesn't need it.
- **Merge `main` into your branch only** for a conflict, for something that just
  landed and that you need, or once before merging.
- **When stuck, say so.** After about an hour without a commit, stop and tell the
  maintainer what blocks you, in two lines.

## Reviews

Reviews use independent subagents, scaled to the change: one reviewer for docs and
small fixes, Architect and Tester for most changes, plus Pragmatism and Agent
experience where they apply. The table and the rules are in
[`skills/persona-review`](skills/persona-review/SKILL.md) (D16). Re-review only
blocker and major findings.

## Dogfooding

Silta is built with Silta (spec §22.1, D20). **Current stage: DF1** (since
2026-11-05; [setup](docs/dogfood/README.md)). Update this line when a stage starts.
From DF2 the session-start hook runs `silta agents session-start`; until then, start
with `silta --ws silta task show <ref>`.

Every command runs as `silta --ws silta …` with `~/.local/bin/silta`, which
`scripts/install-dev.sh` builds from `main`. Rerun that script after pulling `main`,
and never use a binary from your own worktree. It also builds and installs
`~/Applications/Silta Dev.app` with Xcode; if either build fails, it keeps both
previous installs.

- **Find the slice's task; never add a second one.** Look for the issue's `url:`
  link in `task ls --proposed --promoted --archived --json`. Plain `task ls` hides
  proposals, promoted and archived tasks, and the text listing shows no links.
  - Only if no task links the issue: `task add --start "<slice>: <title>" --app silta`,
    then `task link <ref> url:<issue url>`.
  - If the task is `proposed`, name
    `silta --ws silta task triage --accept <ref> --approved "<the human's words>"` to
    the maintainer and start it after they say yes.
  - If it is `dropped`, ask the maintainer before doing anything.
- **Claim, plan, submit.**
  1. `task start <ref>`.
  2. Plan with `task plan <ref> -F - <<'EOF'`, and tick each step with
     `task plan <ref> --step N --done` as soon as it's done. Plans and results always
     go through stdin with a quoted heredoc; never write a plan or result file into
     the repository.
  3. When the PR is open, end its description with `## Draft result`: the result as
     it should read once merged, ending with the `Friction:` line.
  4. `task submit <ref>`. Never `task done` before the merge.
- **Questions and handoffs:** `comment <ref> --kind question --to <actor> -F -` and
  `--kind handoff -F -`. Answer with `--kind answer --reply-to <question ref>`; the
  asker accepts with `comment accept <answer ref>`. Ask a human who is in the chat
  there, not as a Silta question.
- **A claimed slice.** If `task start` answers `claimed`, another session holds the
  task. The claim belongs to the whole actor, `agent:<tool>:<session>`, and the
  session comes from the worktree. So continue in the claiming worktree
  (`task show <ref> --json` names it as `worktree`) with the same tool, or name
  `silta --ws silta task start <ref> --steal --approved "<the human's words>"` to the
  maintainer. Tell the other session with a comment on the task.
- **Work for the human.** Follow `silta guide human`
  ([spec §11](docs/spec.md#silta-guide)). Put everything you need from the maintainer
  in one chat message. For a human-only command, name the exact command, wait for
  their yes, and run it with `--approved "<their exact words>"`. Never write those
  words yourself. A run started by another agent
  ([dogfood README](docs/dogfood/README.md#drive-codex-from-another-agent)) has no
  chat with the maintainer: it never runs human-only commands, and names them in its
  last message instead.
- **Record friction.** End every `done` result in the `silta` workspace with
  `Friction: none` or `Friction: <what was awkward>`. Friction that needs its own fix
  also gets `task add "<what was awkward>" --topic dogfood`. That is a proposal, and
  a session gets two ([spec §11](docs/spec.md#silta-guide)); put anything beyond that
  in the `Friction:` line.
- **Reviews run as Silta threads.** The reviewer posts each blocker or major finding
  as its own root comment (`comment <ref> -F -`), never as a reply to a handoff, and
  lists minor findings in one more comment. On the PR, one comment
  `Review: changes (round N)` points to `task show <ref>`. The author runs
  `task start <ref>` again (D41), fixes on the same PR, and answers each thread with
  one reply (`--reply-to <root ref>`): what changed and the test that proves it, not
  a commit hash. Then the author updates the draft result and submits again. Only the
  reviewer resolves threads (`comment resolve <ref>… -m`), once the follow-up review
  confirms the fix. Approval is a PR comment starting `Review: approve`.
- **Finish after the merge.** Whoever merges the PR pulls `main`, then runs
  `scripts/dogfood-finish.sh <ref> <pr>` and `scripts/install-dev.sh` from the main
  checkout. The script runs `task done` with the merge commit and the PR's draft
  result, posts the result on the slice issue and closes it. So a PR that only plans
  work gets its own subtask; finishing it must not close the work it plans.

## Mac app verification

Use `scripts/silta-app.sh launch --route …` to reach a state in a private Debug
fixture. Read its `state.json` through `state` or use `wait` for a predicate. Use
offscreen snapshots for layout and an owned-window `shot` for glass when available.
Stop only the fixture run you launched. See the [control-plane guide](docs/plans/mac-app-control.md#drive-a-fixture-from-the-terminal)
for commands and evidence. Real UI checks never block a PR.

## Parallel agents and worktrees

- Claude worktrees live in `.claude/worktrees/` (git-ignored). Codex worktrees live
  outside the repo.
- Two agents never work on the same slice. Shared files are `Package.swift`, the
  migrations and the error-code table, so coordinate through the plan before
  touching them.
