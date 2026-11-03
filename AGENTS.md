# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, OpenCode, …) working in this
repository. This file is the single source of truth; `CLAUDE.md` only points here.
When this file and a linked document disagree, fix one of them in the same change.
Don't leave the contradiction in place.

## What this repo is

Silta is a local context hub and backlog for coding agents: a Swift core library
(`SiltaCore`), a CLI (`silta`) that agents call through their shell, and later a
macOS app. The design is in [`docs/spec.md`](docs/spec.md). **Status: M1 in
progress; the package skeleton builds.** The first milestone (M1) is broken into slices in
[`docs/plans/m1-daily-use.md`](docs/plans/m1-daily-use.md).

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
| Finding any other doc | [`docs/README.md`](docs/README.md) |

## Verify ladder

Run the cheapest step that covers your change, and go by the exit code. Don't parse
verbose output.

| Change | Run |
|---|---|
| Markdown only | `scripts/run-guards.sh` (link check, plans board) |
| Swift code | `scripts/verify.sh quick` (guards, lint, build with warnings as errors, tests) |
| Storage, concurrency, location, agent-facing output | `scripts/verify.sh full` (adds stress and scenario tiers) |
| A guard script | `python3 -B -m unittest discover -s scripts/tests` (self-tests) |

Before saying something works, state which step you ran and what it doesn't prove.

## Hard invariants

Each invariant names the guard that enforces it. Don't weaken a guard to get a change
through. Fix the change, or propose a decision first.

1. **`SiltaCore` imports no UI or CLI frameworks.** That means no AppKit, SwiftUI,
   UIKit, Cocoa or ArgumentParser. Enforced by `check_core_boundary.py`, and in
   `Package.swift` by `check_package_graph.py`: `SiltaCore` depends only on GRDB and
   Yams.
2. **Core code gets time and ids from injected seams**, never from `Date()`,
   `Date.now` or `UUID()`. Enforced by `check_core_determinism.py`. Mark a deliberate
   exception with `// guard:allow-nondeterminism <reason>`.
3. **Tests never wait on the wall clock.** That means no `sleep`, `Task.sleep` or
   `asyncAfter`; use the fake clock. This covers `Tests/` and `SiltaTestSupport`.
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
   `Package.swift` enables the six Swift 7 upcoming features on every target and no
   experimental features without a decision; enforced by `check_package_features.py` (D29).
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

1. **Pick a slice** from the active plan whose dependencies are done. Each slice is
   independent enough for its own worktree and branch.
2. **Plan before coding** for anything beyond a small fix. Where the plan goes
   depends on the dogfooding stage (see Dogfooding below): on the slice's issue
   before DF0, in Silta from DF0 on, or in `docs/plans/` if it's larger. Then get it
   reviewed with `skills/persona-review`.
3. **Tests first** ([test-first flow](docs/coding-guidelines.md#test-first-flow)):
   - **A bug fix starts with a reproduction.** Write a test that fails for the
     reported reason and commit it first, wrapped in `withKnownIssue`. Then fix it.
   - **A feature starts from its acceptance tests**, in red → green → refactor steps.
   - **Goldens are written from the spec**, not generated from the code.
4. **Implement, verify, then get a review again** with the same reviewers.
5. **Commit** in imperative sentence case, under ~72 characters, ending with the
   `Co-Authored-By` trailer the harness gives you.
   - Branches are `<agent>/<slice>-<slug>`, e.g. `claude/s4-output-contract`.
   - Every change reaches `main` through a pull request, docs included. `main` is
     protected: squash merges only, and CI must pass on a branch that is up to date.
6. **Report honestly:** what changed, what you verified, and what remains unverified.

## Dogfooding

Silta is built with Silta as soon as it can be (spec §22.1, D20). **Current stage:
before DF0.** Update this line when a stage starts.

The DF0 instructions below take effect only after an agent completes
[setup with the maintainer](docs/dogfood/README.md) after the DF PR merges.

| Stage | Plans and steps | Questions and handoffs | Session start |
|---|---|---|---|
| Before DF0 | Comment on the slice issue | Comment on the slice issue | Read the issue and the plan |
| DF0 | One task per slice. Find it by the issue's `url:` link in `silta --ws silta task ls --proposed --promoted --archived --json`, then `silta --ws silta task start <ref>`. Only if no task links the issue: `silta --ws silta task add --start "<slice>: <title>" --app silta`, then `silta --ws silta task link <ref> url:<issue url>`. Plan with `silta --ws silta task plan <ref> -F - <<'EOF'`, tick with `task plan <ref> --step N --done`, finish with `task done <ref> -F - <<'EOF'` | Comment on the slice issue | `silta --ws silta task show <ref>` |
| DF1 | as DF0 | `silta comment <task> --kind question` / `--kind handoff` | as DF0 |
| DF2 | as DF0 | as DF1 | The hook runs `silta brief` |

From DF0 on, every command runs as `silta --ws silta …`:
- **Find the slice's task; never add a second one.** Imported tasks stay `proposed`
  until the maintainer triages them, plain `task ls` hides other sessions'
  proposals and tasks promoted to a tracker, and done or dropped tasks are archived
  after 14 days. So look for the issue's `url:` link in the
  `--proposed --promoted --archived --json` listing; the text listing shows no links. If the task is `proposed`, name
  `silta --ws silta task triage --accept <ref> --approved "<the human's words>"` to the
  maintainer and start it after they say yes. If it is `dropped`, ask the maintainer
  before doing anything.
- **Plans and results go through stdin.** Pass them with `-F -` and a quoted
  heredoc (`<<'EOF'`); never write a plan or result file into the repository.
- **A claimed slice.** If `task start` answers `claimed`, another session holds the
  task. The claim belongs to the whole actor, `agent:<tool>:<session>`, and the
  session comes from the worktree. So continue in the claiming worktree
  (`silta --ws silta task show <ref> --json` names it as `worktree`) with the same
  tool, or name
  `silta --ws silta task start <ref> --steal --approved "<the human's words>"` to the
  maintainer. Until DF1, tell the other session in a comment on the slice issue.
- **Work for the human.** Follow [spec §11](docs/spec.md#silta-guide) until
  `silta guide` ships. Put everything you need from the maintainer in one chat
  message. For a human-only command, name the exact command, wait for their yes,
  and run it with `--approved "<their exact words>"`. Never write those words
  yourself.
- **Use the dogfood binary.** Always use `~/.local/bin/silta`, built from `main` by
  `scripts/install-dev.sh`; rerun it after pulling `main`. Never use a binary from
  your own worktree.
- **Record friction.** End every `done` result in the `silta` workspace with one line:
  `Friction: none`, or `Friction: <what was awkward>`. Friction that needs its own
  fix, or that comes up outside a task, also gets
  `silta --ws silta task add "<what was awkward>" --topic dogfood`. That task is a
  proposal, so it counts toward the two proposals per session
  ([spec §11](docs/spec.md#silta-guide)); put anything
  beyond that in the `Friction:` line.
- **Close the issue.** When a slice's task is done, post its result on the GitHub
  issue and close the issue.

## Parallel agents and worktrees

- Claude worktrees live in `.claude/worktrees/` (git-ignored). Codex worktrees live
  outside the repo.
- Two agents never work on the same slice. Shared files are `Package.swift`, the
  migrations and the error-code table, so coordinate through the plan before
  touching them.
