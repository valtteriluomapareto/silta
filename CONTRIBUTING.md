# Contributing

This covers setup, commands and the merge workflow. Agents should start with
[`AGENTS.md`](AGENTS.md); this file holds the details it links to.

## Toolchain

| Tool | Version | Where it's pinned |
|---|---|---|
| Xcode / Swift | Xcode 27.1 (Swift 6.4) | [`.xcode-version`](.xcode-version) |
| SwiftLint | 0.65.1 | [`scripts/ci/install-swift-tools.sh`](scripts/ci/install-swift-tools.sh) |
| swift-format | 603.0.0 | same |
| Python | system `python3` | used only by the guard scripts |

CI selects exactly this Xcode (`scripts/ci/select-xcode.sh`) and installs the
SHA-checked tools. Locally, `brew install swiftlint swift-format` is enough. If a
lint result differs from CI, trust CI's pinned versions.

## Commands

| Command | What it does | What it doesn't prove |
|---|---|---|
| `scripts/run-guards.sh` | Repository guards: core boundary, determinism, test waits, plan references, docs links, plans board | That the code builds or behaves |
| `python3 -B -m unittest discover -s scripts/tests` | Guard self-tests: each guard passes a clean tree and fails a planted violation | — |
| `scripts/lint-check.sh` | swift-format and SwiftLint in `--strict` mode, no changes | Behaviour |
| `scripts/lint-fix.sh` | Apply swift-format and SwiftLint fixes | — |
| `scripts/verify.sh quick` | Guards, lint, `swift build` with warnings as errors, `swift test` (a run with zero tests fails) | Concurrency under load, wall-clock deadlines, real agent use |
| `scripts/verify.sh full` | `quick` plus stress/scenarios (`SILTA_SLOW_TESTS=1`), then the wall-clock hook and Git deadline tier (`SILTA_DEADLINE_TESTS=1`, the `WallClock…` suites) alone and serially | Real agent use (spec §21 evals) |

Before a Swift package exists, the build and test steps report "skipped" and the
guards still run.

## Workflow

1. **Issue or slice.** Work starts from a slice in the active plan, or from a GitHub
   issue that names one.
2. **Plan.** Anything beyond a small fix gets a written plan. Follow the current
   [dogfooding stage](AGENTS.md#dogfooding) for its location; larger plans use
   `docs/plans/` and its template.
3. **Plan review.** Three independent reviewer subagents (Architect, Tester,
   Pragmatism) review the plan, using [`skills/persona-review`](skills/persona-review/SKILL.md).
   A fourth, Agent experience, joins when the change touches agent-facing output.
   One agent playing several personas doesn't count. If subagents aren't available,
   say so in the PR.
4. **Tests first**, following the
   [test-first flow](docs/coding-guidelines.md#test-first-flow).
   - A bug fix starts with a committed reproduction that fails for the reported
     reason (`withKnownIssue`).
   - A feature starts from its acceptance tests.
   - A PR labelled `bug` must change a test; CI checks this.
5. **Implementation review** by the same reviewers. Fix or answer every finding.
6. **Merge** on green CI for the current head. Use squash merges titled
   `<slice or #issue> <type>: summary`, e.g. `S4 feat: JSON envelope and exit codes`.
   `main` is protected (D19): the branch must be up to date with `main`, so rebase or
   merge `main` in when GitHub asks. `gh pr merge --auto --squash` queues the merge for
   when CI passes.

## Branches and commits

- **Branches:** `<agent>/<slice>-<slug>`, e.g. `claude/s7-where`, `codex/s8-code-show`,
  or `docs/<slug>` for documentation.
- **Commits:**
  - imperative, sentence case, under ~72 characters, e.g. "Add JSON envelope for
    errors"
  - a body that explains why when it isn't obvious
  - the `Co-Authored-By` trailer for agent-written commits
- **Golden output:** a change to golden files (guide text, JSON, error messages) says
  so in the commit body: "Golden update: …".

## Definition of done

- [ ] `scripts/verify.sh quick` passes, or `full` for storage, concurrency, location
      and agent-facing changes.
- [ ] New behaviour has tests written first; a bug fix has a reproduction that failed first
      (PR field "Test-first evidence").
- [ ] Spec, decisions and plan board are updated when behaviour or scope changed.
- [ ] Agent-facing changes have updated goldens and an agent-experience review.
- [ ] The PR says what remains unverified.
