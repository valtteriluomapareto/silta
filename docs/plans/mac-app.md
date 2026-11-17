# Silta for Mac: a read-only viewer

Status: active

## Goal

A native macOS 26 app shows the human what waits on them, what agents are doing, the
workspace map and its docs. It is the human's own surface (D38), built the way spec
§4.1 and §17 describe the M5 app: it links `SiltaCore` and reads through the same
services as the CLI. The first version is read-only. Each action is a ref or a command
the human copies.

## Inputs

- Designs: Paper file "Silta", page "MVP v2":
  - screens: My work, Board, Docs, Workspace;
  - a states and dark-mode sheet;
  - notes with the glossary and fixture dataset.
- The page "MVP v1" holds a feasibility review written for a CLI-based design. Its
  data mapping still applies; its process-boundary notes don't.
- Spec:
  - §4.1: one core, thin front-ends; the database is the integration point;
  - §11 and D38: the app counts as `human:*`;
  - §17: the change signal, `data_version`, `App/SiltaApp.xcodeproj`;
  - §19: logs come from the CLI front-end.
- [`workspace-knowledge.md`](workspace-knowledge.md) supplies docs and proposals.
  Doc triage arrives with SI-134; diff readability with SI-126.

## Scope

**In:**
- **Sidebar:** workspace switcher, My work, Board, Workspace and Docs, apps with open
  counts, "Claimed now", and refresh status.
- **My work:** the human's inbox, plus tasks in `review`. The waiting badge counts
  each actionable inbox entry and each distinct review task once;
  it does not count visual groups. The maintainer chose actionable-item counts on
  2026-11-16; Paper v2's “4 waiting” group count is not the acceptance value.
- **Board:** blocked tasks stay in Todo with a blocked label; lanes show plan
  progress, and a task inspector shows the plan, claim,
  properties and discussion.
- **Workspace:** apps and connections with a connection inspector, read from the
  workspace model rather than YAML.
- **Docs:** a three-column view with Document, Changes and Comments tabs, a revision
  menu and paging.
- **Copy:**
  - a ref chip on every item;
  - command blocks whose placeholders fail safe if left unfilled: proposal refs use
    `REFS`, and question answers use `-m ""`, which Silta refuses as an empty body;
  - review items offer task-reading commands. Human completion permits an empty
    result, so a completion template cannot promise the same empty-message refusal.
    The maintainer chose to preserve CLI behavior on 2026-11-17; completion commands
    remain outside this viewer;
  - a Copied state;
  - ⌘C and a context menu.
- **States:**
  - store missing, or a newer schema than the app;
  - first load, empty, long text and many items;
  - dark mode.
- **Accessibility:** contrast at least 4.5:1 for readable text, labels on icon-only
  controls, and the keyboard shortcuts ⌘1–⌘4, ⌘F and ⌥⌘I.

**Out of v1:**
- **Writes.** As `human:*` the app may run them directly, but answering, triage, done
  and doc triage as buttons with a confirm step are the next plan.
- **A signed release bundle with the embedded CLI**, which is M5. v1 is a local dev
  build from the same commit as the installed `silta`.
- A free-form graph map, an activity feed, notifications and iOS.

## Design

- **Layers:**
  - **Root package target `SiltaAppSupport`** (Foundation + SiltaCore, no SwiftUI).
    It holds read models for the screens and command templates, with a small `public`
    API. Shared development fixture seeding is whole-file DEBUG code here, with a
    `SiltaTestSupport` wrapper (D23); the app never links test support. SiltaCore's
    services are `package`-scoped, so this target must live in the root package.
  - **Thin Xcode project `App/SiltaApp.xcodeproj`** (target `SiltaApp`). It holds the
    SwiftUI views and the asset catalog and links `SiltaAppSupport`. Native views
    import only that facade and Apple frameworks; document formatting uses
    Foundation's Markdown parser and SwiftUI.
  - **Guard:** SiltaCore stays free of UI code.
- **Store and actor:**
  - The app opens `SILTA_HOME` (default `~/.silta`) through SiltaCore's store and
    never writes or migrates.
  - A store with a newer schema shows the "update Silta" state.
  - Queries run as `human:<USER>`, so the inbox gives human-form `next` commands such
    as `task triage --accept …`. No `--approved` placeholders.
  - Runnable recovery commands carry the selected `SILTA_HOME` with literal shell
    quoting, so a custom app home cannot recover a different default store.
  - Reads aren't logged; §19 logging belongs to the CLI front-end.
- **Freshness:** check `PRAGMA data_version` when the window gains focus, on ⌘R, and
  on a 5-second timer while the window is frontmost. Reload when it changed or a
  one-minute cache ceiling is reached. The ceiling bounds clock-only staleness;
  a foreground tick adds at most five seconds. The
  §17 change signal (`notify_post` after each commit) replaces the timer once a slice
  adds it to SiltaCore writes.
- **Copy text:** runnable templates carry the selected `SILTA_HOME`. Use the inbox's
  human-form `next` where it is a runnable command,
  otherwise a template keyed by item kind. Placeholders never decide for the human:
  nothing is pre-filled for drop or reject, and there's no `-F -`.
- **Layout:** `NavigationSplitView` (three columns for Docs), `.inspector`,
  `.searchable` in the toolbar. Glass only on the sidebar, toolbar and controls. The
  app accent is tide `#0B6E8E`, from the asset catalog.

## Slices

| Slice | Scope | Depends on | Verify with |
|---|---|---|---|
| A1a (SI-154) | `SiltaAppSupport`: workspace list, human inbox and review tasks, board and task detail; shared v2 seed in DEBUG `SiltaAppSupport/Control/` with a `SiltaTestSupport` wrapper and release-isolation guard | — | `swift test` on the seed: task counts reconcile; models match `task ls`/`task show`/`inbox --for me`; Release package build excludes fixtures |
| A1b (SI-155) | Typed workspace-map read models and persistent `data_version` probe | A1a | Map counts and edges match the seed; probe sees an external CLI write and stays unchanged by reads |
| A2 (SI-145) | Running Debug app: sidebar, My work, copyable refs/commands, isolated fixture launch, store states and refresh; folds SI-175, SI-176 and A2c into one screen PR. SI-173 commands can land separately | A1a, A1b | Native view-model tests, Debug/Release builds, state and PNG checks; unlocked interaction follow-up |
| A3 | Board and task inspector | A2 | View-model tests on the seed, state and PNG checks; unlocked interaction follow-up |
| A4 | Workspace and connection inspector | A3 | View-model tests on the Acme seed, state and PNG checks; unlocked interaction follow-up |
| A5 | Docs read models and view: list, reader, revisions, paging, Comments; Changes with the doc triage command block | A4, SI-126, SI-134 | Read-model and view-model tests on pending-only, archived, legacy-metadata docs and a doc over 400 lines; state and PNG checks; unlocked interaction follow-up |

Delivery order is My work, Board, Workspace, then Docs: one screen per PR.
Use a short `task plan` and one independent combined Architect/Tester implementation
review. Logic remains test-first; SwiftUI layout gets view-model tests afterwards.
No planted faults except for guard tests. Split only when a diff substantially
exceeds about 1,000 lines. Add navigation, observable state and development hooks
only when a screen needs them. The minimal [control support](mac-app-control.md)
provides isolated fixtures, versioned model state and offscreen root PNGs in its own
PR. Real-window capture, wait and live actions remain separate follow-ups.
Merge main only for a conflict or a needed landed change. After merging, submit
the task and report which tasks the maintainer can close; do not mark them done.

## Validation

Computer use never blocks a PR. Each PR records checks from tests, versioned
`state.json`, inspected snapshot PNGs and any real UI pass. Missing real UI checks
belong under **Pending unlocked check** and run later, without waiting or retrying
computer use. SwiftPM and hosted tests must run with a locked console; record the
one-time proof in the PR. Offscreen PNGs use the real root in `NSHostingView` with
`bitmapImageRepForCachingDisplay`/`cacheDisplay`; glass and vibrancy need the later
unlocked pass. Rendering limitations are disclosed and tracked separately.

- Read models are tested in-process on fixture stores with an injected clock and ids.
  That is deterministic and covered by the existing `swift test` in `verify.sh` and CI.
- Each command template runs in a fixture workspace with its placeholders filled,
  under `/bin/sh -c`, and must exit 0 with the expected state change. Unfilled
  placeholders must fail with no write and never wait for input.
- **CI** (A2 adds it with the Xcode project; the runner already has the pinned Xcode):
  - `SiltaAppSupportTests` run in the existing `swift` job. Read-model tests stay
    in-process except CLI parity and recovery replay checks; command-template tests
    also start processes. That job is CPU-bound and the slowest one, so A1 and each
    later slice report how much test time they add.
  - The `app` job runs `scripts/verify-app.sh` beside `swift` and `evals`; `verify`
    requires all three. Guards, lint and tool installation stay in `swift`. Locally,
    `scripts/verify.sh app` adds guards/lint; `full` includes native app verification.
  - `verify.sh app` runs `xcodebuild test` for `SiltaAppTests` (Debug), then
    `xcodebuild build` (Release). Release on every PR proves the DEBUG-only control code
    compiles out. Both runs:
    - use `-derivedDataPath .build/app/DerivedData` and `-clonedSourcePackagesDirPath`;
    - use `-onlyUsePackageVersionsFromResolvedFile` and the project's own
      `Package.resolved` for the root package dependencies (D18);
    - set `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` in the project, so local builds match;
    - sign with "Sign to Run Locally", so hosted tests need no certificate.
  - A test run proves nothing unless tests ran. `verify.sh app` fails when the result
    bundle reports zero tests, any skipped test or a missing `AppStartupTests` suite.
    Other suites rely on the nonzero-test and no-skip checks.
  - A guard with self-tests checks that every package pinned in both the project's and
    the root `Package.resolved` has the same pin, so the app never builds against a
    different GRDB than the `swift` job tested (D18).
  - Budget: the `app` job must finish before the slowest other job. If it doesn't,
    measure first, then move the Release build to the weekly run, which gives up the
    per-PR proof that DEBUG-only code compiles out. Path gating comes last: the filter
    must cover everything the project compiles or imports, including
    `Sources/SiltaCore/**` and `Sources/SiltaTestSupport/**` unless a guard proves `App/`
    imports neither, so it would skip few PRs. The weekly and manual runs always run
    the app.
  - Not in CI: XCUITest and screenshot approval. Signing and notarization (M5) belong to
    a separate tag-triggered release workflow.
- **Not verified until DF3:** whether the human uses the app daily.

## Risks

- **Version skew** between the dev app and an installed CLI from another commit.
  Mitigation: a newer store schema refuses; the About box shows both commits. M5
  removes the skew by bundling.
- **SiltaCore read paths built for the CLI** (bounded text, masking) may not suit the
  views. Add typed read queries to SiltaCore that the CLI can also use; never query
  tables from the app.
- **Copy-and-paste friction.** v1 accepts it; the writes plan removes it.

## Done when

- A1–A5 have merged.
- The app is used against the dogfood workspace for a week, and every mismatch with
  `silta` output found during that week is filed and fixed.
- The states sheet and dark mode match the designs.

Then record the app's read model and refresh rules in spec §17, and delete this file.
