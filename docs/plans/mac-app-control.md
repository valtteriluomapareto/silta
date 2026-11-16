# Silta for Mac development control plane

Status: proposed

## Goal

An agent can launch Silta for Mac into a named fixture and route, read its state as
JSON, wait for a condition, and capture the app window. Live actions use the same
handlers as the UI. Control runs use isolated data and are absent from Release.

## Inputs

- [Mac app plan](mac-app.md): A1 read models, A2 shell and My work, A3 board,
  A4 workspace, A5 docs. The app reads SiltaCore directly as an explicit human
  actor; product views never invoke the CLI or migrate storage.
- [Spec §4.1](../spec.md#41-architecture), [§11](../spec.md#11-agent-integration),
  [§17](../spec.md#17-storage-concurrency-technology), and
  [§19](../spec.md#19-observability); D18, D21–D30 and D38 in
  [decisions](../decisions.md).
- Paper's Silta file, MVP v2: My work, Board, Docs, Workspace, States and dark
  mode, and Notes. The Mac app plan wins over a mockup.
- Existing issues [#178](https://github.com/valtteriluomapareto/silta/issues/178)
  (C1, SI-146) and [#179](https://github.com/valtteriluomapareto/silta/issues/179)
  (C2, SI-147), under tracking issue
  [#183](https://github.com/valtteriluomapareto/silta/issues/183).
- Poimi's control-plane plan, read locally at
  `/Users/valtsu/personal/poimi/docs/plans/control-plane.md`: adopt named fixtures,
  reach and look before actions, atomic snapshots and a file mailbox. Silta uses
  a Mac window and SQLite, with no simulator or headless app host.

## Scope

**In:** DEBUG launch, named fixtures, routes, observable state, the development
script, a release-isolation guard, then live UI actions and one external fixture
write to verify refresh. Add routes and actions with the product screens they
exercise; unavailable screens return an explicit refusal.

**Out:** product writes, real-data control mode, a socket or MCP server, headless
rendering, a scenario language, fault-injection framework, arbitrary shell or SQL
execution, CI screenshot approval, and changes to Paper or Poimi.

## Design

### Isolation and fixture ownership

- All control Swift files live under a directory named `Control/` and are wrapped
  as whole files in `#if DEBUG`. Flag parsing lives in one `ControlLaunch.swift`.
  Release has no control parser, mailbox observer or snapshot writer. Before
  opening storage, its startup check refuses only arguments beginning with
  `-Silta`, including unknown `-Silta*` flags. It leaves other arguments to macOS
  and Xcode, including `-NSDocumentRevisionsDebugMode`,
  `-ApplePersistenceIgnoreState` and `-AppleLanguages`; there is no general
  unknown-argument rejection or operating-system argument allowlist.
- One `ControlFixture` enum is shared by launch, previews and fixture tests:
  `v2`, `empty`, `newer-schema`, `missing-store`, `many-items`, `long-text`.
  Its home is the DEBUG-only control sources of the root app-support target, so
  its implementation can call package-scoped SiltaCore APIs. The Xcode app consumes
  its small DEBUG-only public entry point; no test support is linked into the app.
- A1 places the shared v2 seed implementation in whole-file DEBUG sources at
  `Sources/SiltaAppSupport/Control/`, using core service APIs. Its
  `SiltaTestSupport` seed is a package wrapper, so tests and the future app consume
  one dataset and seeding path. The wrapper is also DEBUG-gated so Release builds
  cannot reference an absent seed. Test support may depend on app support; app support
  never depends on test support. This is the narrow D23 update recorded with this
  plan: one fixed fixture/test clock implementation lives beside the seed in
  DEBUG `SiltaAppSupport/Control/`, and test support reuses it through an alias or
  forwarding wrapper, without another implementation. The seeded ID algorithm
  already serves the CLI in SiltaCore; it remains the single implementation there.
  DEBUG Control exposes shared access to that same generator, reused by test
  support, rather than copying its algorithm or making Core depend on app support.
  Existing clock/ID conformance suites exercise these shared implementations.
  Test-support helpers that need DEBUG-only types are also DEBUG-gated so Release
  product builds still compile. Other fakes stay in test support; no package guard
  is relaxed. The minimal whole-file DEBUG guard and its Python self-tests ship
  with A1's first fixture sources; C1a extends coverage to App control files and Release launch behavior.
- Seed ordinary fixtures through core service APIs before opening the read-only
  app connection. `missing-store` creates no database. `newer-schema` starts from
  a valid seed and adds an unknown migration marker through a fixture-only helper;
  it never edits a shipped migration. The helper lives in control sources.
- Each launch owns a fresh private temporary run directory containing `home/`,
  `silta/` (SILTA_HOME), mailbox files and snapshots. Never inherit a data home,
  location default or preferences from the parent process. Resolve symlinks and
  reject the real Silta home or any user-selected existing store before seeding.
  Use a separate UserDefaults suite. Cleanup touches only the owning run directory.
- Pin fixture time, ID sequence, UTC, locale and appearance; pass the same clock
  to product read models so relative times stay fixed. Transport deadlines and
  the 1.5-second copy feedback still use monotonic time. The run ID is unique per
  launch and is excluded from comparisons of deterministic fixture content.
- Fixture writes use a separate process against this isolated SILTA_HOME. The
  app's long-lived read connection remains read-only; product startup never seeds.

### Reach and look (C1)

Launch syntax:

```text
SiltaApp -SiltaControl -SiltaFixture v2 [-SiltaRoute mywork] [-SiltaDark]
scripts/silta-app.sh launch --fixture v2 [--route mywork] [--dark]
scripts/silta-app.sh state [jq-path]
scripts/silta-app.sh wait '.idle == true' [--timeout 10]
scripts/silta-app.sh shot /tmp/silta-mywork.png
```

- `-SiltaFixture`, `-SiltaRoute` and `-SiltaDark` without `-SiltaControl` fail before
  opening data. Unknown fixtures, malformed routes and conflicting flags fail
  explicitly. Direct control launch also creates and validates an isolated run.
- Route grammar: `mywork`, `board:AC-12`, `docs:doc:order-contract@3`, and
  `workspace:edge:acme-mobile/acme-backend/http-api`. Parse the screen prefix once;
  the remaining ref uses the core ref parser. Apply through the same app handlers
  a click calls, after loading. Missing refs fail explicitly. A2 initially supports
  `mywork`; A3–A5 add their routes and selection projections with their screens.
- `launch` builds serially using a worktree-local derived-data path, starts the
  executable directly, and records its PID, run ID and directory in a worktree-local
  pointer file. It never kills an unrelated app or falls back to real data. A second
  launch stops only its recorded, verified control process or reports a conflict.
- `state.json` is versioned, projected from actual app-owned observable state and
  written by temp-file plus rename. Coalesce multiple changes on the next main-actor
  turn; never build a snapshot in a view body. Observation is re-registered after
  each notification, and projection runs after the observed mutation.
- Required fields: `snapshotVersion`, `run`, `revision`, `fixture`, `appearance`,
  `screen`, `route`, typed `selection`, `inspectorOpen`, `counts` (board lanes,
  sidebar badges), `refresh` (phase, last observed data_version, coded load error),
  `pid`, `windowNumber` and `idle`. `windowNumber` is the owned `NSWindow`
  number, or null until its window exists. Unsupported/unloaded counts are null,
  never invented zeros.
  Bodies, comments, paths, credentials and arbitrary error strings are excluded.
- `idle` means startup, route application, read-model loading and refresh have
  completed and the snapshot includes their results. Error states can be idle;
  callers also assert the expected refresh phase. It does not prove painted pixels.
- `state` and `wait` validate snapshot version and current run. `wait` uses file
  change notifications and a monotonic deadline, not fixed sleeps or a busy loop.
  Predicates use jq; invalid predicates fail immediately. Timeout must be finite
  and positive (at most 120 seconds). Register the file watch before the first read
  and re-read after registration/events to avoid lost changes. Examples use
  `has(...)` or type checks before nullable comparisons under ordinary jq semantics.
  Timeout reports the unmet predicates and last snapshot, including when no
  snapshot was published. C1b decides whether undeclared paths fail immediately
  (follow-up below); this plan does not select a jq/schema parsing mechanism.
- `shot` waits for current-run idle and a positive `windowNumber`. The app writes
  its actual window number and PID into `state.json`; the script verifies that the
  window still belongs to the recorded run's live PID using Core Graphics window
  metadata. It then runs `/usr/sbin/screencapture -l"$windowNumber" -o "$output"`
  to capture only that window, without its shadow. Never select by title, frontmost
  app or screen bounds. A closed/reused window or denied Screen Recording access
  fails explicitly. Inspect every screenshot used as visual evidence.
- Before starting C1b / SI-153, run a capture preflight from the same execution host
  and permission context as the script, against a temporary synthetic owned window.
  Record the command, result and inspected artifact on SI-153; another tool's screen
  capture permission does not prove that `screencapture` can run here. Repeat when
  the execution host or permissions change. Do not enable permissions automatically.
  If blocked, the human can grant Screen Recording and relaunch the host, or run
  the same `shot` command from a Screen Recording-authorized Terminal and provide
  its result and file. Manual capture of the owned app window is a visual-only
  fallback: pair it with the current run/route/revision and inspect it. It does not
  verify the script. Record the execution host for successful script capture; keep
  automated-capture acceptance open until that succeeds. Launch/state/wait work can
  proceed while the capture capability is blocked.

### Live actions (C2)

```text
scripts/silta-app.sh send '{"action":"refresh"}'
scripts/silta-app.sh fixture-write
```

`send` supplies protocol version, run and sequence, and prints the response. It
accepts action JSON rather than introducing an action-specific argument parser.

- The script writes `req-<seq>.json` atomically in the run mailbox; the app watches
  the directory, processes requests in sequence, and writes `res-<seq>.json`
  atomically. Both contain protocol version, run ID and sequence. No sockets.
- Strict decoding rejects unknown versions, actions, keys, invalid refs and types.
  Bound request bytes and accept only plain files inside the owning directory;
  reject symlinks. Only one client writes to a run at a time. Repeated sequences
  return the prior response without repeating effects; stale-run requests fail.
- Actions: `nav`, `select.task`, `select.doc`, `select.connection`, `inspector`,
  `copy.ref`, `copy.command`, `refresh`. Add each screen's action registration
  after both its UI and C2 are available; track that follow-up on the screen task
  when its UI ships first. Unsupported actions return `refused(unsupported)`.
- UI actions call the same app handler as a click or keyboard command. The control
  layer only decodes, dispatches and projects. Results are `accepted`, `noop` or
  `refused(reason)`; accepted means admitted, not finished.
- Responses carry `seq`; snapshots add `settledSeq`. A client waits for
  `settledSeq >= seq` and `idle`, plus its feature predicate. Refused/noop requests
  also settle. Processing errors are returned explicitly, not hidden in idle.
- `fixture-write` is a script-side composite, absent from the app action enum.
  It runs a fixed, allowlisted CLI recipe that adds one fictional task in the
  isolated Acme workspace using the locally built binary, captures its ref, sends
  ordinary `refresh`, then waits for that sequence and the expected ref/count.
  It accepts no executable, home, arbitrary args, bodies or SQL. Each explicit
  invocation creates one task; it never automatically retries an uncertain CLI
  write. If the CLI exits ambiguously, report it for inspection instead of replay.
  Retrying the subsequent refresh reuses the saved ref and cannot repeat the write.
- Copy actions exercise the actual clipboard handler. Tests use an injected
  clipboard sink. Interactive control uses a private named pasteboard so an agent
  never overwrites the person's system clipboard.

## Slices

| Slice | Scope | Depends on | Verify with |
|---|---|---|---|
| C1a / SI-152 / #178 | Shared named fixtures, launch and My work route, atomic snapshot, extend A1 release guard | A2; reuse A1 seed | SwiftPM fixture tests, Xcode launch/snapshot tests, Python guard self-tests, Debug and Release builds |
| C1b / SI-153 / #178 | `launch/state/wait/shot`, process ownership, AGENTS.md onboarding | C1a; capture preflight recorded before starting | Python script/wait/shot tests; Debug fixture launch and inspected light/dark window screenshots |
| C2 / SI-147 / #179 | Mailbox, dispatch to shared handlers, sequence barriers, copy and fixture-write refresh | C1b | Strict-decoding and action tests; isolated CLI write changes read-model counts on the existing reader; real UI wiring check |

Schedule A1 → A2 → C1a → C1b, then C2, A3 and A4 can run alongside one another.
A3/A4 require reach-and-look, not live actions: they add routes and selection state
with their screens, then add live actions after C2 is available. A5 still waits for
C2, SI-126 and SI-134. No second control-plane
implementation is needed. Keep each PR near 800 lines; split oversized work into
linked subtasks.

SI-146 is the C1 implementation parent, with SI-152 and SI-153 beneath it. Keep it
`doing` and out of review until both implementation parts are complete. Plan-only
PR #186 belongs to its own child SI-159; only that child tracks the planning review.
Plan-only children link their PR, not the parent issue, so finish automation cannot
close #178 for documentation. Never pass SI-146 to `dogfood-finish` for #186. Use a
separate subtask for future plan-only PRs too; #178 remains open for C1 code.

### C1b follow-up: undeclared wait paths

Evaluate Poimi's immediate failure for a snapshot path that is not declared, instead
of making every caller rely on `has()`. Decide this in C1b / SI-153, with tests that
distinguish an undeclared path from a declared field whose value is null. The decision
must cover supported jq expressions and an actionable error; no implementation or
custom jq/schema parser is part of #186.

## Validation

Acceptance tests are written and observed red before implementation. Fixture and
core read-model suites run in SwiftPM's `SiltaAppSupportTests` via `verify.sh full`;
script/wait/guard suites run with `python3 -B -m unittest discover -s scripts/tests`.
App-owned launch, Observation and handler suites run in Xcode's `SiltaAppTests` via
`xcodebuild test -project App/SiltaApp.xcodeproj -scheme SiltaApp -destination
'platform=macOS' -derivedDataPath .build/app-control-tests` (one shell command).
Builds/tests run serially. App CI must explicitly run this test command; a build
alone proves no Xcode tests ran. Report unexecuted local or CI suites by name.


- C1: `ControlFixtureTests` proves every named fixture, deterministic time/IDs,
  A1 count parity, empty and long/scale cases. Existing `DeterminismTests` clock/ID
  contracts must exercise the shared Control/test-support types, with no second
  fixed-clock or seeded-ID implementation. `ControlLaunchTests` proves route
  parsing, unsupported screens, invalid flags and isolation (including symlinked
  real-home rejection) before storage access. `ControlSnapshotTests` proves schema,
  no bodies/paths, atomic replacement, terminal errors and honest idle. Test the
  script wait helper with injected file events and a fake monotonic clock: current
  run success, invalid jq, timeout, absent/malformed snapshot and stale run. Cover
  a change during observer registration, invalid timeout bounds, and missing-key
  predicates using `has` before null comparisons.
- C1b: `ControlShotTests` inject process/window metadata and a capture runner.
  Cover a positive owned window number and exact `screencapture -lID -o` arguments;
  null, missing or stale windows; wrong PID/run ownership; denied/failed capture;
  and partial output that must not be accepted as an artifact. Ownership failures
  must refuse before invoking capture. These are unit-test seams, not runtime
  executable overrides. The actual-host permission preflight and inspected image
  remain separate acceptance checks.
- C1 guard: Python self-tests plant unwrapped files, an early `#endif`, nested
  directives, empty trees and a Release-visible launch flag. Release startup tests
  refuse known and unknown `-Silta*` arguments before any storage open, while
  accepting unrelated arguments, including the three macOS/Xcode examples above.
  Require whole-file DEBUG wrapping for every control source in App and Sources;
  run the guard in CI.
- C2: `ControlMailboxTests` covers each action, each refusal, duplicate/stale
  sequences, malformed/oversized files and symlinks; fake-clock tests cover timeouts
  and the accepted-to-settled barrier. A refresh acceptance test uses two database
  connections. Fake-clock refresh tests cover focus, the five-second frontmost
  timer, suppression in background, unchanged versions causing no reload, and last
  good data surviving a failed refresh. The external-write journey additionally
  proves actual SQLite version changes; no test uses a wall-clock wait.
- Run `scripts/verify.sh full` before every PR, plus guard self-tests when the
  guard changes. Run builds serially; give xcodebuild its own derived-data path.
  Build Debug and Release locally. If CI cannot build the app with the pinned
  Xcode, record local-only app validation and the missing CI coverage explicitly.
- Launch fixtures, read state and inspect captured screenshots for each new screen.
  A real click/keyboard pass proves wiring; invoking a shared handler cannot.
  Launch Release with known and unknown `-Silta*` arguments and an isolated sentinel
  data home; assert refusal before creating files or reading that sentinel. Spy on
  the storage opener in Xcode tests to prove no default/real home is opened either.
  Separate Release tests pass `-NSDocumentRevisionsDebugMode YES`,
  `-ApplePersistenceIgnoreState YES`, the argument pair `["-AppleLanguages", "(en)"]`
  and an unrelated argument through normal startup in an isolated home; they must not trigger
  control-argument refusal.

## Risks

- Test support accidentally shipped: preserve the package graph guard and review
  fixture placement before C1 implementation; no dependency exception is implied.
- Snapshot diverges from UI: project loaded app state, compare fixture counts to
  A1, and verify both real clicks and screenshots alongside predicates.
- Stale files or early idle: run identity, monotonic revisions, sequence settlement
  and atomic files are acceptance-tested.
- Newer-schema and missing-store fixtures accidentally create/migrate data: assert
  storage bytes remain unchanged after the reader opens or fails.
- Screen capture permissions or unavailable Xcode block visual verification: report
  the exact limitation and ask the human; never repair the environment silently.

## Done when

C1 and C2 acceptance checks pass, A3–A5 can extend the same routes and handlers,
Release isolation is enforced, and AGENTS.md documents: “Launch into the state,
don't click your way there” and “Read state.json for what the app holds; a
screenshot that someone looks at proves the look.” Move lasting protocol and
isolation rules into the spec/decisions, then delete this plan and its board row.
