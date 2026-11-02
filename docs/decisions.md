# Decisions

Numbered decisions, cited as `D#` in docs, plans and reviews. The numbers are never
reused. Change a decision by adding a dated **↳ update** line under it, or by
superseding it with a new entry that says "supersedes D#".

D1–D10 are the core product decisions, explained in [`spec.md` §4](spec.md#4-core-design-decisions).
They're summarised here so every decision has one index.

## Product

- **D1: SQLite is the source of truth.** It holds everything Silta owns. YAML is only
  an editing view of the configuration (`silta ws edit`).
- **D2: External sources are indexed, never owned.** That means meeting notes and repo
  docs.
- **D3: Deterministic export** to a text tree for backup and diff. `restore` replaces
  a workspace.
- **D4: CLI only, `--json` everywhere.** No MCP server and no daemon.
- **D5: Agent writes are gated.** Unsolicited tasks start as `proposed`, doc edits are
  proposals, and some commands are human-only.
- **D6: Silta resolves "where am I"** from cwd, branch, upstream and claimed task.
- **D7: Code access is read-only**, through `git show`, `grep` and `log` on
  configured refs.
- **D8: Truth (`silta.db`) and derived data (`index.db`) live in separate files.**
  Human decisions are never stored only in the derived file.
- **D9: Every write has an actor with a session.** Unknown callers are agents, never
  humans.
- **D10: Agent-facing contracts are tested like an API**, across harnesses and
  models.

## Technology

- **D11: Swift 6 with SwiftPM.**
  - Targets: `SiltaCore` (library), `silta` (executable), and later `SiltaApp`.
  - macOS 15+.
  - Domain types don't import GRDB; record conformances live in the storage layer.
- **D12: SQLite through GRDB**, using the system SQLite.
  - PostgreSQL is the planned move if Silta is ever shared by several people.
  - Turso is revisited when it reaches 1.0, or when a Swift binding appears.
  - The comparison is in spec Appendix B.
- **D13: Scripting contract.** This is the "control plane" idea applied to a CLI: an
  agent must be able to prove from the command line that a change works.
  - Data goes to stdout; logs and diagnostics go to stderr.
  - `silta schema` describes commands, JSON shapes and error codes, generated from
    code.
  - Time, ids and the data directory are injectable, so runs are deterministic.
  - Scenario runs leave an evidence directory.
  - The details are in spec §20.1.

## Process

- **D14: One canonical `AGENTS.md`.** `CLAUDE.md` is a stub. Skills live in
  `skills/` and are symlinked into `.claude/skills/`. Rules are never duplicated
  across tool-specific files.
- **D15: Plans are named after the feature, never dated or phase-numbered.**
  - The board in `docs/README.md` mirrors `docs/plans/`.
  - When a plan ships, its lasting rules move to the spec or this file, and the plan
    is deleted.
- **D16: Reviews use independent subagents.**
  - Architect, Tester and Pragmatism review every plan and every implementation.
  - An Agent experience reviewer joins for changes to agent-facing output.
  - Tests come first, and a bug fix includes a test that failed first.
  - **↳ update 2026-11-02:** test-first is a written flow
    (`coding-guidelines.md`, "Test-first flow").
    - A bug's reproduction is committed first, wrapped in `withKnownIssue`, and the fix
      removes the wrapper.
    - Features start from failing acceptance tests.
    - Goldens are written from the spec.
    - PRs give "Test-first evidence".
    - CI requires a test change on PRs labelled `bug`.
- **D17: Invariants are enforced by guards, and every guard has a self-test.**
  - Each guard must pass a clean tree and fail a planted violation, because a guard
    that silently stops matching passes forever.
  - `scripts/run-guards.sh` runs them all and reports every failure.
- **D18: The toolchain is pinned.**
  - Xcode comes from `.xcode-version`.
  - SwiftLint and swift-format are pinned by version and SHA256.
  - GitHub Actions are pinned by commit SHA.
  - Builds treat warnings as errors, and lint runs in `--strict` mode.
  - A test run with zero tests fails.
  - **↳ update 2026-11-02:** Xcode 27.1, the same build (27A9275) locally and in CI.
    CI runs on GitHub's `xcode-27` image, which is a public preview. If that image
    breaks, the fallback is `macos-26` with Xcode 26.6, which reports the same Swift 7
    feature list (D29).
  - **↳ update 2026-11-02:** Swift package dependencies are pinned with `exact:`, and
    `Package.resolved` is committed. `scripts/verify.sh` builds only from the resolved
    file, so a manifest change without a matching resolve fails.
- **D19: Branch and merge flow.**
  - Branches are `<agent>/<slice>-<slug>`, squash-merged on green CI.
  - Until the first code lands, documentation changes may be committed directly to
    `main`.
  - **↳ update 2026-11-02:** code has landed, so every change goes through a pull
    request. A ruleset on `main` enforces this:
    - no direct pushes, force pushes or deletion
    - squash merges only, with linear history
    - the `verify` check must pass on a branch that is up to date with `main`
    - no approvals are required and nobody bypasses the rules

    Auto-merge is on, so a PR can be queued to merge when CI passes.
- **D20: Dogfood from DF0** (spec §22.1).
  - GitHub issues are the public record, and Silta is the working layer. Tasks link
    their issue with a `url:` link and are not promoted, so they stay editable.
  - The binary used on real data is built only from `main`, by
    `scripts/install-dev.sh`.
  - From DF0 on, migrations count as shipped.
  - Dogfooding friction is recorded as Silta tasks with the topic `dogfood`, and
    triaged once per wave.

## Code

The rules themselves are in [`coding-guidelines.md`](coding-guidelines.md).

- **D21: Concurrency.**
  - A synchronous, nonisolated core built from `Sendable` value types.
  - `async` only for real I/O waits.
  - No global mutable state, and no actors in the core.
  - Swift 6 strict concurrency (the upcoming-feature flags are in D29).
  - Default MainActor isolation only in the app target (M5).
- **D22: Errors.**
  - Per-area error enums conforming to `CodedError`, mapped to the §16 table and
    checked by a golden test.
  - Plain `throws` by default.
  - No `try!`, `as!`, force unwraps or IUOs in `Sources/`.
  - `try?` needs a reason.
- **D23: Seams.**
  - One `SiltaEnvironment`, passed explicitly.
  - Naming: `System…`, `Fake…`, `Scripted…`.
  - Fakes live in a `SiltaTestSupport` target.
  - A conformance suite for every seam.
- **D24: Access control.**
  - `public` only for the app-facing façade.
  - `package` for the CLI and test support.
  - `internal` by default.
  - `@testable` only in unit tests.
- **D25: Layout.**
  - Feature folders.
  - GRDB records in `Storage/Records/`.
  - One primary type per file.
  - Commands named `<Noun><Verb>Command`.
- **D26: Tests.**
  - Swift Testing, with `#require` for preconditions.
  - Parameterized matrices.
  - The slow tier selected by tag.
  - Per-test scratch directories.
  - A home-made golden helper; goldens are never regenerated in CI.
- **D27: Logging.**
  - An injected `Log` seam; no `print` or `os` in the core.
  - Output only from the output layer.
  - Logs never contain bodies.
- **D28: Doc comments.**
  - Required on public and CLI-facing package API.
  - Elsewhere, only where the reason isn't obvious.
- **D29: Language level: "future Swift" up to the stable line.**
  - Swift 6 language mode, plus all six Swift 7 upcoming features on every target:
    `ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility`,
    `InferIsolatedConformances`, `NonisolatedNonsendingByDefault`,
    `ImmutableWeakCaptures`.
  - This is the list the pinned toolchain (Swift 6.4, Xcode 27.1; D18) reports as
    enabled in Swift 7 mode (`swiftc -print-supported-features`).
  - New stable APIs are allowed case by case.
  - Experimental features need a decision.
  - Switching language mode is its own planned change.
- **D30: Simplicity.** Write the smallest code the acceptance tests and the spec
  need: no options, types or validation without a current caller, and no generality
  for later slices. Pragmatism reviews over-engineering first. Errors that can reach
  the caller are always `CodedError` (guard).

