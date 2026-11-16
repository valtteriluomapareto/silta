# Silta for Mac: a read-only viewer

Status: proposed

## Goal

A native macOS 26 app shows the human what waits on them, what agents are doing, the
workspace map, and its docs. It reads everything through `silta --json`. Every action
is a command the human copies and runs in Terminal, so v1 never writes.

## Inputs

- Designs: Paper file "Silta", page "MVP v2":
  - screens: My work, Board, Docs, Workspace;
  - a states and dark-mode sheet;
  - notes with the glossary and fixture dataset.
- The feasibility review is on page "MVP v1".
- Reviewed by three personas: an end user, an Apple HIG designer and a nitpick UX
  designer.
- Spec §16: commands, JSON shapes and error codes.
- Spec §11: actors. A process without a TTY resolves to `agent:unknown`, so human-only
  writes refuse. That is why v1 is read-only.
- [`workspace-knowledge.md`](workspace-knowledge.md) supplies docs, proposals and
  `doc triage`.
- D38: an agent never supplies approval words. The app doesn't either.

## Scope

**In:**
- **Sidebar:** workspace switcher, My work, Board, Workspace and Docs, apps with open
  counts, "Claimed now", and refresh status.
- **My work:** `inbox --for me`, plus tasks in `review` from `task ls`.
- **Board:** lanes from `task ls`. Plan progress comes from `task show` for claimed
  tasks only.
- **Inspectors:** a task inspector (`task show --timeline`) and a connection inspector
  (edges from the `ws show` YAML).
- **Docs:** a three-column view with Document, Changes (`doc show --diff`) and
  Comments (`--comments`) tabs, a revision menu (`--rev`), and paging (`--lines`).
- **Copy:**
  - a ref chip on every item;
  - command blocks with brass placeholders that never decide for the human;
  - a Copied state;
  - ⌘C and a context menu.
- **States:**
  - silta missing or too old;
  - first load, updating, stale and failed refresh;
  - empty, long text and many items;
  - dark mode.
- **Accessibility:** contrast at least 4.5:1 for readable text, VoiceOver labels on
  icon-only controls, and keyboard navigation (⌘1–⌘4, ⌘F, ⌥⌘I).

**Out:**
- Any write from the app: answering, accepting, triaging, done, edits.
- Reading `silta.db` directly.
- A daemon or polling loop.
- Agent liveness: Silta has none.
- A workspace-wide activity feed.
- A free-form graph map.
- Notifications.
- iOS.

## Design

- **One process boundary.** A `SiltaClient` runs `silta --ws <slug> … --json` and
  decodes the envelope. It sets `SILTA_ACTOR=agent:silta-app:<launch id>`, so the
  command log shows the app's reads apart from agents'.
- **Data contract.** The app decodes only fields that `silta schema` publishes. At
  launch it checks the binary's version and schema. It needs the doc JSON fields from
  D0, and refuses an older binary with the missing-silta state.
- **Freshness:**
  - Watch `$SILTA_HOME/silta.db` and `-wal` with FSEvents, never the `log/` folder,
    because the app's own reads write log lines.
  - Debounce 300 ms, then re-run only the visible screen's queries.
  - If a refresh fails, keep the last data and show the error in the sidebar footer.
- **Copy text.** It comes from the inbox's `next` commands, or from a template filled
  with real refs. Fields the human must choose, such as answer text, refs to accept,
  or a sha that isn't known yet, become visible placeholders.
- **Layout:**
  - `NavigationSplitView`, two columns, or three for Docs;
  - `.inspector` for details;
  - `.searchable` in the toolbar;
  - Glass only on the sidebar, toolbar and controls;
  - the app accent is tide `#0B6E8E`, from the asset catalog.
- **Code location.** The app lives in `Apps/SiltaMac` as an Xcode project. Its data
  layer, `SiltaAppKit` (client, decoding, view models, command templates), is a
  SwiftPM library tested with `swift test` and kept apart from `SiltaCore`. Markdown
  rendering uses a vetted package; MarkdownUI is the candidate.

## Slices

| Slice | Scope | Depends on | Verify with |
|---|---|---|---|
| D0 (SI-143) | `doc ls` and `doc show` JSON gain structured fields (title, kind, about, revision, state, actor, created_at, why, source task, body); text output unchanged | — | Schema golden; JSON goldens; spec §16 |
| A1 | App shell: Xcode project, `SiltaAppKit`, `SiltaClient`, version check, FSEvents refresh, sidebar, toolbar, missing-silta and refresh states, ref chip and command block components with copy | D0 | Decoding tests against JSON from a fixture workspace; component previews; contrast check |
| A2 | My work and Board with the task inspector; claims in the sidebar | A1 | View-model tests on the v2 fixture dataset (counts must reconcile); manual pass on a dogfood workspace |
| A3 | Workspace: apps, connections and the connection inspector from the `ws show` YAML | A1 | YAML decoding tests on `docs/examples/acme-workspace.yaml` |
| A4 | Docs: list, reader, Changes, Comments, revisions, paging; the doc-triage command block | A1, D0, SI-134 (`doc triage`), SI-126 diff fix | Rendering tests on fixture docs; a long-doc paging test |

A2 and A3 run in parallel after A1. A4 waits for its CLI dependencies.

## Validation

- `SiltaAppKit` tests decode real CLI output from a scratch workspace, built the way
  `HelpCommandTests` seeds one. A JSON contract change then breaks the app's build,
  not the app at runtime.
- Every command template is executed in the fixture workspace with its placeholders
  filled, and must not fail with a usage error.
- **Not verified until DF3:** whether the human uses the app daily, or keeps working in
  the terminal.

## Risks

- **Refresh loops.** Reads that write to the database would trigger themselves.
  Watching only the database files and debouncing makes this visible in testing.
- **Process cost.** About 3–6 CLI calls per refresh, around 100 ms each. If a screen
  feels slow, add one combined read to the CLI rather than reading the database
  directly.
- **Copy-and-paste fatigue.** v1 is honest but adds a step. The fix is a v2 design for
  an app human actor (spec §11), not a workaround.
- **Contract drift.** Caught by the decoding tests above.

## Done when

- A1–A4 have merged.
- The app runs against the dogfood workspace for a week with no data mismatches
  against the CLI.
- The states sheet and dark mode match the designs.

Then record the app's actor and read-only contract in `spec.md` §11 and the
read-only decision in `decisions.md`, and delete this file.
