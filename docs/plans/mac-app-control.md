# Silta for Mac development control plane

Status: active

## Goal

Validate the running app with an isolated Debug fixture. C1a shipped in #214.
The [Mac app plan](mac-app.md#validation) explains what each validation layer proves.

## Fixture and offscreen output

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
  screens are `mywork`, `board[:task-ref]`, `workspace[:edge-, app- or service-ref]` and
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
  state/PNG evidence. Each snapshot also writes `sidebar.png` from the real
  AppSidebar. With Board or Workspace's inspector open, it writes `inspector.png`
  from the real task, connection, app or service inspector. These filenames are reserved;
  choose a different name for the root PNG. Parts use the same model and logical
  height, at 240 and 360 points wide, with active control appearance.
- Render the real AppShellView in an offscreen NSHostingView, using
  `bitmapImageRepForCachingDisplay` and `cacheDisplay`. Do not use ImageRenderer:
  it cannot draw the native split view, lists or inspectors. This path shows
  layout and content. The native toolbar, glass and vibrancy require a real window. It does not
  require Screen Recording permission. Inspect every resulting PNG.
- State projects model-owned route, typed selections, per-route inspector flags
  and loaded data. Observation schedules a coalesced projection after mutation;
  writes use atomic replacement, never view-body side effects.

### state.json version 1

| Field | Meaning |
|---|---|
| `snapshotVersion` | Schema version, currently 1 |
| `seq`, `settledSeq` | Last issued and settled action sequence. Both start at zero in a driver run and are null in other modes. |
| `pid`, `windowNumber` | Process ID and real window number. The window number is null until available and in offscreen mode. |
| `run`, `revision` | Unique launch identity and increasing publication number |
| `fixture`, `appearance` | `v2` and `light`/`dark` |
| `screen`, `route` | Current screen and canonical route including selected ref and document view |
| `selection` | Null, typed `{kind: task/connection/app/service, ref: ...}`, or `{kind: document, ref: ..., view: ...}` |
| `inspectorOpen` | Flag belonging to the current route |
| `counts.lanes` | Visible Board lane counts, including current filters/proposals; null until loaded |
| `counts.sidebar` | Actionable waiting, claimed tasks and app open-count badges; null until loaded |
| `refresh` | `starting`, `loading`, `ready` or `failed`, plus the observed dataVersion |
| `idle` | Initial loading, selected task/document content and current scope/version refresh have settled |

Lane keys use their displayed names: Todo, Doing, Review, Done this week. Failed
loads may be idle; also check refresh.phase. Idle does not prove painted pixels.
Bodies, comments, filesystem paths and arbitrary error messages are excluded.
The sequence gap `seq > settledSeq` indicates an action in progress.

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

## Drive a fixture from the terminal

Build the Debug app from the repository with `scripts/verify.sh app` or
`scripts/run-mac-fixture.sh` (the latter also opens a fixture window). Use a fresh
run for each independent check. `launch` prints its private directory after the
requested route and its initial reads settle. The directory contains `app.log`,
`state.json`, the fixture store in `data/` and the driver’s process record.
`stop` terminates the matching fixture and leaves the directory for inspection.

```sh
run=$(scripts/silta-app.sh launch --route board:AC-12 --dark)
scripts/silta-app.sh state "$run" selection
scripts/silta-app.sh wait "$run" 'idle=true' 'refresh.phase="ready"' 'selection.ref="AC-12"'
scripts/silta-app.sh shot "$run" "$run/board.png"
scripts/silta-app.sh stop "$run"
```

`state RUN [PATH]` prints JSON. `wait` takes one or more `PATH=JSON` arguments
and prints the matching state. Quote strings as JSON even inside shell quotes.
It listens for file replacement and process exit, with a monotonic deadline.
Timeouts show the expected and last observed values. Declared nullable fields
can be matched with `null`. Unknown fields fail immediately; lane names and app
slugs are literal path segments and must exist in the loaded snapshot. `launch`,
`wait` and `shot` accept `--timeout SECONDS`. For `shot`, it caps the readiness
wait and `screencapture` independently. Process identity checks have separate
short bounds.

`shot` waits for ready and idle plus a real window number. It checks the live
process identity and Core Graphics window owner before and after `screencapture
-l<id> -o`. It publishes a PNG and matching `<output>.json` only if both checks
pass and the projected state agrees before and after capture (ignoring the publication
number). The sidecar records the post-capture endpoint. Model state can change
and return between those endpoints. Choose unused output
paths. Screenshot capture requires Screen Recording in a usable window session.
If it fails, run `shot` in an authorized Terminal on the same Mac, or take a
manual capture of the owned window and record its run/route/revision. Use
`-SiltaSnapshot` for offscreen evidence. The fixture validation and merge gate
stay available without either real-window capture path.

## Live actions and fixture writes

`action RUN JSON` calls the same model handlers as the app’s controls. It is available
in interactive runs created with `scripts/silta-app.sh launch`. Arguments are JSON
objects with the exact fields below:

| Action | Extra fields | Meaning |
|---|---|---|
| `nav` | `screen` | Open `mywork`, `board`, `workspace`, or `docs`. |
| `select` | `screen`, `ref`, optional `view` for Docs | Select a Board task, Workspace edge/app/service, or Docs revision. Docs views are `document`, `changes`, `comments`. |
| `inspector.toggle` | | Open or close the current Board or Workspace inspector. |
| `copy.ref` | | Copy the current task, app, service, connection or document ref to the Mac clipboard. |
| `copy.command` | | Copy the Board inspector’s read command for the selected task in review. |
| `refresh` | | Force a model refresh and settle the current scope. |

```sh
run=$(scripts/silta-app.sh launch)
scripts/silta-app.sh action "$run" '{"action":"select","screen":"board","ref":"AC-9"}'
scripts/silta-app.sh wait "$run" 'settledSeq=1' 'selection.ref="AC-9"' 'idle=true'
scripts/silta-app.sh fixture.write "$run" sample-proposal 'Check the Acme refresh'
scripts/silta-app.sh state "$run" counts.sidebar.waiting
scripts/silta-app.sh stop "$run"
```

The driver serializes clients with a per-run lock. It adds `version`, `run` and `seq`
and publishes a compact, sorted UTF-8 `req-<seq>.json`. The app consumes the next
sequence once, including malformed requests, and publishes `settledSeq` before an
atomic `res-<seq>.json`. Results include the run and sequence, plus `accepted`, `noop`
or `refused` with a stable reason. A refused action exits nonzero. Reasons distinguish
an invalid request, stale run, unknown selection, unavailable action, read failure,
superseded selection, and clipboard failure. The model’s loader state is checked before
completing a selection. Users can still change the window while a request is in flight.

On an action timeout, retry the same JSON with `--seq N` to recover that request’s
result. The driver checks the stored request to avoid applying it twice. Keep the run
folder for its logs, state, and receipts. Stop and launch a fresh fixture if a child
exits or the run can’t be recovered.

`fixture.write RUN WRITE_ID TITLE` creates one Acme task proposal through the repository’s
built CLI, using only the run’s private `data/` and a fixed argument list. It then sends
an ordinary `refresh` and reports the new task ref and refresh outcome. Keep the same
write ID and title to retry refresh after a successful write. If the CLI result was
interrupted, inspect the fixture and the write receipt before doing another write.
The same ID cannot execute another CLI write, including after an ambiguous interruption.
Copy actions write only to the clipboard and the mailbox never executes copied commands.

## Slices

| Slice | Scope | Status |
|---|---|---|
| C1a / SI-152 / #178 | Isolated v2 launch, route selection, state JSON and offscreen PNG | Shipped in #214, with additional screens and snapshot parts in later PRs |
| C1b / SI-153 / #178 | Driver, predicate waits, owned real-window capture and cleanup | Implemented in C1b |
| C2 / SI-147 / #179 | Mailbox, shared UI handlers, sequence barriers, copy and fixture-write refresh | Implemented in C2 |

Neither C1b nor C2 blocks screen PRs. Add fixture variants, state fields, routes
and actions as screens need them. Keep one slice per PR and no grandchildren tasks.

SI-146 remains the C1 implementation parent, doing and out of review until its
implementation parts are complete. SI-152 and SI-153 track those parts; plan-only
PR #186 belongs to SI-159. Give future plan-only PRs their own task. After merging
an app PR, submit its task and report it ready for the human to close; never run
`task done` or dogfood-finish for it.
