# Coding guidelines

How Swift code in this repo is written. Each rule cites its decision (D21–D28 in
[`decisions.md`](decisions.md)) and says how it's enforced:
- **guard:** checked by `scripts/run-guards.sh`
- **lint:** checked by SwiftLint
- **review:** checked by the persona review

When a rule and the code disagree, fix the code or propose a decision; don't
quietly diverge.

## 1. Concurrency (D21)

- **The core is synchronous and nonisolated.** Services are plain functions over
  `Sendable` value types, and GRDB is used through its synchronous `read`/`write`
  closures.
- **`async` only for real waiting**: subprocesses, and the app's observation of
  changes. Don't make a function `async` just because its caller is.
- **No global mutable state.** That means no stored `static var` and no top-level
  `var` in `SiltaCore`, because shared state breaks parallel tests and strict
  concurrency (guard). A deliberate exception carries
  `// guard:allow-global <reason>`.
- **No actors in the core** unless a decision adds one. Concurrency between processes
  is handled by SQLite transactions (spec §17), not by actors.
- **Swift 6 language mode** with strict concurrency checking on every target, plus
  the upcoming features `NonisolatedNonsendingByDefault` and
  `InferIsolatedConformances`. Confirm the flag names when S1 creates
  `Package.swift`.
- **`@MainActor` belongs to the app.** The app target (M5) uses Swift 6.2's
  default MainActor isolation. `SiltaCore`, the CLI and the test support stay
  nonisolated.
- **`@unchecked Sendable` and `nonisolated(unsafe)`** need a comment explaining why
  they're safe (review).

## 2. Errors (D22)

- **Per-area error enums** (`StorageError`, `LocationError`, `TaskError`, …)
  conform to `CodedError`, which provides `code`, `exitCode`, `message`, `next` and
  optionally `retryAfter`, matching the §16 table.
  - A golden test proves every case maps to a code in the table, and that every code
    in the table is reachable.
- **Plain `throws` by default.** Use typed throws (`throws(StorageError)`) only in
  small leaf APIs where callers really switch on the cases.
- **No crashes in shipped code.** These aren't allowed in `Sources/` (lint):
  - `try!`
  - `as!`
  - force unwraps (`x!`)
  - implicitly unwrapped optionals

  Tests use `#require` instead.
- **`fatalError`/`preconditionFailure`** only for programmer errors that tests would
  catch, and always with a message (lint).
- **`try?` needs a reason on the same line**, e.g.
  `try? fm.removeItem(at: tmp) // best-effort cleanup` (guard). Never use it to
  discard an error the user or agent should see.
- **Error messages are written for agents:** what happened, then the next command
  (`next`). There are no stack traces in output.

## 3. Dependencies and seams (D23)

- **`SiltaEnvironment`** holds every seam: `clock`, `ids`, `git`, `home`, `db`,
  `actor`, `log`. It's built once per command and passed explicitly to services. No
  globals and no task-locals.
- **Naming:**
  - the protocol is a noun: `Clock`, `GitRunner`, `Log`
  - the real implementation is `System…`: `SystemClock`, `SystemGitRunner`
  - test doubles are `Fake…` (state you can set) or `Scripted…` (replays recorded
    answers)
- **Fakes live in the `SiltaTestSupport` target**, so unit tests, CLI tests and the
  scenario runner share them. Production targets never depend on it.
- **Every seam with a system and a fake implementation has a conformance suite** that
  runs against both (§6), so fakes can't drift from reality.

## 4. Access control (D24)

- **`public`:** only the façade the app will need, meaning the service entry points
  and their input and output value types.
- **`package`:** what the CLI and `SiltaTestSupport` need beyond the façade.
- **`internal`** (the default) for everything else.
- **`@testable import`** only in unit-test targets, never in the CLI or test support.
- Public API is documented (§8).

## 5. Layout and naming (D25)

- **Folders by feature** inside `SiltaCore`: `Tasks/`, `Comments/`, `Location/`,
  `Code/`, `Output/`, `Policy/`, `Agents/`, `Storage/`, `Support/`. A slice should
  touch mostly one folder.
- **GRDB record conformances** live in `Storage/Records/` as extensions. Domain
  types never import GRDB (D11).
- **One primary type per file**, with the file named after it. Small private helpers
  may share the file.
- **CLI commands** are named `<Noun><Verb>Command`, e.g. `TaskAddCommand`,
  `WhereCommand`, one per file under `Sources/silta/Commands/`.
- **Tests mirror the source folders.** Test types are named `<Subject>Tests`.

## 6. Tests (D26)

- **Swift Testing** (`@Test`, `#expect`, `#require`). XCTest only where a tool
  requires it.
- **`#require` for preconditions** instead of `guard … else { return }`. A failed
  precondition must fail the test, not skip it silently.
- **Parameterized tests for matrices:** the actor matrix, the `where` matrix, the
  error-code table, the secret corpus.
- **Tiers:**
  - slow tests carry `.tags(.slow)` and `.enabled(if: TestTier.slowEnabled)`, which
    is driven by `SILTA_SLOW_TESTS=1`
  - the scenario runner is a slow test
- **Isolation:** each test gets its own scratch directory and `SILTA_HOME`, so tests
  share no state and run in parallel.
- **Time and ids:**
  - use `FakeClock` and seeded ids (D13)
  - never wait on the wall clock (guard)
  - never assert on real timestamps
- **Golden files:**
  - plain text and JSON in `Tests/<target>/Golden/`
  - compared by a small helper in `SiltaTestSupport`
  - regenerated only with `SILTA_UPDATE_GOLDENS=1`, which `scripts/verify.sh`
    refuses in CI
  - a commit that changes goldens says "Golden update: …"
- **Bug fixes** come with a test that fails on the base commit.

## 7. Logging and output (D27)

- **Logging goes through the `Log` seam** in `SiltaEnvironment`. No `print`,
  `debugPrint`, `dump` or `NSLog`, and no `os`/`OSLog` imports in `SiltaCore`
  (guard).
- **Command output** (stdout data, stderr messages) is produced only by the output
  layer (spec §16, §20.1), never by services.
- **Implementations:**
  - the CLI writes the JSONL command log (§19), plus stderr with `--verbose`
  - the app uses `os.Logger` with subsystem `com.valtteriluoma.silta`
  - tests capture lines
- **Privacy:** logs carry ids, counts, codes and timings. They never carry bodies
  (task text, comments, plans, file contents), so secrets and project data can't
  leak into logs (review).

## 8. Doc comments (D28)

- **`///` is required on every `public` declaration** (lint: `missing_docs`) and on
  `package` declarations used by the CLI (review). It says what the API does and its
  contract: errors thrown, and side effects such as writes or git calls.
- **Inside the code, comment only where *why* isn't obvious.** Don't add comments
  that restate the code.
- References to `spec §n` and `D#` are welcome. History, plans and review rounds are
  not (guard, AGENTS.md).
