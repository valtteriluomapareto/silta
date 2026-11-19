# Silta for Mac development control plane

Validate the running app with an isolated Debug fixture. The
[Mac app plan](plans/mac-app.md#validation) explains what each validation layer proves.

## Fixture and offscreen output

Use the shared `v2` fixture from `SiltaAppSupport/Control`, its fixed clock and the
existing ID generator. `SiltaTestSupport` reuses these implementations. Every
launch creates a fresh private temporary data home before opening the app reader;
control never accepts or inherits an existing SILTA_HOME. The app’s product action
flows are documented in the [Mac actions plan](plans/mac-app-actions.md).

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
| `fixtureNow` | The fixture's fixed UTC timestamp, also used by the driver's fixture CLI |
| `screen`, `route` | Current screen and canonical route including selected ref and document view |
| `selection` | Null, typed `{kind: task/connection/app/service, ref: ...}`, or `{kind: document, ref: ..., view: ...}` |
| `inspectorOpen` | Flag belonging to the current route |
| `counts.lanes` | Visible Board lane counts, including current filters/proposals; null until loaded |
| `counts.sidebar` | Actionable waiting, claimed tasks and app open-count badges; null until loaded |
| `refresh` | `starting`, `loading`, `ready` or `failed`, plus the observed dataVersion |
| `idle` | The current route and selected read have settled, and no product write is in flight |

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

Build the Debug app from the repository with `scripts/verify.sh app`. Use a fresh
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

`shot` waits for ready and idle, a settled mailbox, and a real window number. It checks the live
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
| `copy.ref` | | Return the exact current task, app, service, connection or document ref in `copied`. |
| `copy.command` | | Return the Board inspector’s read command for the selected task in review in `copied`. |
| `refresh` | | Force a model refresh and settle the current scope. |

```sh
run=$(scripts/silta-app.sh launch)
scripts/silta-app.sh action "$run" '{"action":"select","screen":"board","ref":"AC-9"}'
scripts/silta-app.sh wait "$run" 'settledSeq=1' 'selection.ref="AC-9"' 'idle=true'
scripts/silta-app.sh action "$run" '{"action":"copy.command"}'
scripts/silta-app.sh fixture.write "$run" sample-proposal 'Check the Acme refresh'
scripts/silta-app.sh state "$run" counts.sidebar.waiting
scripts/silta-app.sh stop "$run"
```

The driver adds `version`, `run` and `seq` and publishes a UTF-8 `req-<seq>.json`.
Whitespace, member order and equivalent string escapes are accepted. The app
decodes scalar values, enforces each action's field set and refuses duplicate
decoded names, including escaped aliases. This prevents a direct mailbox writer
from making the action or run fields ambiguous. Tests
`wireAcceptsJSONFormattingAndRejectsEscapedDuplicateKeys` and
`strictWireDistinguishesMalformedAndStaleRequests` cover both rules.

The app consumes the next
sequence once, including malformed requests, and publishes `settledSeq` before an
atomic `res-<seq>.json`. Results include the run and sequence, plus `accepted`, `noop`
or `refused` with a stable reason. A refused action exits nonzero. Reasons distinguish
an invalid request, stale run, unknown selection, unavailable action, read failure,
and a superseded selection. The private response file holds copied text. Product
Copy buttons continue to use the Mac clipboard. The Board command check asserts
that AC-9 uses the review timeline command with the exact fixture `SILTA_HOME`.

After validating a ref, a windowed action calls the existing model handler and
waits for the read owned by the view. Offscreen snapshots explicitly load the
content they render. Refresh has the same behavior as ⌘R. With an unchanged Board
version it keeps the current inspector result. A current read failure returns
`readFailed`; a retained result from an earlier version stays pending until the
view's current read finishes. Users can change the selection while a request waits.

On an action timeout, retry the same JSON with `--seq N` to recover that request’s
result. Keep the run folder for its logs, state, and receipts. Stop and relaunch if
the window has closed or a read stays pending after the driver's deadline. The
server keeps the sequence unsettled while the read is pending.

`fixture.write RUN WRITE_ID TITLE` creates one Acme task proposal through the repository’s
built CLI, using only the run’s private `data/`, fixed argument list and published
fixture clock. Build both the CLI and the Debug app from the same checkout with
`scripts/verify.sh app`. The driver then sends
an ordinary `refresh` and reports the new task ref and refresh outcome. A fresh write
requires a live mailbox with no earlier action waiting to settle. Keep the same
write ID and title to retry refresh after a successful write. If the CLI result was
interrupted, inspect the fixture and the write receipt before doing another write.
The same ID cannot execute another CLI write, including after an ambiguous interruption.

### Failure handling

| Mechanism | Failure it prevents | Tests |
|---|---|---|
| Per-run client lock and mailbox preflight | Two drivers can race to reserve a sequence, or a new CLI write can change the data while an earlier action is still running. Reject a missing fixture clock before reserving an ID. | `test_client_lock_refuses_a_second_driver`, `test_new_write_does_not_create_intent_with_no_mailbox_or_pending_request`, `test_missing_clock_refuses_without_creating_intent` |
| Sequenced requests, stored responses and `--seq` recovery | An inspector toggle can run before a timeout or interruption drops the caller's answer. Reading the recorded result preserves the original toggle and copied value. | `test_published_action_failure_identifies_the_recoverable_sequence`, `test_action_waits_for_both_settlement_and_the_response_link` |
| Separate state settlement and response links | The filesystem can wake the client between the state update and the response link. A settled sequence alone does not give the caller its outcome. | `test_action_waits_for_both_settlement_and_the_response_link`, `mailboxWatcherDrainsFutureRequestAndRefusesStaleRunAtNextSequence` |
| Write-ID intent before spawning the CLI | The CLI can commit before the caller knows its result. An uncertain ID stays reserved so an ordinary retry cannot add a second task. | `test_intent_survives_interruption_and_never_replays` |
| Saved ref after the CLI returns | Refresh can fail after a successful write. The same ID and title let the caller retry refresh without rerunning the CLI. | `test_written_receipt_retries_only_refresh_after_failure` |
| Current selected read and app-write barrier | The new version can arrive before SwiftUI starts its read. A cancelled retry can leave an older value visible. A product write can be suspended before refresh. The mailbox and snapshots share the readiness check. | `refreshObservesAnOutsideWriteAndWaitsForTheCurrentInspector`, `cancelledRetryDoesNotValidateAValueFromBeforeTheFailure`, `statusStaysBusyUntilProductWriteCompletes` |

The native process check uses the effective UID, executable, working directory and
subsecond start time to keep stop and capture tied to the owned run. The write driver
refuses linked fixture storage because a symlink or hard link can point outside the
private directory. The mailbox rejects symlinks and nonregular files and bounds
request input to 16 KiB to keep a malformed manual request from reading another
file, blocking on a pipe or allocating an unbounded buffer.
