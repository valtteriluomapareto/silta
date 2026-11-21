# Silta for Mac: first actions

Status: active

## Goal

The human clears what waits on them in My work without a terminal. They can answer a
question, accept an answer, comment, accept task proposals and unblock a ready task.
Each action is one SiltaCore service call made by the app as `human:<USER>` (D38, D50).

## Inputs

- Designs: Paper file "Silta", page "Actions v1":
  - My work with an answer box, an answer card and proposal checkboxes;
  - the inspector's Answer/Comment box;
  - the sending, error and dark states;
  - notes.

  The plan review cut the confirm sheets, the replan unblock and the Board card
  button, so those parts of the page are superseded.
- Spec:
  - §4.1: one core, thin front-ends. The app calls services with an actor; the CLI and
    the app never talk to each other.
  - §11 and D38: the app counts as `human:*`.
  - §17: writes take `BEGIN IMMEDIATE` and check `min_writer_version`.
  - §19: the command log.
- [`mac-app.md`](mac-app.md): the app, its store states and its control
  support.

## Scope

**In:**
- **`AppWriter` in `SiltaAppSupport`**, built from an `AppReader` and sharing its home,
  user and clock. One entry point, `perform(_ write: AppWrite, workspace:)`. `AppWrite`
  is an enum: answer, comment, accept answer, accept proposals, unblock.
  - It acts as `human:<USER>` and calls the existing services (`TaskService.comment`,
    `acceptComment`, `triage`, `unblock`) with their current arguments; `unblock` gains
    a package `requireReady` option that the CLI doesn't use.
  - **Existing store only.** Each write opens a fresh `DatabaseStore` with a new
    package option, `existingOnly`. Under the migration lock, `initialize` then
    refuses:
    - a missing `silta.db`, as `cannotOpen`, before creating any directory;
    - a pending migration, as a new `StorageError.migrationRequired` (code `env`).

    `min_writer_version` and a newer schema refuse as `schemaTooNew`, as they already
    do. So the app doesn't create or migrate a store. A file deleted in the instant
    between the recheck and SQLite's open would still be recreated empty. The CLI's
    behaviour doesn't change.
  - Failures throw `AppReadError`, the viewer's body-free coded error, which is also
    used for writes. Store refusals keep their kinds (`unavailableStore`,
    `migrationRequired`, `newerSchema`). Everything else is `other`, with Core's code
    and message.
  - A human's text containing a secret is refused by Core (`SecretError`, `invalid`).
    The app keeps the draft and shows the message. `--allow-secret` stays out.
  - Accepting an already-accepted answer returns Core's `unchanged` and counts as
    success.
  - **Log line:** each write appends one body-free line to the §19 log. The command is
    `app answer`, `app comment`, `app accept-answer`, `app triage` or `app unblock`,
    with the actor, workspace, milliseconds, and the exit code and error code a CLI
    failure of the same kind would give. So DF3 can tell app use from terminal use.
- **App model.**
  - `AppModel` takes a `Writer` closure beside its `Loader`:
    `(AppWrite, workspace) async throws -> Void`. Tests inject a controlled writer,
    as `ControlledLoads` does for reads.
  - A draft is keyed by its domain target: the question ref for an answer, the task
    ref for a comment, plus the workspace. So the My work card and the inspector share
    one draft and one in-flight guard.
  - One write per target at a time; the field and button are disabled while it runs.
    A failure is stored per target with the error.
  - Drafts clear only on success. A draft whose target has gone is simply never shown
    again. Unsent drafts are kept in the app's defaults, so they outlast a quit,
    and automated control runs keep them in memory only.
  - Every write, success or failure, forces a refresh and reloads the open task
    detail. That also covers stale views: `conflict`, `not_found` or `claimed`.
  - A slow write (busy retries) shows "Sending…" until Core returns or gives up. Core
    bounds its retries, and `busy` shows Core's retry message.
- **Views** (Actions v1):
  - **My work question card:** an answer box with "Send answer" (⌘↩), disabled while
    empty, and "Copy command" kept.
  - **My work answer card:** the answer, its thread ref, "Accept answer", and "Open
    task", which opens the task in the Board inspector.
  - **Inspector:** one box under the discussion. If the task has an unanswered
    question to the human, an Answer/Comment switch appears; Answer targets the
    newest such question. Otherwise the box is Comment only.
  - **My work proposal card:** checkboxes, none ticked at first, and "Accept N". It
    sends one all-or-nothing `triage` with no sheet. The selection is dropped for
    refs that leave the list.
  - **My work `ready` item:** "Unblock". Core unblocks a human's task even with an open
    blocker, so the app offers it only on `ready` items. `replan` items keep their
    read command. The write passes Core's `requireReady`, so a blocker added since the
    read refuses as `blocked` instead of being cleared. Unblock has its own target, apart
    from the task's comment draft.
  - **Errors** show in the card or inspector with the code, the message and "Copy
    command".
- **Fixture:**
  - B1: a human question on AC-14, answered by Codex (one `answer` item).
  - B2: AC-17 blocked on a new task AC-19, which Claude then finishes (one `ready`
    item and one more task done this week). A task blocker must be open when the block
    is set, so it can't name an already-done task.
  - The affected count assertions change in the same commit, which says so.
- **Docs:**
  - `mac-app.md` stops saying the app never writes or logs.
  - D50 records in-process human writes, existing store only, and the `app …` log
    line.
  - §19 gains the `app …` commands.

**Out:**
- Doc triage, approve and done, archive, dropping proposals, editing plans, and
  `--allow-secret`.
- Unblocking `replan` items: Core suggests a re-plan, and the open blockers would be
  unlinked.
- An Unblock button on Board cards: the card is one button, and the inbox cap would
  make the button flicker.
- Confirm sheets.
- A "You asked: …" line on the answer card. The inbox item carries the question's
  ref, not its text.
- The §17 change signal.
- Real-window checks of focus, ⌘↩ and VoiceOver.

## Slices

| Slice | Scope | Depends on | Verify with |
|---|---|---|---|
| B1 (SI-198) | `existingOnly` store option and `StorageError.migrationRequired`; `AppWrite` and `AppWriter` with the log line; answer, accept answer and comment; the model `Writer` seam, drafts and action state; My work question and answer cards; the inspector box; the AC-14 fixture thread; this plan, D50 and §19 | A6b | Core: `existingOnly` refuses a missing store (no directory created) and a pending migration (db bytes unchanged). `AppWriterTests` on an isolated seeded home: answer, comment and accept land as `human:acme` and show in a fresh `AppReader` read; `min_writer_version` 999 refuses as `newerSchema`; a secret is refused with `invalid`; a non-asker accept keeps Core's code; a repeat accept succeeds; one log line per write with no body; a CLI write between the read and the write. Model: the draft is shared by My work and the inspector, kept on failure and cleared on success; a second send while one is in flight is refused; every write forces a refresh; Answer/Comment choice. Light and dark PNGs of the question and answer cards and the inspector box |
| B2 (SI-199) | Accept proposals and unblock ready tasks; checkboxes and the selection; the AC-17 block on AC-19 | B1 | `AppWriterTests`: triage accepts only the chosen refs. A ref accepted elsewhere first fails the batch with `conflict`, and the others stay proposed. Unblock of a ready task returns it to todo. Model: selection, "Accept N", pruning after refresh, Unblock only on `ready`. Light and dark PNGs |

Each slice is one PR. Writes are test-first: the store and `AppWriterTests` come
before the views.

## Validation

- `scripts/verify.sh app` and `quick` on each PR.
- Tests run against an isolated seeded home, never `~/.silta`.
- True write contention is covered by Core's storage tests. These tests sequence a
  CLI write between the app's read and its write instead of racing them.
- PNGs cover the states a route reaches: cards, inspector box, checkboxes. Sending
  and error states are covered by model tests only.
- **Unverified until a live run:** keyboard focus, ⌘↩ and VoiceOver announcements.
- **Unverified:** a store deleted while a write holds the migration lock. The recheck
  under the lock has no test, because deleting between two file calls needs a hook
  Core doesn't have.

## Risks

- **A write races a CLI write.** Core's transaction validates inside `BEGIN
  IMMEDIATE`. The forced refresh shows the new state.
- **The app is older or newer than the store.** `existingOnly` and the writer floor
  refuse the write, and the refresh shows the store state.
- **Typed text is lost.** Drafts clear only on success; a test proves it.

## Done when

B1 and B2 are merged and dogfooded once on the `silta` workspace from the installed
app. Then fold the lasting rules into `mac-app.md` and the spec's app section, and
delete this file.
