# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, OpenCode, …) working in this
repository. This file is the single source of truth; `CLAUDE.md` only points here.
When this file and a linked document disagree, fix one of them in the same change.
Don't leave the contradiction in place.

## What this repo is

Silta is a local context hub and backlog for coding agents: a Swift core library
(`SiltaCore`), a CLI (`silta`) that agents call through their shell, and later a
macOS app. The design is in [`docs/spec.md`](docs/spec.md). **Status: pre-code.** The
first milestone (M1) is broken into slices in
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
   UIKit, Cocoa or ArgumentParser. Enforced by `check_core_boundary.py`.
2. **Core code gets time and ids from injected seams**, never from `Date()`,
   `Date.now` or `UUID()`. Enforced by `check_core_determinism.py`. Mark a deliberate
   exception with `// guard:allow-nondeterminism <reason>`.
3. **Tests never wait on the wall clock.** That means no `sleep`, `Task.sleep` or
   `asyncAfter`; use the fake clock. Enforced by `check_test_waits.py`.
4. **Code comments don't refer to plans, phases, milestones or review rounds.**
   Enforced by `check_no_plan_refs.py`.
5. **No crashes or hidden state in shipped code.** That means:
   - no stored `static var` or top-level `var` in `SiltaCore`
   - no `print`/`os` logging in `SiltaCore`
   - `try?` only with a reason on the same line
   - no `try!`, `as!`, force unwraps or IUOs in `Sources/`

   Enforced by `check_core_hygiene.py`, `check_try_optional.py` and SwiftLint
   (D21, D22, D27).
   `Package.swift` enables the six Swift 7 upcoming features on every target and no
   experimental features without a decision; enforced by `check_package_features.py` (D29).
6. **Relative links in markdown resolve.** Enforced by `check_docs_links.py`.
7. **The plans board in `docs/README.md` mirrors `docs/plans/` one-to-one.** Enforced
   by `check_plans_board.py`.
8. **Agent-facing output is a contract.** This covers `silta guide` text, `--json`
   shapes, error codes and exit codes. They change only together with their golden
   tests and an agent-experience review (spec §16, §20, §21; D16).

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
   - Until the first code lands, small documentation changes may go straight to
     `main`.
6. **Report honestly:** what changed, what you verified, and what remains unverified.

## Dogfooding

Silta is built with Silta as soon as it can be (spec §22.1, D20). **Current stage:
before DF0.** Update this line when a stage starts.

| Stage | Plans and steps | Questions and handoffs | Session start |
|---|---|---|---|
| Before DF0 | Comment on the slice issue | Comment on the slice issue | Read the issue and the plan |
| DF0 | `silta task add --start "<slice>: <title>"` (link the issue), `silta task plan`, `--step N --done`, `done --result` | Comment on the slice issue | `silta task show <id>` |
| DF1 | as DF0 | `silta comment <task> --kind question` / `--kind handoff` | as DF0 |
| DF2 | as DF0 | as DF1 | The hook runs `silta brief` |

From DF0 on:
- **Use the dogfood binary.** Always use `~/.local/bin/silta`, built from `main` by
  `scripts/install-dev.sh`. Never use a binary from your own worktree.
- **Record friction.** Anything awkward is recorded with
  `silta task add "<what was awkward>" --topic dogfood`.
- **Close the issue.** When a slice's task is done, post its result on the GitHub
  issue and close the issue.

## Parallel agents and worktrees

- Claude worktrees live in `.claude/worktrees/` (git-ignored). Codex worktrees live
  outside the repo.
- Two agents never work on the same slice. Shared files are `Package.swift`, the
  migrations and the error-code table, so coordinate through the plan before
  touching them.
