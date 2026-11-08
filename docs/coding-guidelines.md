# Coding guidelines

How Swift code in this repo is written. Each rule cites its decision (D21–D30 in
[`decisions.md`](decisions.md)) and says how it's enforced:
- **guard:** checked by `scripts/run-guards.sh`
- **lint:** checked by SwiftLint
- **review:** checked by the persona review

When a rule and the code disagree, fix the code or propose a decision; don't
quietly diverge.

## 0. Language level (D29)

- **Write "Swift 7 ready" code today.** Every target uses Swift 6 language mode and
  enables all six upcoming features that become the default in Swift 7 mode (guard:
  `check_package_features.py`):

  | Feature | What changes in the code you write |
  |---|---|
  | `ExistentialAny` | Write `any Clock`, never a bare protocol type. Prefer generics or `some` where they fit. |
  | `InternalImportsByDefault` | Imports are internal. Re-exporting a type in public API needs `public import X`; keep this rare. |
  | `MemberImportVisibility` | Import every module whose members you use, even if another import already pulls it in. |
  | `InferIsolatedConformances` | A conformance of a `@MainActor` type is inferred as isolated, mainly relevant in the app. |
  | `NonisolatedNonsendingByDefault` | Nonisolated `async` functions run on the caller's actor. Use `@concurrent` when work really must leave it. |
  | `ImmutableWeakCaptures` | `weak` captures are `let`. Don't reassign a captured weak reference. |

- **When the compiler suggests a fix-it for one of these, apply it.** Don't turn the
  feature off locally.
- **New stable APIs are welcome where they clearly help**: typed throws, `sending`,
  noncopyable types, newer Swift Testing features, Foundation's `Subprocess`. When one
  shapes the architecture, record it as a decision (D#).
- **Experimental features (`enableExperimentalFeature`) are not used** without a
  decision that names the feature and the reason (guard). They can change or
  disappear, and agents write unreliable code with features they've rarely seen.
- **When a new language mode ships** (e.g. Swift 7), switching to it is a planned
  change with its own issue, not a side effect of another slice.

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
  uses SQLite transactions for writes (spec §17), not actors. Database initialization
  uses the advisory lock recorded in D12.
- **Writes keep what they don't know (D32).** An older binary may write to a newer
  schema, so owned writes use `UPDATE` or `INSERT`, never `REPLACE` (which resets
  columns it doesn't know), and JSON columns keep unknown keys. A migration that
  changes what older writes mean raises `min_writer_version`.
- **Swift 6 language mode** with strict concurrency checking on every target, plus
  all the Swift 7 upcoming features (§0).
- **`@MainActor` belongs to the app.** The app target (M5) uses Swift 6.2's
  default MainActor isolation. `SiltaCore`, the CLI and the test support stay
  nonisolated.
- **`@unchecked Sendable` and `nonisolated(unsafe)`** need a comment explaining why
  they're safe (review).

## 2. Errors (D22)

- **Per-area error enums** (`StorageError`, `LocationError`, `TaskError`, …)
  conform to `CodedError`, which provides `code`, `exitCode`, `message`, `next` and
  optionally `retryAfter`, matching the §16 table.
  - In `SiltaCore` and `silta`, no type conforms to `Error` directly: it conforms to
    `CodedError`, so every error that can reach the caller has a code, a message and
    a `next` command (guard: `check_coded_errors.py`). An error that never leaves its
    file carries `// guard:allow-error <reason>`.
  - Register each new type in `ErrorReachabilityTests` and take its codes off
    `notYetProduced`.
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
  scenario runner share them. Production targets never depend on it (guard:
  `check_package_graph.py`).
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

| Target or folder | Holds |
|---|---|
| `Sources/SiltaCore` | The domain library: storage, policy, git access, actors, brief and output. No UI or CLI frameworks (AGENTS.md invariant 1) |
| `Sources/silta` | The CLI: ArgumentParser commands under `Commands/`, plus the entry point, global options and text renderers next to them |
| `Sources/SiltaTestSupport` | Fakes (clock, log, git runner), the golden helper, scratch directories, `SiltaBinary` and the `.slow` tag. Only test targets depend on it (D23) |
| `Tests/SiltaCoreTests` | Unit and fixture tests of `SiltaCore`, in folders that mirror its feature folders; error-code goldens in `Golden/` |
| `Tests/siltaTests` | Black-box CLI tests that run the built binary: golden text and `--json` in `Golden/`, the scenario runner in `Scenarios/`, and tests of the dogfood scripts |
| `Tests/Scenarios` | Scenario files (`<name>.yaml`) the runner executes in a temporary `SILTA_HOME` (spec §20.1) |
| `Evals/` | Isolated harness adapters, Acme eval fixtures, evidence graders and offline replay tests (spec §21) |
| `scripts/` | The verify ladder, lint, fixtures and dogfood scripts; `guards/` holds the repository guards, `tests/` their self-tests, and `ci/` the CI-only steps. Each script's header says how to run it |

- **Folders by feature** inside `SiltaCore`: `Agents/`, `Brief/`, `Code/`,
  `Comments/`, `Doctor/`, `Location/`, `Output/`, `Policy/`, `Storage/`, `Support/`,
  `Tasks/`, `Workspace/`. A slice should touch mostly one folder.
- **GRDB record conformances** live in `Storage/Records/` as extensions. Domain
  types never import GRDB (D11).
- **One primary type per file**, with the file named after it. Small private helpers
  may share the file.
- **CLI commands** are named `<Noun><Verb>Command`, e.g. `TaskAddCommand`,
  `WhereCommand`, one per file under `Sources/silta/Commands/`.
- **Tests mirror the source folders.** `SiltaCoreTests` mirrors `SiltaCore`'s
  feature folders. `siltaTests` is flat, because `Sources/silta` has no feature
  folders; its files group by name prefix (`Task…`, `Brief…`, `Where…`). Test types
  are named `<Subject>Tests`.
- **Test files are named after their subject**, not after a review round or a
  regression (`BriefRoundOneTests`, `TaskInputRegressionTests`). A split file of one
  suite is `<Suite>+<Topic>.swift`, like `BriefCommandTests+Fixture.swift`.

## 6. Tests (D26)

- **Swift Testing** (`@Test`, `#expect`, `#require`). XCTest only where a tool
  requires it.
- **`#require` for preconditions** instead of `guard … else { return }`. A failed
  precondition must fail the test, not skip it silently.
- **Parameterized tests for matrices:** the actor matrix, the `where` matrix, the
  error-code table, the secret corpus.
- **Tiers:**
  - slow tests carry the `.slow` tag from `SiltaTestSupport` and run only when
    `SILTA_SLOW_TESTS=1` (`scripts/verify.sh full`)
  - the scenario runner is a slow test
  - wall-clock deadline checks carry a `.deadline` tag, live in `WallClock…` suites
    and run only when `SILTA_DEADLINE_TESTS=1`, which `scripts/verify.sh full` sets
    for a serial run of those suites alone; the decisions they prove also get a
    fake-clock test that runs everywhere
- **Isolation:** each test gets its own scratch directory and `SILTA_HOME`, so tests
  share no state and run in parallel.
- **CLI tests are black-box.** `siltaTests` runs the built binary through
  `SiltaBinary.run`, which gives the child a fixed environment (no inherited `SILTA_*`
  or `HOME`). It doesn't depend on or import the `silta` module.
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
- **Bug fixes and new behaviour follow the test-first flow** below.

### Test-first flow

**Fixing a bug: reproduce it before you touch the code.**

1. **Reproduce at the smallest tier that shows the bug.**
   - a unit test for logic
   - a fixture-repo test for git and location
   - a scenario (spec §20.1) when sessions, time, restarts or several processes are
     involved
2. **Watch it fail for the right reason.** Run it and read the failure: the message
   must match the reported symptom, not a setup error or a typo in the test. Paste
   the failing output into the issue.
3. **Commit the reproduction first**, wrapped in `withKnownIssue("#<issue>: …") { … }`.
   CI stays green, and the history shows the test failed before the fix.
4. **Fix with the smallest change** that makes it pass, and remove the
   `withKnownIssue` wrapper in the same commit. If the wrapper is left on a test
   that no longer fails, Swift Testing reports the known issue as missing. So a
   "reproduction" that never really failed is caught too.
5. **Refactor while green**, then run the verify ladder for the change.
6. **If you can't reproduce it, don't fix it blind.**
   - Write down on the issue what you tried and at which tier.
   - Add diagnostics if that would help.
   - Ask, or label the issue `needs-repro`.

**Adding behaviour: acceptance first, then small steps.**

1. **Turn the issue's acceptance list into failing tests or scenarios first.** They
   describe the behaviour from the outside: CLI output, exit codes, database state.
2. **Work in small red → green → refactor steps.** Each step adds one failing test,
   the code to pass it, then cleanup. Don't write code that no test asks for.
3. **Golden files come from the spec, not from the implementation.** Write the
   expected output first, or review it line by line against the spec before
   accepting it. A golden generated from whatever the code prints is just a snapshot
   of a possible bug, and this matters most for agent-facing output (D10).

**Evidence:** the PR's "Test-first evidence" field names the test, and links the
failing commit or output. For a feature, it lists the acceptance tests that were
written first. The Tester reviewer checks it.

## 7. Logging and output (D27)

- **Logging goes through the `Log` seam** in `SiltaEnvironment`. No `print`,
  `debugPrint`, `dump` or `NSLog`, and no `os`/`OSLog` imports in `SiltaCore`
  (guard).
- **Command output** (stdout data, stderr messages) is produced only by the output
  layer (spec §16, §20.1), never by services. Commands conform to `OutputCommand` and
  return a `CommandOutput`; `OutputRouter.render` decides streams and exit codes, and
  `SiltaMain` only writes its result.
- **Implementations:**
  - the CLI writes the JSONL command log (§19), plus stderr with `--verbose`
  - the app uses `os.Logger` with subsystem `com.valtteriluoma.silta`
  - tests capture lines
- **Privacy:** logs carry ids, counts, codes and timings. They never carry bodies
  (task text, comments, plans, file contents), so secrets and project data can't
  leak into logs (review).

### Help pages

Every command's help has an abstract of one sentence, at most 80 characters,
ending in a period and saying `(human-only)` when it is. The usage line is accurate;
each argument and option gets one line, with enumerated values and defaults. The
discussion is at most six lines and covers only effects a caller must know.
Global options appear in their own titled group; test knobs stay hidden. Help
contains no repository paths, milestone or decision ids, roadmap language, or a
paragraph copied from another command. It points to `silta guide <topic>` for
rules instead of repeating them.

## 8. Doc comments (D28)

- **`///` is required on every `public` declaration** (lint: `missing_docs`) and on
  `package` declarations used by the CLI (review). It says what the API does and its
  contract: errors thrown, and side effects such as writes or git calls.
- **Inside the code, comment only where *why* isn't obvious.** Don't add comments
  that restate the code.
- References to `spec §n` and `D#` are welcome. History, plans and review rounds are
  not (guard, AGENTS.md).

## 9. Simplicity (D30)

Write the smallest code the acceptance tests and the spec need. Generality costs
review time now and blocks change later, and a later slice knows its needs better
than a guess made today (review: Pragmatism checks this first).

- **No parameter, option, protocol or type without a caller or test that needs it
  now.** "A later slice might" isn't a caller. Name the slice in the PR instead.
- **No validation of cases that can't happen.** Check what callers or the
  environment can actually send. Don't range-check a constant, or make an `init`
  throw to guard values only tests pass.
- **Parse exactly the format the spec defines**, and check it by round-trip (parse,
  format, compare) rather than with a regex plus a second parser.
- **No wrapper types that only forward.** Use the wrapped type. A `Fake…` holds
  state a test sets; if it doesn't, it isn't needed.
- **One initializer per concept.** Default arguments over overloads.
- **No magic defaults inferred from arguments** (e.g. a timeout guessed from the
  first word). Make the caller say it.
- **Prefer the platform** (Foundation, Synchronization, ArgumentParser) over a
  hand-rolled mechanism, unless a test shows the platform falls short.
- **Spec edits state the contract,** not the implementation: what a caller can rely
  on, not how the code gets there.
- **When a choice isn't covered by the spec or the issue, pick the simplest option**
  and say so in the PR, rather than building in options for both.
