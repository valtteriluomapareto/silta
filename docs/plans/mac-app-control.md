# Silta for Mac development control plane

Status: active

## Goal

Validate the running app without depending on an unlocked Mac. The current slice
is SI-152: isolated DEBUG fixture launch, model-owned state.json and offscreen PNGs.
It has its own PR, stacked on Workspace and merged after #210. Screen delivery in
[the Mac app plan](mac-app.md) remains My work, Board, Workspace, then Docs.

## Current scope: C1a / SI-152

Use the shared `v2` fixture from `SiltaAppSupport/Control`, its fixed clock and the
existing ID generator. `SiltaTestSupport` reuses these implementations. Every
launch creates a fresh private temporary data home before opening the app reader;
control never accepts or inherits an existing SILTA_HOME. Product views remain
read-only and never run CLI commands.

```text
SiltaApp -SiltaFixture v2 [-SiltaRoute mywork] [-SiltaDark]
SiltaApp -SiltaSnapshot out.png [-SiltaRoute board:AC-12] [-SiltaDark] [-SiltaSize 1280x800]
```

- Snapshot mode implies the isolated v2 fixture. Routes available with these
  screens are `mywork`, `board[:task-ref]`, `workspace[:edge-ref]` and
  `docs[:doc-ref[:view]]`. Document views are `document` (default), `changes` and
  `comments`. Apply routes through AppModel handlers and validate selected refs
  against fixture data. The native launch adds Docs examples through
  `AppDocsFixture`; shared task data stays in `AppV2Fixture`.
- Unknown `-Silta*`, duplicate flags, missing values, unsupported routes and invalid
  sizes fail before fixture storage opens. Non-Silta arguments belong to macOS
  and Xcode and are left alone. Sizes are logical points, from 1000×700 (the root
  view minimum) through 4096×4096.
- All control sources live under `Control/`, wrapped as whole files in `#if DEBUG`.
  Release refuses only `-Silta*` arguments before opening storage. Keep the existing
  whole-file guard, package boundary and hosted-test isolation checks.
- Interactive fixture launch prints its state.json path in the private run
  directory. Snapshot launch writes state.json next to the requested PNG, then
  exits. Use a separate output directory for each capture to retain matching
  state/PNG evidence.
- Render the real AppShellView in an offscreen NSHostingView, using
  `bitmapImageRepForCachingDisplay` and `cacheDisplay`. Do not use ImageRenderer:
  it cannot draw the native split view, lists or inspectors. This path shows
  layout and content; **glass and vibrancy are not represented**. It does not
  require Screen Recording permission. Inspect every resulting PNG.
- State projects model-owned route, typed selections, per-route inspector flags
  and loaded data. Observation schedules a coalesced projection after mutation;
  writes use atomic replacement, never view-body side effects.

### state.json version 1

| Field | Meaning |
|---|---|
| `snapshotVersion` | Schema version, currently 1 |
| `run`, `revision` | Unique launch identity and increasing publication number |
| `fixture`, `appearance` | `v2` and `light`/`dark` |
| `screen`, `route` | Current screen and canonical route including selected ref and document view |
| `selection` | Null, typed `{kind: task/connection, ref: ...}`, or `{kind: document, ref: ..., view: ...}` |
| `inspectorOpen` | Flag belonging to the current route |
| `counts.lanes` | Visible Board lane counts, including current filters/proposals; null until loaded |
| `counts.sidebar` | Actionable waiting, claimed tasks and app open-count badges; null until loaded |
| `refresh` | `starting`, `loading`, `ready` or `failed`, plus the observed dataVersion |
| `idle` | Initial loading, selected task/document content and current scope/version refresh have settled |

Lane keys use their displayed names: Todo, Doing, Review, Done this week. Failed
loads may be idle; also check refresh.phase. Idle does not prove painted pixels.
Bodies, comments, filesystem paths and arbitrary error messages are excluded.
There is no pending field or mailbox state in this slice.

## Validation and merge gate

- Logic/read models: SwiftPM tests and hosted xcodebuild tests. Run
  `scripts/verify.sh app` for guards/lint, hosted tests and universal Release.
  CI runs app verification directly; its Swift job already runs guards/lint.
  Required named suite is AppStartupTests, with nonzero/no-skip/no-expected-failure
  checks for the entire hosted run.
- Tests cover launch syntax/refusals, route handlers, counts and selection from
  the actual model, unloaded/failed state, and JSON replacement. Test logic first;
  view-model tests may accompany layout. No non-guard planted-fault exercises.
- Launch each supported screen in light/dark, inspect each PNG and read its matching
  state.json for counts, selection, inspector and idle. List tests, state.json,
  PNG and real-UI evidence separately in every PR.
- Computer use never blocks a PR. Do not wait for or retry it. Any unrun clicks,
  shortcuts, clipboard or glass checks go under **Pending unlocked check**. Land
  on tests, state/PNG evidence and green CI; do one short real UI pass later when
  unlocked and file discovered problems as follow-up fixes.
- SwiftPM and hosted xcodebuild tests must work while locked. The one-time proof
  is recorded in [#217](https://github.com/valtteriluomapareto/silta/pull/217);
  pending real UI checks never hold a PR.
- Stop owned fixture builds when testing ends. Do not terminate unrelated apps.

## Deferred slices

| Slice | Scope | Depends on | Verify with |
|---|---|---|---|
| C1a / SI-152 / #178 | Isolated v2 launch, current routes, atomic state, offscreen PNG, Release isolation | A2; model-owned navigation in A3/A4 | Launch/state tests, hosted tests, inspected PNGs, Debug/Release |
| C1b / SI-153 / #178 | `launch/state/wait/shot`, verified process ownership, window number | C1a; capture preflight before starting | Script/wait/shot tests and inspected real-window capture when available |
| C2 / SI-147 / #179 | Mailbox, dispatch through UI handlers, sequence barriers, copy and fixture-write refresh | C1b | Strict decoding/action tests and isolated external-write refresh |

C1b and C2 are not prerequisites for screen PRs. Add fixture variants, state
fields, routes and actions only when a screen needs them. C2 may proceed alongside
screen work once its own dependencies are satisfied; screens add live actions
later. Keep one slice per PR and no grandchildren tasks.

For C1b, the app publishes its actual window number. `shot` verifies that the
window belongs to the recorded live PID, then runs
`/usr/sbin/screencapture -l"$windowNumber" -o "$output"`. Before starting SI-153,
record a capture preflight from the actual execution host and permission context.
Screen Recording denial is a real limitation; offscreen PNGs or CUA success do not
prove this permission. The fallback is the same command in a human-authorized
Terminal, or a manual owned-window capture paired with its state/run. Do not grant
permissions automatically or block a screen PR on this capability.

C1b should consider Poimi's immediate failure on undeclared wait paths, rather than
requiring has(). Distinguish an unknown path from a declared null field; decide
this with tests then, without adding a jq/schema parser to C1a.

SI-146 remains the C1 implementation parent, doing and out of review until its
implementation parts are complete. SI-152 and SI-153 track those parts; plan-only
PR #186 belongs to SI-159. Give future plan-only PRs their own task. After merging
an app PR, submit its task and report it ready for the human to close; never run
`task done` or dogfood-finish for it.
