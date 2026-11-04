# Silta — local project context & backlog for agents

Status: **draft v0.3** · 2026-11-02 · personal project by Valtteri Luoma · changes in Appendix C

## Name

*Silta* is Finnish for **bridge**. It means four things here:

1. ***Komentosilta*, a ship's command bridge.**
   - It's where the watch stands, the log is kept, the charts are read and the
     captain signs off.
   - Each agent session "comes onto the bridge", gets the picture, works its watch
     and hands over.
   - You're the captain, and the macOS app is your view of the bridge.
2. **A bridge across space.** It connects repos and branch-apps: a mobile app ↔
   the API branch of a platform repo ↔ a sales portal. The agent sees across without
   leaving its side.
3. **A bridge across time.** It connects sessions that never meet. This is
   *vahdinvaihto*, the change of watch: handoffs, results and decisions carry the
   work forward.
4. **A bridge between worlds.** It connects:
   - Finnish meeting talk and English code
   - humans and agents
   - Claude, Codex and OpenCode
   - what's in your head and what's written down

In documentation, the ship vocabulary is welcome: "come onto the bridge", "change of
watch", "the log". CLI commands stay plain (`silta brief`, `silta task add`), because
models act most reliably on ordinary words.

**Identifiers** follow the personal-app scheme used by Poimi and Photo Export:

| Thing | Value |
|---|---|
| Product / app | Silta, `Silta.app` |
| CLI | `silta` |
| Bundle id, OSLog subsystem | `com.valtteriluoma.silta` |
| Change notification | `com.valtteriluoma.silta.changed` |
| Data directory | `~/.silta` (override: `SILTA_HOME`) |
| Environment variables | `SILTA_HOME`, `SILTA_ACTOR`, `SILTA_SESSION`; for tests and scenarios: `SILTA_NOW`, `SILTA_ID_SEED`, `SILTA_SLOW_TESTS` (§20.1) |
| Copyright | Valtteri Luoma |

Silta is a personal project. The data of the projects you use it on stays in your
local database and in exports you control. It never goes into the Silta repo, its
fixtures or its evals. Examples in this spec use a fictional workspace, **Acme**.

## 1. Problem

Real project work often spans:
- several repos, and sometimes one repo holds several *apps* on different long-lived
  branches
- meeting notes in a separate repo
- knowledge about external services and release flows that lives mostly in one
  person's head

A new agent session starts blind. An agent in the Flutter app doesn't know which
backend branch serves it, what was decided in last week's meeting, or what work is
already planned. Today's workarounds are copy-pasting context, filling the team's tracker
(Azure DevOps, Jira, GitHub Issues) with agent-created work items, or leaving plan files
in product repos.

## 2. Goals

1. **One command gives any agent the picture** for where it's working: the task it's
   on, the app, neighbouring apps, open work and recent decisions, within a small
   token budget.
2. **Docs live in the app**, not in per-project repos. One tool, many workspaces
   (one per project or engagement).
3. **Local backlog** that agents read and write instead of the team tracker or plan files.
   Plans are stored *on the task*.
4. **Read other apps' code safely**, including branch-as-app repos, without checkouts.
5. **Link meeting notes to apps and topics**, so decisions can be found from code.
6. Works for **Claude Code and Codex** through a plain CLI, and is **measurably
   usable by other harnesses and models** (§21).
7. **Tasks are discussable, like a small GitHub issue**: questions, answers, decisions,
   handoffs, and (M2) reviews with verdicts.
8. **Useful within 15 minutes of install**, and cheap enough to keep using.

## 3. Non-goals

- Not a replacement for the team's tracker. The tracker stays the record of committed
  work; `silta` is the working layer underneath it (§8).
- Not a general wiki or a copy of code. Docs point at code. They don't restate DTOs,
  routes, config keys or folder layouts.
- Never stores secrets. It stores *where* a secret lives (§18).
- No server, no sync in v1. Single user, local machine.
- No MCP server and no daemon (D4).
- No reactions or social features. Discussion is for getting work done.
- Doesn't replace repo-local `AGENTS.md`/`CLAUDE.md`. Facts about one repo stay in
  that repo; `silta` holds what spans repos or lives outside them.

## 4. Core design decisions

| # | Decision | Why |
|---|---|---|
| D1 | **SQLite is the source of truth** for everything `silta` owns. Humans edit configuration as YAML (`silta ws edit`), which is validated and applied to the DB. | Relations and queries are first-class; YAML is just an editing view. |
| D2 | **External sources are indexed, never owned.** Meeting-note folders and repo docs are read-only and re-indexed on change. | Notes stay the output of whatever produces them; repo docs stay in repos. |
| D3 | **Deterministic export** to a text tree for backup and diff. `silta restore` replaces a workspace from it. | A `.db` file can't be diffed or reviewed; the export can. |
| D4 | **CLI only, `--json` everywhere. No MCP server, no daemon.** | Every target harness has a shell tool. If shell-less clients ever matter, it would be a `silta mcp` stdio subcommand, never hosted in the app. |
| D5 | **Agent writes are gated.** Unsolicited agent tasks start as `proposed`. Agent doc edits are proposed revisions. Human-only commands need the human's go-ahead (D38). | Prevents spam and rot by default, without blocking work the human asked for in chat (§8). |
| D6 | **`silta` resolves "where am I"** from cwd, git branch, upstream and claimed task (§7). | Agents shouldn't need to know which branch is which app. |
| D7 | **Code access is read-only** via `git show`/`grep`/`log` on configured refs. | No checkout means you can't edit the wrong branch. |
| D8 | **Truth and derived data in separate files.** `silta.db` holds plain tables only, including every human decision. `index.db` holds search, caches and verify results, and can be deleted at any time. | The search engine and indexes can change without risk to data people wrote. |
| D9 | **Every write has an actor with a session.** Unknown callers count as agents, never as humans (§11). | Claims, inboxes, rate limits and human-only rules depend on it. |
| D10 | **Agent-facing contracts are tested like an API**: the guide, `--json` shapes, exit codes and error hints, across harnesses and models (§21). | Agents are the main users. Regressions in wording are real bugs. |

Later decisions (D11 onward: technology, the scripting contract, and process) and any
updates to these ten are in [`decisions.md`](decisions.md). Two shape the whole tool:
- **D37: the human's attention is the budget.** Silta should cost the human about ten
  minutes a day, in one sitting.
- **D38: the human works through agents.** The human talks to an agent, which runs
  `silta` for them. Only the Mac app (M5) is the human's own surface.

## 4.1 Architecture

```
  Agent sessions (Claude Code, Codex, OpenCode…)             You
        │ shell tool                                          │
        ▼                                                     ▼
  ┌────────────┐  short-lived, one process          ┌──────────────────┐
  │  silta …     │  per command                       │  Silta.app (M5)    │
  │  (CLI)     │  actor: agent:<tool>:<session>     │  actor: human    │
  └─────┬──────┘                                    └────────┬─────────┘
        └──────────────────────┬─────────────────────────────┘
                               ▼
  ┌───────────────────────────────────────────────────────────────────────┐
  │ SiltaCore (Swift package, no UI/CLI imports)                             │
  │  Services  Tasks · Comments/Reviews · Docs · Brief (+ rendering)       │
  │            Search · Index · Verify · Export/Restore · Location         │
  │  Policy    actor rules · secret guard · gates · rate limits            │
  │  Storage   GRDB records (extensions) · DatabaseMigrator · leases       │
  │  Adapters  GitRunner (read-only, sanitized) · NotesParser · Notifier   │
  └──────────────┬─────────────────────────────────────┬──────────────────┘
                 │ SQLite (WAL)                         │ git show/grep/log
                 ▼                                      ▼
       ~/.silta/silta.db (truth)                  ~/work/acme/* repos + worktrees
       ~/.silta/index.db (derived)              ~/notes (indexed)

  every write (from M5) → notify_post("com.valtteriluoma.silta.changed") → Silta.app refreshes
```

- **One core, thin front-ends.** All rules live in `SiltaCore`, including brief
  rendering (text and JSON), because the hook, the CLI and the app all use it. The
  front-ends parse input, call a service with an actor, and render the result.
- **Engine-free domain.** Domain types don't import GRDB. Record conformances live in
  the storage layer as extensions, which keeps a later Postgres port possible.
- **The database is the integration point.** The CLI and the app never talk to each
  other, and agents don't need the app running.
- **One version.** From M5 the CLI ships inside the app bundle
  (`Silta.app/Contents/Helpers/silta`). Every write transaction checks
  `min_writer_version` (§17).
- **Data directory.** `SILTA_HOME` (default `~/.silta`) relocates everything. Tests and
  evals use it, and the real data is never touched.

## 5. Concepts

- **Workspace**: one project or engagement, with a task prefix (`AC`).
- **Repo**: a local clone. Worktrees resolve to their main repo.
- **App**: something deployable: `repo + ref (+ optional subpath)`, with an optional
  prod ref. One repo can hold several apps. For each ref, one app is **primary**;
  subpath apps (e.g. `crm-ui`) share a ref with a primary app.
- **Environment, Service, Edge**:
  - an environment is where an app is deployed (test or prod)
  - a service is an external system
  - an edge says which app calls which app or service

  All three are edited only as YAML sections (`silta ws edit`).
- **Topic**: a stable theme slug with aliases in any language (the glossary).
- **Task**: a backlog item with plan, result, comments and links.
- **Comment**: a post on a task or a doc revision. Its kind is one of `comment`,
  `question`, `answer`, `decision` or `handoff`. Threads can be resolved.
- **Review** (M2): a comment with a verdict on a subject (the task's diff, a plan
  revision, or a doc revision), with line comments.
- **Doc** (M2): a versioned markdown document owned by `silta`.
- **Source**: a folder that is indexed: meeting notes or repo docs.
- **Actor**: `human:<name>`, `agent:<tool>:<session>` or `agent:unknown:<session>`.
- **External party**: someone or something outside Silta that work waits on, such as a
  customer, another team or an app store: `ext:acme`. A party is waited on but never
  acts, so it is not an actor. Parties are plain names, not edited in the YAML and
  never renamed; a service (above) is a system the code calls (D35).

### 5.1 Reference grammar

One grammar everywhere: in arguments, in `--json`, and in `[[…]]` links inside
bodies. A bare task id is accepted wherever a task is expected.

| Ref | Example | Notes |
|---|---|---|
| Task | `AC-12` | `task:AC-12` is also accepted |
| Comment | `AC-12/3` | the 3rd comment on AC-12 |
| Doc / revision / comment | `doc:mobile-auth-flow`, `doc:mobile-auth-flow@4`, `doc:mobile-auth-flow@4/2` | |
| App, topic | `app:platform-api`, `topic:messaging` | |
| Code | `platform-api:src/Api/Controllers/AuthController.cs#L40-52` | `code:` prefix optional; `@<ref>` after the app picks another branch: `platform-api@feature/x:path` |
| Plan lines | `plan@3#L12-18`, `plan#L12` | latest revision when `@n` is omitted |
| Diff lines | `diff:lib/push/categories.dart#L88`, `#-L88` for the old side | relative to the task's review subject; CLI resolution waits for the M2 subject producer |
| Note | `note:notes/projects/acme/2026-10-26-weekly-status.md` | |
| URL | `url:https://dev.azure.com/…` | |
| External party | `ext:acme` | 1–64 lowercase letters, digits and `-`, starting and ending with a letter or digit; something a task waits on, never an actor (D35) |

`silta help refs` prints this table. The parser has golden tests (§20).

## 6. Data model

Timestamps are ISO-8601 UTC with milliseconds. Ordering ties are broken by `id`.
Time comes from an injected `Clock`; ULID timestamps round to the nearest millisecond.
Every owned row has a `uid` (a ULID) used by
export and restore, and kept for a future sync or Postgres move. Owned entities
reference each other by **foreign keys**; strings appear only for external things
(notes, code, URLs).

### `silta.db` (truth)

```sql
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  -- 'min_writer_version', 'change_seq', 'last_backup_day'

CREATE TABLE workspace (
  id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
  slug TEXT NOT NULL UNIQUE,                  -- 'acme'
  name TEXT NOT NULL,
  task_prefix TEXT NOT NULL UNIQUE,           -- 'AC'
  settings TEXT NOT NULL DEFAULT '{}'         -- JSON (D39): review_gate, archive_after_days, stale_days, proposals, ask_about, agent_doc_writes
);

CREATE TABLE repo (
  id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
  workspace_id INTEGER NOT NULL REFERENCES workspace(id),
  slug TEXT NOT NULL, remote_url TEXT, default_ref TEXT,
  UNIQUE (workspace_id, slug)
);
CREATE TABLE repo_path (                      -- machine-local; not exported
  repo_id INTEGER PRIMARY KEY REFERENCES repo(id),
  path TEXT NOT NULL UNIQUE,                  -- canonical (realpath, case-folded on case-insensitive volumes)
  fetched_at TEXT
);

CREATE TABLE app (
  id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
  workspace_id INTEGER NOT NULL REFERENCES workspace(id),
  slug TEXT NOT NULL, previous_slugs TEXT NOT NULL DEFAULT '[]',
  name TEXT NOT NULL,
  repo_id INTEGER NOT NULL REFERENCES repo(id),
  ref TEXT NOT NULL, prod_ref TEXT, subpath TEXT,
  is_primary INTEGER NOT NULL DEFAULT 1,      -- one primary per (repo, ref, subpath IS NULL)
  stack TEXT, summary TEXT,
  lifecycle TEXT NOT NULL DEFAULT 'active',   -- active | legacy | dead
  UNIQUE (workspace_id, slug)
);
CREATE UNIQUE INDEX app_primary_ref ON app(repo_id, ref) WHERE is_primary = 1 AND subpath IS NULL;
CREATE TABLE environment (id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
  app_id INTEGER NOT NULL REFERENCES app(id), name TEXT NOT NULL, url TEXT, deploy TEXT, notes TEXT);
CREATE TABLE service (id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
  workspace_id INTEGER NOT NULL REFERENCES workspace(id), slug TEXT NOT NULL, name TEXT NOT NULL,
  summary TEXT, secrets_location TEXT, UNIQUE (workspace_id, slug));
CREATE TABLE edge (id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
  workspace_id INTEGER NOT NULL REFERENCES workspace(id),
  from_app_id INTEGER NOT NULL REFERENCES app(id),
  to_app_id INTEGER REFERENCES app(id), to_service_id INTEGER REFERENCES service(id),
  kind TEXT NOT NULL, summary TEXT NOT NULL, code_refs TEXT NOT NULL DEFAULT '[]',
  CHECK ((to_app_id IS NULL) <> (to_service_id IS NULL)));

CREATE TABLE topic (id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
  workspace_id INTEGER NOT NULL REFERENCES workspace(id),
  slug TEXT NOT NULL, previous_slugs TEXT NOT NULL DEFAULT '[]',
  name TEXT NOT NULL, summary TEXT, status TEXT NOT NULL DEFAULT 'active',
  UNIQUE (workspace_id, slug));
CREATE TABLE topic_alias (
  workspace_id INTEGER NOT NULL REFERENCES workspace(id),
  topic_id INTEGER NOT NULL REFERENCES topic(id),
  alias TEXT NOT NULL,                        -- stored NFC, lowercased
  PRIMARY KEY (workspace_id, alias));

CREATE TABLE seq_counter (scope TEXT PRIMARY KEY, next INTEGER NOT NULL);
  -- 'task:<workspace_id>'; task-comment high-water marks come from retained rows (§17)

CREATE TABLE task (
  id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
  workspace_id INTEGER NOT NULL REFERENCES workspace(id),
  seq INTEGER NOT NULL,                       -- AC-<seq>
  title TEXT NOT NULL,
  type TEXT NOT NULL DEFAULT 'feature',       -- feature | bug | chore | spike | question
  status TEXT NOT NULL,                       -- proposed | todo | doing | review | blocked | done | dropped
  priority INTEGER NOT NULL DEFAULT 2,
  description_md TEXT NOT NULL DEFAULT '',
  plan_md TEXT NOT NULL DEFAULT '',           -- current plan; checklist items '- [ ]' are steps
  plan_rev INTEGER NOT NULL DEFAULT 0,
  acceptance_md TEXT NOT NULL DEFAULT '',
  result_md TEXT,
  parent_id INTEGER REFERENCES task(id),
  app_id INTEGER REFERENCES app(id),          -- primary app, used for location and brief
  claimed_by TEXT, claimed_at TEXT,           -- actor incl. session; heartbeat on each write by the claimer
  branch TEXT, worktree TEXT,                 -- set on start
  done_sha TEXT, done_branch TEXT, done_dirty INTEGER,
  archive_override TEXT,                      -- NULL (auto) | 'archived' | 'kept'
  follow_up_at TEXT,                          -- blocked: the UTC day to chase the blocker (D35)
  external_ref TEXT,                       -- promoted, e.g. "ado:4711" or "gh:owner/repo#12"; read-only in silta
  created_by TEXT NOT NULL,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, closed_at TEXT,
  UNIQUE (workspace_id, seq)
);
-- "archived" is computed: archive_override = 'archived'
--   OR (archive_override IS NULL AND status IN ('done','dropped') AND closed_at < now - archive_after_days)

CREATE TABLE task_plan_rev (id INTEGER PRIMARY KEY, task_id INTEGER NOT NULL REFERENCES task(id),
  rev INTEGER NOT NULL, body_md TEXT NOT NULL, actor TEXT NOT NULL, created_at TEXT NOT NULL,
  UNIQUE (task_id, rev));

CREATE TABLE task_event (id INTEGER PRIMARY KEY, task_id INTEGER NOT NULL REFERENCES task(id),
  actor TEXT NOT NULL, kind TEXT NOT NULL,    -- created | status | field | plan | step | claim | link | promote | block | unblock | secret_redacted
  body TEXT, created_at TEXT NOT NULL);       -- a status event's body is always the new status (D40)
  -- claim: NULL on start; 'released <comment-ref>' for a handoff release.
  -- A comment's secret_redacted event body is that comment's ref, never its content.
CREATE INDEX task_event_task ON task_event(task_id, kind);

CREATE TABLE comment (
  id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
  task_id INTEGER REFERENCES task(id),
  doc_rev_id INTEGER REFERENCES doc_rev(id),
  seq INTEGER NOT NULL,                       -- per target
  thread_id INTEGER REFERENCES comment(id),   -- NULL for roots
  kind TEXT NOT NULL,                         -- comment | question | answer | decision | handoff | review
  verdict TEXT,                               -- review: approve | changes | comment
  subject TEXT,                               -- review: 'diff:<base>..<head>' | 'plan@3' | 'doc@4'
  anchor TEXT, anchor_sha TEXT, anchor_snippet TEXT,  -- (M2) quoted lines kept for orphaned anchors
  body_md TEXT NOT NULL,
  mentions TEXT NOT NULL DEFAULT '[]',        -- JSON array of actors, parsed from @…
  accepted INTEGER NOT NULL DEFAULT 0,        -- answer accepted by the asker
  actor TEXT NOT NULL,
  resolved_at TEXT, resolved_by TEXT, deleted_at TEXT,
  created_at TEXT NOT NULL,
  CHECK ((task_id IS NULL) <> (doc_rev_id IS NULL))
);
CREATE UNIQUE INDEX comment_task_seq ON comment(task_id, seq) WHERE task_id IS NOT NULL;
CREATE UNIQUE INDEX comment_doc_seq  ON comment(doc_rev_id, seq) WHERE doc_rev_id IS NOT NULL;

CREATE TABLE review_request (                 -- (M2)
  id INTEGER PRIMARY KEY, task_id INTEGER NOT NULL REFERENCES task(id),
  reviewer TEXT NOT NULL,                     -- 'agent:codex' (any session) | 'human:valtteri'
  subject TEXT NOT NULL, requested_by TEXT NOT NULL, created_at TEXT NOT NULL,
  taken_by TEXT, taken_at TEXT,               -- lease, TTL 30 min
  done_at TEXT);

CREATE TABLE doc (id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
  workspace_id INTEGER NOT NULL REFERENCES workspace(id),
  slug TEXT NOT NULL, previous_slugs TEXT NOT NULL DEFAULT '[]',
  title TEXT NOT NULL, kind TEXT NOT NULL, owner TEXT,
  current_rev INTEGER, verified_at TEXT, archived INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, UNIQUE (workspace_id, slug));
CREATE TABLE doc_rev (id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
  doc_id INTEGER NOT NULL REFERENCES doc(id), rev INTEGER NOT NULL,
  base_rev INTEGER,                           -- the revision this proposal was written against
  body_md TEXT NOT NULL,
  state TEXT NOT NULL,                        -- proposed | accepted | rejected | superseded
  actor TEXT NOT NULL, message TEXT, created_at TEXT NOT NULL, UNIQUE (doc_id, rev));

-- Typed links. Owned targets by id; external targets as strings.
CREATE TABLE link (
  id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
  workspace_id INTEGER NOT NULL REFERENCES workspace(id),
  from_kind TEXT NOT NULL, from_id INTEGER NOT NULL,          -- task | doc | comment
  rel TEXT NOT NULL,                                          -- about | source | blocked_by | relates | cites
  to_kind TEXT NOT NULL,                                      -- task | task_plan_rev | comment | doc | doc_rev | app | topic | note | code | url | ext
  to_id INTEGER, to_ext TEXT,
  anchor TEXT,                                -- owned target line anchor, separate from identity
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  CHECK ((to_id IS NULL) <> (to_ext IS NULL)));
CREATE UNIQUE INDEX link_unique ON link(workspace_id, from_kind, from_id, rel, to_kind, IFNULL(to_id, to_ext), IFNULL(anchor, ''));

CREATE TABLE alias_decision (                 -- human confirm/reject of index-suggested topic matches
  workspace_id INTEGER NOT NULL REFERENCES workspace(id),
  note_ref TEXT NOT NULL, topic_id INTEGER NOT NULL REFERENCES topic(id),
  decision TEXT NOT NULL,                     -- accepted | rejected
  actor TEXT NOT NULL, created_at TEXT NOT NULL,
  PRIMARY KEY (workspace_id, note_ref, topic_id));

CREATE TABLE source (id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
  workspace_id INTEGER NOT NULL REFERENCES workspace(id),
  kind TEXT NOT NULL,                         -- notes | repo-docs
  root TEXT NOT NULL, include TEXT NOT NULL, exclude TEXT NOT NULL DEFAULT '[]',
  repo_id INTEGER REFERENCES repo(id));

CREATE TABLE worktree_override (path TEXT PRIMARY KEY, -- canonical worktree toplevel
  app_id INTEGER NOT NULL REFERENCES app(id),
  set_by TEXT NOT NULL);                      -- human-only

CREATE TABLE approval (id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
  workspace TEXT,                             -- slug, no foreign key: survives restore
  actor TEXT NOT NULL,
  command TEXT NOT NULL,                      -- path, refs and passed flag names; no bodies; creating commands end with ' -> <created refs>'
  words TEXT NOT NULL, created_at TEXT NOT NULL);  -- an agent's --approved run (D38)

CREATE TABLE change_log (seq INTEGER PRIMARY KEY, kind TEXT NOT NULL, row_id INTEGER NOT NULL);
  -- appended in the same transaction as each owned write; the indexer catches up from it
```

Schema migrations use GRDB's `DatabaseMigrator`; there's no separate version table.

### `index.db` (derived, can be deleted)

- `index_meta`: the schema version (a mismatch triggers a rebuild),
  `last_change_seq`, and the lease row (`lease_owner`, `lease_until`).
- `indexed_file`: source, path, sha256, title, date, frontmatter, sections.
- `suggested_topic`: alias matches from indexing. Rows with an `alias_decision` are
  applied or hidden accordingly.
- `search` (FTS5, `unicode61 remove_diacritics 0`) and `search_tri` (FTS5 `trigram`).
- `code_ref_check`, `where_cache`.

Owned line links keep `to_id` and a separate `anchor`. Current `plan#L…` links target
that task; historical `plan@n#L…` links target its `task_plan_rev` row. Revisions and
comments also use owned IDs. Different anchors on the same target are distinct links.

## 7. Location resolution (`silta where`)

Input: the cwd (or `--path`). The path is canonicalised first: realpath, `/private`
symlinks resolved, case-folded on case-insensitive volumes.

1. **Repo.** Run `git rev-parse --path-format=absolute --git-common-dir` and match
   against `repo_path`. No match → `unregistered` (exit 2; `brief --hook` prints
   nothing).
2. **Candidates** are the repo's apps.
   - If the cwd is under an app's `subpath`, only the subpath apps are candidates.
   - Otherwise subpath apps are dropped, which leaves one primary app per ref.
   - Then apply the rules below in order. The first rule that picks a single
     candidate wins.
3. **Single candidate** → done.
4. **Human override** for the canonical worktree toplevel (`worktree_override`),
   only when its app remains among the filtered candidates.
5. **Task link.** A task claimed by this session, or the task whose `branch` equals
   the current branch, gives its `app_id`.
6. **Exact ref.** The current branch equals an app's `ref` or `prod_ref`, ignoring
   `origin/`.
7. **Upstream.** `git rev-parse --abbrev-ref @{upstream}` equals an app ref. Otherwise
   the branch's oldest reflog entry `branch: Created from <ref>` names an app ref.
8. **Two-sided distance.** For each candidate ref, compute `a = rev-list --count
   ref..HEAD` and `b = rev-list --count HEAD..ref`, and pick the smallest `a + b`.
   - Confidence is `high` if the best score is under half the runner-up's, otherwise
     `low`.
   - This handles promotion chains (`master` → `portal` → `api`). A branch cut from
     `master` has a small distance to `master` but a large one to `portal`, because of
     the hundreds of commits that exist only on `portal`, and the same goes for `api`.
9. **Nothing resolves** → `low`, with all candidates listed.

**Edge cases.** Each case returns a defined value, and each has a fixture (§20).

| Case | Result |
|---|---|
| Detached HEAD | Rules 4–5, then 8 against the HEAD sha. `branch: null` |
| Shallow or partial clone where `rev-list` fails | `low`, reason `shallow` |
| A candidate ref missing locally (`origin/x` not fetched) | Skipped in rules 6–8; configured candidate retained, warning `ref_missing` |
| Worktree of an unregistered repo | `unregistered` |
| Branch created from a non-app ref (e.g. `release/2024`) | `low` with candidates, never a silent guess |

**Output** (`--json`):

```json
{"workspace":"acme","repo":"platform","app":"platform-portal","branch":"feature/messages-ui",
 "head":"3f9a1c2000000000000000000000000000000000","confidence":"high","reason":"upstream","candidates":[…]}
```

- `head` is the full commit SHA, not an abbreviation. `reason` is one of
  `explicit`, `single`, `override`, `task`, `exact_ref`, `upstream`, `reflog`,
  `distance`, `non_app_ref`, `shallow` or `unresolved`.
- Ref comparisons strip only `origin/`; other remote prefixes are not normalized.
- Outside Git, `where` returns `unregistered` with carry-on guidance and harmless
  help, without suggesting a scan of the input directory. An unregistered Git
  repository instead gets a scan command for its canonical toplevel.
- Commands that need an app fail with exit 4 when confidence is `low` and no
  `--app` was given. The error lists `--app <slug>` retries.
- `brief` and `task` commands carry on with `low` and show the candidates.
- Explicit `--app <slug>` selects a filtered candidate. An app outside the filtered
  candidates is `ambiguous_location`, with candidate retries. `--task <ref>` selects
  task evidence before session claims and branch matches (§8). An explicit task
  must exist even when an earlier rule resolves the app; a valid task does not
  change the precedence of those rules.
- `where` itself succeeds at low confidence: no app is selected. Its text shows
  each candidate's slug and ref, with explicit `--app` retries. When distance ran,
  retries are ordered by increasing score, then slug for ties; unscored candidates
  follow by slug. The same order survives a cache hit. Retries keep the canonical
  inspected directory, while override receipts name the canonical worktree root.
  Candidate JSON entries are `{"app":"<slug>","ref":"<development ref>"}`,
  sorted by app slug.
- `where --set <app>` and `--unset` change the canonical worktree toplevel's
  override, also when invoked in a subdirectory. The override applies only among
  that input path's filtered candidates, so a subpath app still wins. Other linked
  worktrees have separate overrides, including worktrees nested inside the parent.
  Set accepts any configured app in the matched repository, so a worktree-root
  approval retry can store a subpath app. The accompanying location report still
  resolves the inspected path's filtered candidates. Both accept `--path <directory>`.
- Effective override changes are human-only and record an approval atomically.
  Repeating a set, or unsetting an absent override, needs no approval and writes no
  rows. Supplied `--approved` then warns `approval_unused`. Receipts distinguish
  `Override set to <app>` or `Override removed` from `No override` or
  `Override already <app>`. Read-proven
  no-ops bypass truth writes. If a concurrent change makes a planned mutation
  redundant after its write opens, no decision, approval or change-log row changes;
  normal daily-backup bookkeeping may still run.
  Approval retries and recorded approval commands preserve the workspace and name
  the canonical worktree root, which is the scope of the operation.
- A shallow clone can resolve through earlier rules. Distance inference without
  complete history returns `low`, reason `shallow`, and is never cached.
- A named non-app reflog origin returns `low`, reason `non_app_ref`.
- Missing development refs produce `ref_missing`. Configured candidates remain
  available for explicit selection, single-candidate, override and task rules;
  missing refs are skipped only in the ref-dependent rules (6–8). Distance stays
  low when missing competitors prevent the strict runner-up comparison.
- The cache lives in `index.db`, keyed on (path, HEAD sha, hash of candidate ref
  shas). It is written only if the lock is free; it never blocks.
- Location Git requests set `GIT_NO_LAZY_FETCH=1` to suppress fetching missing
  promised objects. This is best effort: older Git versions may ignore the
  variable. Location does not run an explicit fetch.

## 8. Tasks

**Statuses:** `proposed → todo → doing → review → done`, plus `blocked` and `dropped`.

**Who creates what, as what:**

| Created by | How | Status |
|---|---|---|
| Human | `task add` | `todo` |
| Agent, work the human asked for in chat | `task add --start` | `doing`, claimed by this session |
| Agent, subtask of a task it has claimed | `task add --parent AC-3` or `from-plan --split` | `todo` |
| Agent, an unsolicited idea for later | `task add` | `proposed`; listed in the human's inbox for 14 days; `task triage` accepts or drops it. With the setting `proposals: ask` (D39), human-only instead: the agent asks in chat first |
| Agent, with the human's go-ahead (D39) | a write that would be `proposed`, with `--approved` | `todo`, under either setting |

Under `proposals: ask`, every agent write that would create a `proposed` task is
human-only: `task add`, `--parent` on a task the agent doesn't claim, and
`from-plan`, with or without `--split`. `human_only` names the setting, and `next`
uses `-F <file>` when the body came from stdin. A human's request in chat for the
write is its go-ahead. Proposals that already exist when the setting changes stay in
triage, or leave the inbox after 14 days as usual.

`--parent` needs an open (not `done` or `dropped`), unpromoted parent. `from-plan
--split` children take the root's status, decided once per import: `todo` under a
`todo` or `doing` root, `proposed` under a `proposed` one; `--dry-run` shows the same
(D40). A title is one line without control characters.
A dry run validates or records no approval words and remains ungated. With
`--approved`, would-be proposals preview `todo` and warn `approval_unused`.
Under `proposals: ask` without approval, they also preview `todo`, with a warning
that the real run needs the human's go-ahead in chat and creates `todo`. Split
children preview the same status; refusals and consent warnings name the task count.

`task ls` always shows the caller's own `proposed` tasks, so an agent can see what it
just created; `--status proposed` lists everyone's (it implies `--proposed`). Promoted
tasks are left out unless `--promoted` is given. `task ls` sorts by priority (1–3, 1
first, default 2; set with `task add --priority` or in triage), then oldest first.

**Working the backlog (D37).** When the human says "work the backlog" without naming
a task, the agent runs `silta task ls --status todo [--app <app>]` and starts the first
task. It skips subtasks whose parent another session claims, and on `claimed` it takes
the next one. It finishes each task with `done` before starting the next, and keeps
going until the list is empty or the human stops it.

**Triage (D37, D38)** is human-only and batched, so one answer is one command:
`task triage --accept <ref>… --drop <ref>… [--priority n] [-m <why>]`.
- It is all or nothing: a bad ref fails the whole call, and the error names it.
- `--priority` sets the accepted tasks' priority; without it they keep their own. `-m`
  is the result stored on the dropped ones, "Dropped in triage." by default.
- A proposal nobody triaged leaves the inbox 14 days after `created_at`, which means
  "not now". It stays in `task ls --status proposed` and in `inbox --all`, and no write
  happens.

**Claims:**
- `task start AC-12` claims the task for the actor *including session*. It sets
  `doing`, `claimed_by`, `claimed_at`, `branch` and `worktree` in one
  `BEGIN IMMEDIATE` compare-and-set; `branch` and `worktree` only when the task has an
  app.
- Another session's claim with `claimed_at` under 2 h old → exit 6 `claimed`, naming
  the holder and the age. For an agent, `next` is `silta task ls --status todo`, to
  pick other work, and the message names the exact `silta --ws <workspace> task start
  <ref> --steal --approved "<the human's words>"` to ask the human about, naming the
  task's workspace so it still targets it from another selection. A human gets `next:
  silta task start <ref> --steal` (`next_by: agent`), which §16's rewrite qualifies.
- Any write by the claimer to the task refreshes `claimed_at`. A `handoff` comment
  and `task submit` release the claim (D41).
- `--steal` is human-only when it overrides another session's fresh claim. Otherwise
  it changes nothing and needs no approval (D40).
- Start accepts `todo`, `doing` and `review`, and never reopens terminal tasks.
  Proposals need human triage before they can start or complete. For an agent the
  refusal's `next` is `silta task triage --accept <ref> --approved "<the human's
  words>"`, with `next_by: human`; a human gets `silta task triage --accept <ref>`,
  with `next_by: agent`, since they run it themselves. An agent may
  drop its own proposal with a result; it cannot drop another actor's proposal.
- Task mutations refuse another actor's fresh claim. Discussion posts are exempt:
  another actor's discussion never refreshes the holder's heartbeat or task write
  timestamp. A foreign holder's handoff is refused, with ordinary discussion as the
  alternative. An unclaimed handoff records context and warns that no claim was
  released. An owner's handoff releases only its own claim, preserving task status.
  An expired claim can be reclaimed with
  `start`; each claim compares the complete actor, including session.

**Plans:**
- `task plan AC-12 -F -` stores a new plan revision; a blank body is `invalid`.
  `--if-rev 3` refuses with exit 6 if someone else changed the plan in between. It
  prints one line, `AC-12 plan revision 3 (4 steps)`, counting the checkboxes.
- `task plan AC-12 --step 3 --done|--undo` ticks a checklist item in place. It logs a
  `step` event and does **not** create a new revision, so ticking steps is cheap. A
  tick adds no text, so the secret guard leaves the plan as stored and
  `--allow-secret` is `invalid` with `--step`. It prints one line, `AC-12 step 3 done:
  Patch handler (3/4)` (or `undone`), with the checked count; neither form echoes the
  plan.
- `--step N` counts the plan's top-level checkboxes (`- [ ] …`, `1. [x] …`), from 1;
  `task show` numbers them, e.g. `3. [ ] Patch handler`; a label may hold any
  character but a newline. On a plan with no checkboxes `--step` is `invalid`, says so
  and how to write them, with `next` `silta task plan AC-12 -F -`. A step past the
  last is `invalid` and names the count (`AC-12's plan has 3 checkboxes`), with `next`
  `silta task show AC-12`.
- The secret guard checks only the fields a write changes, each changed field whole
  (not its changed lines); an unchanged field is never rescanned.
- `task from-plan [<file>|-]`:
  - Parses a markdown plan: the title comes from the first heading, the description
    from the text before the first list, and the top-level list items or `##`
    headings become steps.
  - By default the steps become the plan's checklist. `--split` makes them subtasks
    instead (at most 10, or it refuses).
  - `--dry-run` prints what would be created.
  - **It never deletes by default.** `--delete` deletes only an *untracked* file
    inside the current worktree, and only after the transaction commits. Files under
    harness directories such as `~/.claude/plans` are never deleted.
- Repos with their own plans board (sales) keep it; the task links to it
  with `cites`.

**Results and commit link:**
- `task done|drop AC-12 -m|-F` stores `result_md`: what was done, the key decisions,
  and what's left. Agents must give one; humans may skip it. The template is in
  `silta guide`.
- Done also records `done_sha` and `done_branch` from the task's `worktree`, or else
  from the cwd if it's the same repo. A sha from another repo is refused. A dirty
  worktree records `done_dirty = 1` and warns. `--sha` overrides the commit;
  `--no-sha` is for non-code tasks.

**Non-code work** is an ordinary task: releases, store submissions, contracts,
waiting on someone. A task with no app records no branch or worktree on `start`, so
`done` records no commit for it; `--no-sha` covers the rest.

**Blockers and dependencies (D35).** A task can wait on another task, on an outside
party (a customer, an app store), or on something at a URL such as a tracker item.
- `task block AC-12 [--on <ref>…] [--follow-up <date>|<n>d] -m <why>`:
  - Allowed from `todo`, `doing` and `review`. It sets `blocked` and releases the
    claim.
  - Each `--on` records a `blocked_by` link to an open task in the same workspace
    (not itself, and not `done` or `dropped`), an external party (`ext:app-store`) or
    a `url:`. Only `block` writes `blocked_by`; `task link` refuses it.
  - `-m` says what is being waited for. For a party, that is the ask itself, since
    Silta sends nothing: the output says "Silta sends nothing; ask ext:acme: …" for
    each party this call names with `--on`, and not for parties from earlier blocks.
  - `--follow-up` is the day to look again, as a UTC day (not the local one), and
    never in the past; it defaults to 7 days. So nothing stays blocked unnoticed,
    cycles included.
  - On a task that is already blocked, `block` adds blockers and replaces the
    follow-up day and the reason, which is how a chase is snoozed.
  - Each `block` writes a `block` event whose body is JSON:
    `{"on":[…],"follow_up":"<day>","why":"<-m>"}`, where `on` holds task uids and
    `ext:`/`url:` strings. `ls` and `show` print the latest `why`; `show --timeline`
    prints task refs in place of the uids.
  - First use of a party warns `new_party`, listing the parties named in earlier
    `block` events, so `ext:acme` and `ext:acme-co` don't split by accident.
- **Examples:**

  ```
  silta task block AC-12 --on ext:acme -m "Acme's decision: which push categories?"
  silta task block AC-20 --on ext:app-store --follow-up 3d -m "Build 2.3 (412) in review"
  silta task block AC-14 --on AC-12 -m "Needs the push categories first"
  ```
- **Ready to unblock** means every blocker is a task and every one is `done`. A
  dropped blocker task means the prerequisite won't happen ("blocker dropped:
  re-plan"). A party, a URL or a promoted task never closes by itself, so a block
  with any of those, or with no `--on`, comes back only on its follow-up day.
- **Silta never unblocks by itself** (reads never write). The human's inbox lists
  blocked tasks that are ready, have a dropped blocker, or have reached their
  follow-up day.
- `task unblock AC-12 [-m]` always returns the task to `todo`; `task start` claims it
  again. A blocked task can also go straight to `done` (the App Store approved it)
  or `drop`. `unblock`, `done` and `drop` clear the follow-up day and delete the
  `blocked_by` links; the `block` events keep them, so exports keep the history.
- **Unblocking a block that isn't ready needs the human's go-ahead (D40).** An agent's
  `unblock` of a batch with any task that isn't ready is `human_only` unless it
  carries `--approved`; the refusal names each task that isn't ready and only its
  unmet blockers, tasks separated by "; " (`AC-12 waits on ext:acme (blocker AC-6
  dropped); AC-14 waits on an answer`); done blockers aren't listed. Readiness is
  decided inside the write, and one approval row covers the batch, all or nothing. A
  ready unblock needs no approval; `--approved` on it warns `approval_unused`. `done`
  and `drop` of a blocked task stay ungated: each records a result that says why.
- `task start` on a blocked task fails with exit 6 `blocked`, naming the blockers and
  their age; `--steal` doesn't bypass it. `next` is `silta task unblock AC-12` only
  when the block is ready; otherwise `silta task ls --status todo`, to pick other
  work.
- `task ls` and `task show` say what a blocked task waits on and for how long, e.g.
  "waiting on ext:acme for 6 d: Acme's decision…". `task ls --on ext:acme` lists
  everything waiting on one party, ready to go into one email or meeting; `--on
  AC-12` lists what waits on a task.
- A promoted task is read-only in Silta, so it can't be blocked here; its tracker
  holds that state.

**Other rules:**
- **Submit for review:** `task submit AC-12` (doing → review). It takes no body; a
  `status` event's body is always the new status. It releases the claim, so whoever
  reviews and merges can finish the task with `done`; the author takes it back with
  `task start` to address review findings (D41).
- **Archive is computed (§6).** Reads never write. `task archive|keep` sets the
  override.
- **Receipts say what changed:** `AC-5 archived`, `AC-5 kept`, `AC-14 linked cites
  task:AC-2` (the target as `show` prints it), `AC-5 promoted to ado:4711; read-only
  here`, `AC-5 edited: title, plan` (or `AC-5 unchanged`). Their `--json` data stays
  the `ref` and `status` receipt.
- **External tracker:** `task promote AC-12 --ext ado:4711` (or `gh:owner/repo#12`,
  `jira:KEY-12`) is human-only; refusals on the task's state come before the human is
  asked. A promoted task becomes read-only in `silta` and status
  changes return exit 3: "tracked in ado:4711; change it there", with `next`
  `silta task ls --status todo` for the agent to pick other work. M4 adds reading the
  status back, Azure DevOps first.
  - A proposal can't be promoted until it is triaged, and a blocked task until it is
    unblocked (`conflict`, D40), so no proposal or block outlives promotion. For a
    blocked task, `next` is `silta task unblock <ref>` when the block is ready, and
    otherwise `silta task show <ref>`.
  - Rule of thumb for promoting: the work needs someone else, the client or users
    would notice it, or it's more than about half a day.
- **Branch to task:** `brief` and `where` pick "the current task" in this order:
  `--task`, a claim by this session, then the task whose `branch` matches the current
  branch.

### 8.1 Discussion and reviews

**M1: comments and threads.**

| Kind | Use | Behaviour |
|---|---|---|
| `comment` | General notes | — |
| `question` | Blocks work *beyond this session* | Listed in the inbox of the mentioned actors (default `@me`) until answered. **Ask in chat first** when the human is there. |
| `answer` | Reply to a question | The asker can `comment accept AC-12/5`, which resolves the thread |
| `decision` | A choice and its reason | Shown in `brief`; `--from note:…` cites a meeting |
| `handoff` | Where I stopped, what's next | Releases the author's own claim, preserving status. The newest one is shown first in `brief --task`. Template in `silta guide` |

- Threads: `--reply-to AC-12/3`. `comment resolve|reopen <ref>… [-m …]` takes several
  refs in one call.
- `task show` shows the newest handoff thread first and unresolved threads with
  their replies, identifying answered versus resolved questions. Roots and replies
  sort by creation time then id. Deleted content is a placeholder; an empty deleted
  thread is omitted. `--timeline` includes full discussion alongside task events.
  Text bodies are quoted line by line, including blank lines, so content cannot
  impersonate a comment header. Full-history comment headers include their timestamp.
- A post receipt adds `released` beside its existing JSON fields: true only when
  that transaction released the author's own claim, false for ordinary/context-only
  posts. Text says `handoff; claim released` on release. A resumable, unclaimed
  `doing` task shows its actual release ref and a workspace-qualified `task start`
  hint; claimed, promoted and terminal tasks never offer that hint.
- `reply_to` in JSON denotes the thread root. A reply to a reply joins that root;
  the immediate parent is not a separate edge.
- Comments are append-only: the author can soft-delete and post again. There is no
  edit history.
- A body is at most 8 000 Unicode scalar values. Longer output is summarised, and the
  full text is kept as a file path outside the repo.

**M2: reviews.**
- `task diff AC-12` prints the base, head, changed files and the exact review subject.
  The base defaults to the app ref and the head to the task's branch.
- `task review AC-12 --verdict approve|changes|comment [--subject diff|plan[@n]]
  -m|-F [--lines <file|->]`:
  - It's one command, however many line comments it carries.
  - The `--lines` file has one `<ref> <text>` per line, using `diff:`/`plan` refs
    (§5.1).
- **Anchors** store `anchor_sha` and the quoted `anchor_snippet`. On display an anchor
  is `current`, `outdated` (the content changed) or `orphaned` (the sha is
  unreachable after a rebase or force-push). The snippet is still shown when
  orphaned.
- **Review requests:**
  - `task request-review AC-12 --reviewer agent:codex|me|<person>` creates a
    `review_request`.
  - `inbox take <id>` leases it atomically for 30 min, so two Codex sessions can't
    both take it.
  - Posting the review completes the request.
- **Review gate** (workspace setting `review_gate`):
  - `none` (**default**)
  - `any`: `done` warns if the latest verdict is `changes`
  - `human`: `done` needs a human `approve`

  An unmet gate returns exit 7, and `--force` past it is human-only. On a met gate
  `--force` changes nothing and needs no approval (D40).
- **Rate limit:** per actor-session, per task, counting **commands** (a review with
  10 line comments is 1). The default is 30 per 10 min. Over the limit → exit 8 with
  `retry_after_s`, and the hint "summarise the rest in one comment".

**Inbox** (`silta inbox [--for <actor>|me] [--all]`) is a query over current state, so
there are no read markers. Without `--for` it is the caller's own inbox. `me` is the
human, `human:<USER>` (§11), as in `@me` mentions. An agent asked "what needs me?"
runs `silta inbox --for me` and relays it in one message (D37, D38). So the human's
inbox is short and grouped:
- **Order:**
  1. blocked tasks that are ready to unblock or need re-planning, one item each;
  2. blocked tasks past their follow-up day, one item per party or URL listing its
     tasks and asks, the longest overdue first (a task waiting on two parties shows
     under both);
  3. questions to the human, oldest first;
  4. review requests (M2);
  5. proposals from the last 14 days, newest first;
  6. promoted tasks needing attention.
- At most 12 items, then `N more: silta inbox --for me --all`. `--all` shows every item,
  including older proposals.
- Every item shows its refs and the commands that answer it, e.g.
  `silta task triage --accept AC-4 --drop AC-7 --approved "<the human's words>"`. The
  agent asks first, and maps "the rest" only to items it showed.

It lists:
- unanswered questions mentioning the actor
- open review requests for the actor's tool (M2)
- for humans, also: `proposed` tasks, pending doc proposals (M2), and promoted tasks
  needing attention
- for humans, also: blocked tasks that are ready to unblock, have a dropped blocker
  ("re-plan"), or have reached their follow-up day, each with its `next` (D35)
- for agent sessions: new comments by others on tasks they claim, since their last
  write there

## 9. Docs (M2)

- Bodies are markdown with `[[ref]]` links (§5.1), parsed into `link` rows when a
  revision is accepted.
- **Humans:** `silta doc edit <slug> [-F <file>]` saves an accepted revision, from
  `$EDITOR` or a file. It is human-only (§11): without `--approved`, an agent gets
  `human_only`, whose `next` also offers `doc propose`. With `agent_doc_writes:
  direct`, `doc edit` needs no approval.
- **Agents:** `doc propose <slug> -F - -m "why" [--base <rev>]`.
- **Accept:** `silta doc accept <slug> <rev>` refuses (exit 6) if `base_rev` isn't the
  current revision; `--rebase` opens a 3-way merge in `$EDITOR`, or takes the merged
  text with `-F <file>`. Reject with `doc reject`.
- Setting `agent_doc_writes: propose | direct`.
- `silta doc verify <slug>` stamps `verified_at`. `doc archive` hides a doc.
- Writing rule (shown in `doc new` templates): point at code, don't copy it.
- Renaming a slug adds the old one to `previous_slugs`, so old `[[doc:…]]` links keep
  resolving and `verify` suggests updating them.

## 10. Code access (read-only)

```
silta code show <app>[@<ref>] <path> [--prod] [--lines 40-120]
silta code grep <app>[@<ref>] <pattern> [-- <pathspec>]
silta code log  <app>[@<ref>] [<path>] [-n 20]
silta code ls   <app>[@<ref>] [<dir>]
```

- These run against the app's ref, its `prod_ref`, or any ref given with `@` (e.g. a
  backend feature branch). The working tree is never touched.
- **Git runner:** absolute path to `git` (2.40 or later, for `--attr-source`; the
  pinned toolchain ships 2.54), resolved once and checked by `doctor`; environment
  `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`, `LC_ALL=C`. Inherited `GIT_*`
  overrides are removed. Code reads retain normal Git lazy fetching for promised
  objects in partial clones; only location requests suppress it (§7). A 10 s
  timeout per call (fetch 60 s).
- Output carries the resolved sha and depends only on that commit: attributes
  (`.gitattributes`) come from the commit too, never from the clone's working tree.
- JSON data is `{app, ref, sha, output}`; `output` is UTF-8 text, with bytes that
  aren't UTF-8 replaced by U+FFFD. Text starts with `<app>@<ref> <sha>`, followed by
  the output. `--quiet` preserves this read output. All four commands accept `--prod`
  and `--fetch`; `@ref` and `--prod` together are invalid. A missing `prod_ref`
  points to workspace configuration.
- Paths are relative to the app's subpath, or the repo root when none is set. The
  subpath and the `show`, `log` and `ls` paths are literal. `grep` skips binary files
  and accepts one relative wildcard pathspec after `--`, but no leading-colon Git
  magic. Absolute paths and `..` components are invalid. Grep output uses
  app-relative `path:line:text`; `ls` lists names relative to the requested
  directory, with a trailing `/` on directories. No matches in grep or log are an
  empty success. Missing show/ls paths are `not_found`, and so are `show` on a
  directory and `ls` on a file, whose `next` is the matching command. A configured
  subpath missing at the commit is `not_found` and names the subpath.
- Names containing control characters, quotes or backslashes are double-quoted
  with backslash escapes. Other names, including Unicode, display literally.
- `grep` patterns are extended regular expressions (`git grep -E`); an invalid one
  is `invalid`. A ref git can't find or rejects (e.g. `main@{999}`) is `not_found`.
  When `origin/<ref>` resolves, its `next` repeats the read with
  `<app>@origin/<ref>`; otherwise it suggests a fetch. Broken clones and missing
  objects are `env`, rather than a missing ref or path.
- `--lines N` or `--lines A-B` selects positive inclusive lines, truncating at EOF;
  a range past the end adds a `lines_past_eof` warning that gives the file's line
  count. `log -n` is positive and defaults to 20; each line is
  `<full sha> <subject>`. Color, decoration, external diffs and text conversion are
  disabled for code reads.
- Output is bounded: `show` without `--lines` prints at most 400 lines, and `grep`
  at most 200 matching lines. A cut adds an `output_truncated` warning that says how
  much was cut and how to narrow the read (`--lines A-B` for show; a pathspec or a
  narrower pattern for grep).
- A git call over its 10 s timeout is `env` with `next_by: agent`: narrow the read
  (a path, pathspec, pattern or `--lines`) and retry.
- When the repo hasn't been fetched for 24 h, output warns (`ref_stale`): "fetched N h
  ago; run `silta --ws <ws> repo fetch platform` (needs network)". A full commit SHA
  given as `@ref` never warns, since a commit can't move. `--fetch` fetches first.
  Inside a sandbox without network the fetch fails fast with exit 9, never a
  credential prompt. The error names the repo, and its `next` (`next_by: agent`)
  repeats the read without `--fetch`, which reads the cached ref.
- A clone with no recorded fetch warns that it has never been fetched, with the
  same fetch hint. Reads never update the timestamp; a successful `--fetch` does.

## 11. Agent integration

### Actors and sessions

| Condition (first match) | Actor |
|---|---|
| `SILTA_ACTOR` is set | `human:<name>` (only when stdin is a TTY; otherwise ignored, with an `actor_override_ignored` warning when stdout is a TTY), `agent:<tool>:<session>`, or `agent:<tool>` with the resolved session appended |
| `CLAUDECODE=1` | `agent:claude:<session>` |
| `CODEX_THREAD_ID` is present | `agent:codex:<session>` |
| `OPENCODE_*` marker (provisional; unverified), or set by the eval runner | `agent:opencode:<session>` |
| stdin or stdout isn't a TTY | `agent:unknown:<session>` |
| Otherwise | `human:<USER>`, or `human:unknown` when unset |

- **Format (D33):** a name or session is 1 to 64 letters, digits, `.`, `_` or `-`,
  starting and ending with a letter or digit; a tool is lowercase. A malformed
  `SILTA_ACTOR` or `SILTA_SESSION` is `env` (exit 9); an empty one counts as unset. A
  `USER` that doesn't fit becomes `human:unknown`.
- **Session:** `SILTA_SESSION` if set and non-empty. The Claude SessionStart hook exports it through
  the hook's environment file (`CLAUDE_ENV_FILE`, to verify). Otherwise it's the
  first six lowercase hexadecimal characters of SHA-256 over the UTF-8 worktree
  root (`git rev-parse --show-toplevel`), or the current directory outside git or
  when git fails: attribution never fails a command over git. A git failure (anything
  but git's own "not a git repository") adds a `session_fallback` warning.
  Nested directories share a session; separate worktrees do not. A complete explicit
  actor bypasses session resolution, including `SILTA_SESSION`.
- **Codex marker evidence:** `CODEX_THREAD_ID` was present in a Codex desktop
  command environment on 2026-11-02; its value was not recorded. OpenCode remains
  unverified; callers can use the explicit actor and session overrides.
- **Human-only commands** need the human's go-ahead (D38): `promote`, `task edit`,
  `doc edit|accept|reject`, effective `where --set|--unset` changes (§7), `task triage`, `--steal` over another
  session's fresh claim, `--force` past an unmet review gate, `--allow-secret`,
  `ws edit`, and an agent's `task unblock` of a block that isn't ready (D40); and, with
  `proposals: ask` (D39), any agent write that would create a `proposed` task (§8).
  - A `human:*` actor (a TTY, or the app) runs them directly; `--approved` from a
    human is ignored.
  - An agent runs them with `--approved "<the human's words>"`: what the human wrote
    in this chat in reply to a message where the agent named this command. A task
    prompt, an earlier instruction or the agent's own text never counts. One answer
    covers every command named in the message it answers, and nothing else.
  - The words are 1–300 Unicode scalars after trimming and secret-guarded like any agent text. Words in
    angle brackets, or containing a printed placeholder such as `<the human's words>`
    anywhere, are `invalid`.
  - The approval is stored as an `approval` row in the same write: the actor, the
    command with its refs and the flag names passed (no bodies; a body or file flag
    appears as `-m <text>` or `-F <file>`, in `ws edit` too), and the words. A
    command that creates tasks ends with ` -> <created refs>` (D40). So every approval
    can be read back, exported, counted and tied to what it changed.
  - Without `--approved`, an agent gets `human_only` (exit 3). The message says the
    command needs the human's go-ahead; `next` is the same command with
    `--approved "<the human's words>"`.
  - `--approved` on a command that doesn't need it warns `approval_unused` and stores
    nothing. A `--dry-run` records nothing, so it needs no approval, `--allow-secret`
    included, and its `--approved` warns `approval_unused`, saying a dry run records
    nothing. The exception (D39): on an agent write that would create a `proposed`
    task, `--approved` is used under either setting and creates `todo` (§8).
  - `task edit` on a task the agent itself claims needs no approval. `task edit
    --print` prints the current document and is a read. An edit that changes nothing
    stores no approval, so `--approved` warns `approval_unused`. An agent's edit can't
    blank a stored Result or Plan (`invalid`, naming the field); a human's can.
- This is a guard against accidents, not security: an agent could invent a quote. The
  `refusals` and `forbidden` evals check that agents never do.

### `silta agents install`

Writes idempotent marker blocks, after showing a diff and asking first.

| Target | Content |
|---|---|
| `~/.claude/skills/silta/SKILL.md` | The skill (outline below). OpenCode reads it too unless it's disabled. |
| `~/.claude/CLAUDE.md` block | 5 generic lines: "If `silta where` resolves this repo: …; details: `silta guide`." |
| Claude Code **SessionStart hook** | `silta brief --hook`: short, no indexing, 1.5 s timeout, silent if unregistered. It also exports `SILTA_SESSION`. |
| Claude Code **Stop hook** (optional, to verify) | `silta session check`: if this session holds a claim with writes since its last handoff, ask the agent to leave a handoff before stopping |
| `~/.codex/AGENTS.md` block | The same 5 lines |
| `~/.codex/config.toml` | Adds `~/.silta` to the sandbox's writable roots (key name to verify), so Codex can write |
| Permissions (optional) | Deny tracker writes, e.g. `Bash(az boards work-item create*)`, `Bash(gh issue create*)` |

### `silta guide`

The full agent manual, printed by the binary and versioned with it, so Codex,
OpenCode and others get the same text as the skill. `silta guide <topic>` prints one
section. The text is the same in every workspace: a setting that changes the rules
gets one conditional sentence, and `brief` names the workspace's non-default
settings (D39). It covers:
- **When to use silta.** Cross-repo work, another app or backend, branch-as-app repos,
  anything you'd write a PLAN.md for, handoffs, review requests, meeting decisions.
  Not for trivial single-repo edits.
- **Session start.** If the hook already printed the brief, don't run it again. Once a
  task is chosen, run `silta brief --task AC-n`.
- **Recipes**, copy-paste ready:
  - `code grep/show` for other apps
  - `task add --start`
  - `task plan` with a quoted heredoc (`<<'EOF'`)
  - `--step N --done`
  - which to use: `task plan`, `from-plan` or `task add`
  - the `done` result template: what was done, decisions, what's left
- **Working for the human (D37, D38).** The human talks to you; you run `silta`.
  - Decide and record: make the choice, add a `decision` comment and carry on, unless
    it is one of these. Ask about: changing the scope; a new dependency; a public
    API, schema or migration; anything another app or the customer sees; deleting
    what you didn't create; anything irreversible; money. If `brief` shows
    `ask_about: short` (D39), ask only about the last four.
  - When you need the human, put everything in one message: approvals, proposals to
    triage, questions. Never drip them one at a time.
  - Human-only commands: name the exact commands in your message, and after the human
    says yes, run them with `--approved "<their words>"`. Their answer covers the
    commands you named, and nothing else. Never write the words yourself.
  - When no answer can come (the human is away, or the harness runs without a human):
    don't wait. Leave a `question` for `@me` that lists the pending commands, write a
    handoff, and pick other work.
  - Proposals: usually none; never more than two per session, and only what you'd bet
    the human wants. `task add --start` is only for work the human asked for. If
    the human asked you to add a task for later, pass their words as `--approved`,
    so it becomes `todo` without triage (D39).
  - If `brief` shows `proposals: ask` (D39): don't propose. Name each idea and its
    `silta task add` command in your message, and add the ones the human wants with
    `--approved`. With no human present, list ideas under "what's left" in the
    handoff or the `done` result, never in a question, a TODO comment or a file.
  - "What needs me?" means `silta inbox --for me`, relayed as one short message with
    the choices to make.
  - "Work the backlog": see §8, Working the backlog.
- **Questions:** ask in chat; record in silta only if blocked beyond this session.
- **Blocked:** a question to the human doesn't block the task. If the human can
  answer, ask in chat, even about the customer. If only
  someone outside can (`ext:`) or another task must land first, keep doing what you
  can; block only when nothing useful is left. Silta sends nothing, so tell the human
  exactly what to ask whom. Then write a handoff and pick other work. Never unblock
  while a blocker is open unless the human says so, and never write "waiting for…"
  into repo files or plans.
- **Handoff:** always before stopping. Template: state, next step, open questions,
  branch and sha.
- **Reviews (M2):** `inbox` → `inbox take` → `task diff` → one `task review` with a
  lines file → reply, then a batch `comment resolve`.
- **Refusal table:** what to do for each error code (§16). Never use `--force`,
  `--steal`, `where --set`, `promote` or `--allow-secret` on your own initiative, only
  with the human's words through `--approved`. Never create tracker items or plan
  files in repos.
- **Output:** text by default; `--json` only when parsing the result.

## 12. `silta brief`

```
silta brief [--task AC-12] [--app <slug>] [--topic <slug>…] [--budget 2500] [--short] [--hook] [--json]
```

The default budget is **2 500 tokens** (estimated as chars / 4). `--short` and
`--hook` use about 800. Sections come in this order, each trimmed to fit:

1. **Location**: workspace, app, branch, confidence (plus candidates if low), and
   the workspace's non-default settings in one fixed line, each with a short
   gloss, separated by `; `, e.g. `settings: proposals: ask (ask in chat before
   adding a task); ask_about: short (ask only about what others see, deletes,
   irreversible steps, money)`. Trimming never cuts it. `--json` always has a `settings` object, empty when all are default
   (D39).
2. **Current task** (chosen as in §8):
   1. the latest handoff
   2. unanswered questions, and what the task is blocked on and for how long, with
      the same `next` as a refused `task start`
   3. the plan with step state: completed runs collapse (e.g. `1–7 done`), open
      steps keep original numbering, and the tail is trimmed. A complete marker
      such as `(plan trimmed: 32/60; silta --ws acme task show AC-12)` names the last
      represented original step and total, including completed summaries. Zero
      means no step fits; freeform plans retain their text and use a marker without counts.
   4. (M2) review state and unresolved `changes` threads with their snippets
3. **App card**: summary, environments, a pointer to the repo's AGENTS.md.
4. **Neighbours**: edges in and out, each with a ready `silta code show …` command.
5. **Open tasks** for this app and its topics (top 8).
6. **Recently done**: the first line of each result, with `done_sha`, for the last 5.
7. **Decisions**: `decision` comments, plus decisions from meeting notes from M3.
8. **Docs** (M2): titles, plus stale flags.
9. **Glossary**: aliases of the topics shown.

Output ends with `more: silta brief --task AC-15 | silta task show AC-15 | silta guide`.

`--hook` mode never indexes, never fetches, uses `where_cache` when it's fresh, and
prints nothing on error or timeout. Brief is deterministic for the same DB and git
state; the tests check this with golden output.

An explicit `--budget` overrides the default selected by `--short` or `--hook`.
The estimate covers rendered text; JSON syntax overhead is additional. Tiny budgets
retain the compact location, current task reference, non-default settings and complete
`more:` commands even when that minimum exceeds the requested budget. Candidate details
and their complete `brief --app` retries are budgeted before the task line in both
formats. Empty candidate lists are omitted. Recovery commands and trim markers are
kept whole; a marker remains even when zero plan lines fit. The normal budget omits
the redundant `brief --task` retry; short briefs retain it.
JSON contains compact `location` metadata, `settings`, optional `current_task`, ordered
`sections` (`id` and trimmed `text`), `more` commands and a `truncated` boolean.
Absent location app and branch values encode as `null`. Settings is an open object:
unsupported keys/values retain masked raw JSON without a gloss and produce a
`setting_unsupported` warning per key. A malformed top-level settings document uses
an `_invalid` indicator. This tolerant projection does not relax write-policy validation.

Automatic current-task ties use newest claim time (session matches), otherwise newest
update time (branch matches), then highest task sequence. Only local open, unarchived
tasks in candidate apps or unbound tasks without a foreign worktree qualify, including
blocked work. `where` and brief use this same ranked selector. Its selected task app
is task evidence in location resolution, after explicit app/single-candidate/override
rules. App cards, neighbours and app backlogs follow resolved `location.app`; the task
section names its own app, including when an explicit `--app` selects a different app.
Brief masks stored task-body secrets. Blockers include their follow-up date.

The available core brief omits app/backlog and discussion/inbox sections until their
ordered additions ship; the task description joins the richer context addition.
Hook mode has a 1.5 s process deadline, including environment
assembly, fails immediately on database contention and never populates `where_cache`.
The watchdog appends a best-effort body-free timeout record, then exits without running
exit handlers. Timeout and completion have exclusive log/output ownership; completion
cancels the watchdog explicitly before output. Hook log appends are nonblocking and
skip non-regular files; filesystem stalls cannot be absolutely bounded by `O_NONBLOCK`.

## 13. Indexing and search (M3)

- **Sources:**
  - Notes: frontmatter, title, date, sections by fixed headings (`Päätökset` /
    Decisions, `Toimenpiteet` / Actions, `Avoimet kysymykset` / Open questions).
  - Repo docs (`AGENTS.md`, `CLAUDE.md`, `README.md`, `docs/**/*.md`): read at the
    app's ref with `git show`.
  - Files over 512 KB are skipped with a warning. Text is decoded as UTF-8, lossily,
    with BOM and CRLF normalised.
- **Owned content** (tasks, comments, docs) is indexed from `change_log`. Before every
  `search` and `brief`, the reader catches up on the change log, which is cheap and
  incremental. So a write is searchable at once.
- **Sources** are re-indexed when the last index is over 10 min old. The work is done
  only by the process that wins the **lease** (`BEGIN IMMEDIATE` on `index.db` with
  zero busy timeout, lease 60 s). Losers carry on with the stale index. `--hook`
  never indexes.
- **Search:** `silta search <query> [--kind …] [--app] [--topic] [--archived]`.
  - Word index first (BM25); trigram results fill in for queries of 3 or more
    characters, deduplicated by ref.
  - Diacritics are never folded (`sää` ≠ `saa`).
  - A Snowball Finnish stemmer as a custom tokenizer is a later option.
- **Recovery:** a corrupt or version-mismatched `index.db` is deleted and rebuilt
  automatically. `silta index --rebuild` does it manually.

## 14. Verify (M3)

`silta verify` reports:
- **Code refs:** refs that don't resolve on their ref, or that point to a moved path.
- **Docs:** docs never verified, or older than `stale_days`.
- **Links:** broken `[[…]]` links, and links using `previous_slugs`.
- **Repos:** repos not fetched in 7 days, and app refs that no longer exist.
- **Notes:** notes tagged with unknown app or topic slugs.
- **Done commits:**
  - a `done_sha` reachable from the app ref: `merged`
  - not reachable but the branch is gone: `unknown (squash or rebase?)`, never
    "unmerged"

`--fix-tasks` creates `proposed` tasks, deduplicated by fingerprint.

## 15. Export, backup, restore

- **Daily backup (M1):** on the first write of each day, `VACUUM INTO
  $SILTA_HOME/backups/silta-YYYY-MM-DD.db`, keeping 7. Every migration takes a backup
  first.
- **`silta export [--ws] [--to] [--commit]`** writes a byte-identical tree for the same
  DB state. YAML is written by a fixed emitter that quotes every scalar. Rows are
  keyed by `uid`; display refs are included for readability. Absolute paths are never
  written: `repo_path` is machine-local.

  ```
  <root>/<workspace>/
    manifest.json        # format version, file list + sha256, counts
    workspace.yaml       # settings, repos (slug, remote), apps, envs, services, edges, topics+aliases, sources
    tasks/AC-12.md       # frontmatter + Description / Plan / Acceptance / Result
    tasks/AC-12.jsonl    # events, plan revisions, comments, review requests
    docs/<slug>.md, docs/<slug>.jsonl
    links.jsonl, alias_decisions.jsonl, approvals.jsonl
  ```
- **`silta restore <dir> [--dry-run]`** is backup restore and machine moves, with
  **replace** semantics for one workspace.
  - It checks the manifest checksums first and refuses partial or tampered trees.
  - It validates foreign keys, seq uniqueness and prefix clashes.
  - The replace happens in one transaction, and nothing is written on failure.
  - Repo paths are re-resolved with `silta init --scan`.
  - It is **not** a merge, and not a sharing mechanism (Q3).
- **Importers** (M4): `silta import --from dex|beads|backlog-md <path>`. Imported tasks
  become `proposed`, with a `source` link to the original id.

## 16. CLI

**Conventions:**
- Every command accepts `--ws`, `--json` and `--quiet`.
- Bodies come from `-m <text>` or `-F <file|->`. With neither on a TTY, `$EDITOR`
  opens.
- Refs follow §5.1.
- Shell completion is generated by ArgumentParser, with dynamic completion of task
  ids and app slugs.
- `silta` with no arguments prints a one-line status: workspace, app, inbox count, and
  my claimed tasks.

**JSON envelope:**

```json
{"data":{…},"ok":true,"schema":1,"warnings":[{"code":"ref_stale","message":"…"}]}
{"error":{"code":"rate_limited","message":"30 comments on AC-12 in 10 min",
  "next":["silta comment AC-12 --kind comment -F -   # one summary instead"],"next_by":"agent",
  "retry_after_s":240},"ok":false,"schema":1,"warnings":[]}
```

- One line per output. Keys are sorted by Unicode code point at every level, so output
  is byte-stable.
- `warnings` is always present. `retry_after_s` is present only when set.
- Doctor's unhealthy envelope also carries the full report in `data` alongside `error`.
- `next_by` says who acts on the `next` commands: by default `human` for `human_only`
  and `env`, otherwise `agent`. An error can override its code's default. A proposal refusal
  shown to an agent is `human`, because its `next` is the human's triage. A code
  read's timeout or failed `--fetch` (§10) is `agent`, because narrowing the read or
  reading the cached ref comes first. The human works through an agent
  (D38), so for `human` the agent asks the human in chat; for `human_only` it then
  runs the printed command with `--approved "<their words>"`.
- `schema` is the envelope version. Before DF0, data shapes may narrow without a
  `schema` bump; from DF0 on they only gain fields, and any other change bumps
  `schema`.
- `task ls --json` returns one summary per task (D40): `ref`, `title`, `status`,
  `priority`, `archived`, `links` (`rel` and `target`, masked as in `show`, so a task
  can be found by its issue URL), `created_by`, `created_at`, `updated_at`, and when
  set `app`, `parent`, `claimed_by`, `claimed_at`, `external_ref`, `waiting` and
  `follow_up_at`. Bodies
  (description, plan, acceptance, result) come from `task show`, which returns the
  full detail, `parent` included.
- `task plan --json` returns `ref`, `plan_rev`, `steps` (the checkbox count) and
  `steps_done`, and for a `--step` tick also `step`, `done` and `title`. The plan
  itself comes from `task show`. Like the `ls` summary, this narrowing comes before
  DF0 (see `schema` above).

**Text errors** go to stderr: one line, the wait if there is one, then the commands, so
the output always ends with what to run:

```
error: 30 comments on AC-12 in 10 min [rate_limited]
retry after: 240s
next: silta comment AC-12 --kind comment -F -   # one summary instead
```

When `next_by` is `human`, the lines read `ask human: <cmd>` instead of `next: <cmd>`.
Several `next` commands are alternatives, best first: run one. `not_found` names what
wasn't found, and says when it was the parent or a blocker (`Parent task AC-9 not
found.`); a missing app or topic points at `silta ws show`, which lists them, and an
unknown `--ws` names the workspace.
Task recovery commands preserve a known workspace, so a noncurrent workspace remains
selected when following a hint. Early human-only refusals preserve an explicit
`--ws` without reading storage. Invalid task values, an unreadable `-F` file
included, point to the failed command's help. A busy retry names only the parsed command path, without body-bearing
arguments.

**Streams and global flags:**
- Text mode: data on stdout; errors and warnings (`warning: <message> [<code>]`) on
  stderr.
- `--json`: everything on stdout, including errors. stderr stays empty unless debug
  output was turned on explicitly.
- `--quiet` hides a write's receipt text. It still prints data: the refs a write
  created (`task add`; `task from-plan`, one per line, and a `--dry-run`'s preview),
  and the whole output of reads (`task ls`, `task show`, `task edit --print`, `ws
  ls`, `ws show`, `schema`). Warnings and errors still show; with `--json` it changes
  nothing.
- `--json` and `--quiet` may come before or after the subcommand.
- `--help` and `--version` print plain text to stdout and exit 0, even with `--json`.
- A parse error is `usage` (exit 1). Its message is one line of at most 200
  characters, and `next` is `silta <command> --help` for the command that was being
  parsed. Commands check values in `execute` and throw `invalid`; they don't use
  ArgumentParser's `validate()`.
- An unexpected error (a bug) is `env` (exit 9), with the message
  `internal error (bug): <description>`, `next_by: human` and `next: silta doctor`
  (`doctor` arrives in M1). The
  arguments are never echoed, because they can carry bodies (§18).

**Exit codes and error codes.** Every error message ends with the next command to
run.

| Exit | Codes | Agent should |
|---|---|---|
| 0 | — | — |
| 1 | `usage`, `invalid` | Read `silta <cmd> --help` and fix the call |
| 2 | `not_found`, `unregistered` | Check the ref, or carry on without silta |
| 3 | `human_only` | Stop and ask the human in chat; rerun with `--approved "<their words>"` after they say yes |
| 3 | `read_only_promoted` | Leave it to its tracker and pick other work |
| 4 | `ambiguous_location` | Retry with `--app <slug>` from the candidates |
| 5 | `busy` | Retry once after a few seconds |
| 6 | `conflict`, `claimed`, `stale_rev`, `lease_taken`, `blocked` | Re-read, then decide; don't steal, and don't unblock while blockers are open |
| 7 | `gate` | Request a review or ask the human |
| 8 | `rate_limited` | Wait for `retry_after_s`, or summarise |
| 9 | `env` (schema too new, read-only DB, git missing, no network, a bad `SILTA_*` variable) | Report the printed fix to the human |

**Commands.** The milestone that ships each one is in brackets.

```
# setup & health
silta init [--scan <dir>…]                       [M1] create DB; discover repos, worktrees, branch-apps; open YAML
silta ws edit [<ws>] [-F <file>] | ws show [<ws>] | ws ls | ws use <ws>   [M1] config as YAML (validated on save, "did you mean"); -F for agents
silta repo fetch [<repo>]                        [M1]
silta agents install [--claude] [--codex] [--hook] [--stop-hook] | uninstall   [M1]
silta doctor [--fix]                             [M1]
silta guide [<topic>] | silta help refs            [M1]

# context
silta where [--path <dir>] [--app <app>] [--task <ref>] [--set <app> | --unset]      [M1]
silta brief [...]                                [M1; docs M2; notes M3]
silta code show|grep|log|ls <app>[@ref] …        [M1]
silta search <query> [...]                       [M3]

# tasks
silta task add "title" [-m|-F] [--start] [--parent AC-3] [--app] [--topic …] [--priority n] [--from note:…]   [M1]
silta task ls [--status] [--app] [--topic] [--on <ref>] [--mine] [--proposed] [--promoted] [--archived]   [M1] summaries
silta task show AC-12 [--timeline]               [M1] default: header, plan+steps, handoff, open questions, unresolved threads
silta task edit AC-12 [-F <file> | --print]      [M1] human-only: one markdown file, in $EDITOR or from -F; --print reads it
silta task start AC-12 [--steal]                 [M1]
silta task plan AC-12 -F - [--if-rev n] | --step N --done|--undo   [M1]
silta task from-plan [<file>|-] [--parent] [--split] [--dry-run] [--delete]   [M1]
silta task submit AC-12                          [M1]
silta task unblock <ref>… [-m]                   [M1] several refs, all or nothing; an open block needs the human's go-ahead
silta task block AC-12 [--on <ref>…] [--follow-up <date>|<n>d] -m <why>   [M1] adds to an existing block
silta task done|drop AC-12 (-m|-F) [--sha|--no-sha] [--force]       [M1]
silta task triage --accept <ref>… --drop <ref>… [--priority n] [-m]   [M1] human-only, batched
silta task archive|keep|link|promote …           [M1]
silta task diff AC-12                            [M2]
silta task review AC-12 --verdict … [--subject] (-m|-F) [--lines <file|->]   [M2]
silta task request-review AC-12 --reviewer <actor>   [M2]

# discussion
silta comment <target> (-m|-F) [--kind question|answer|decision|handoff] [--reply-to <ref>] [--from note:…]   [M1]
silta comment resolve|reopen <ref>… [-m] | comment accept <ref> | comment delete <ref>   [M1]
silta inbox [--for <actor>|me] [--all] | inbox take <id>   [M1; take M2]

# docs
silta doc new|ls|show|edit|propose|accept|reject|verify|archive …   [M2]

# maintenance
silta export [--commit] | restore <dir> [--dry-run] | backup     [M1]
silta index [--rebuild] | verify [--fix-tasks]   [M3]
silta import --from dex|beads|backlog-md <path>  [M4]
silta open [AC-12]                               [M5] open Silta.app
```

## 17. Storage, concurrency, technology

### Concurrency model

Every CLI call is its own short-lived process, and several agents run at once.
- **Writes:** every write is one `BEGIN IMMEDIATE` transaction, with
  `busy_timeout = 5 s` and up to 3 retries with jitter. After that, exit 5 `busy`.
- **Sequence numbers** are allocated inside the same transaction as the row. Tasks
  use `seq_counter`. Task comments use `max(seq)+1` across all retained rows under
  `BEGIN IMMEDIATE`: the append-only table supplies its own high-water mark, including
  soft-deleted and imported/older comments without counter rows, so refs are never
  reused and no counter bootstrap state is needed.
- **Claims and leases** are compare-and-set inside `BEGIN IMMEDIATE`.
- **Read commands never change `silta.db`'s contents and never migrate.** Archiving is
  computed, and caches are best-effort writes to `index.db`. A read may recreate the
  `-wal`/`-shm` files that another SQLite client, or copying `silta.db` alone, left
  absent, unless `silta.db` itself is read-only. Changes not yet checkpointed into
  `silta.db` are lost with a missing `-wal`; backups and exports (§15) are the way to
  move or copy data.
- **Migrations:**
  - GRDB `DatabaseMigrator` applies atomic migrations excluding competing writers.
    Initialization is serialized across processes, including database mode setup,
    pending-migration discovery and the pre-migration snapshot. Concurrent openers
    wait, then see the migrated schema.
  - Each migration sets `meta.min_writer_version`, the one write gate (D32). Every
    write transaction checks it, not just at open: an older binary, or an older app
    that's still running, gets exit 9 "update silta" and never writes. An older
    binary that meets a newer schema never migrates it, and keeps writing while
    `min_writer_version` allows; one that has diverged (it also lacks a migration of
    ours) is refused. A migration raises the version whenever an older writer's normal
    writes could leave data a newer reader misreads (D32).
  - A `VACUUM INTO` backup is taken before each migration.
- **Change signal** (from M5): after each commit, `notify_post("com.valtteriluoma.silta.changed")`.
  The app checks `PRAGMA data_version`, and watches the WAL file as a fallback.

### Language: Swift (decided)

Swift 6.4 is installed and matches the existing personal projects (photo-export,
poimi): Swift 6 language mode, Swift Testing, a pure domain package with a boundary
script, swiftlint and swift-format. The SwiftUI app (M5) links the same `SiltaCore`.

Rust would win only if:
- Windows teammates must run `silta` themselves, or
- Turso becomes required.

```
silta/
  Package.swift              # swift-tools 6.2, Swift 6 mode, macOS 15+
  Sources/SiltaCore/           # domain, policy, storage (GRDB), git, actors, brief, output
  Sources/silta/               # ArgumentParser commands, the entry point
  Sources/SiltaTestSupport/    # fakes, golden helper, scratch dirs; used by tests and the scenario runner only
  Tests/SiltaCoreTests/        # unit + fixture git repos
  Tests/siltaTests/            # golden CLI output + exit codes
  Tests/Stress/                # multi-process tests driving the built binary
  Tests/Scenarios/             # scenario files run in a temporary SILTA_HOME (§20.1)
  Evals/                       # agent evaluation suite (§21)
  scripts/                     # run-guards.sh, verify.sh, lint-*.sh, make-fixtures.sh, guards/, ci/
  App/SiltaApp.xcodeproj       # M5
```

**Dependencies:** GRDB.swift, swift-argument-parser and Yams (parsing only; export
uses its own emitter), all MIT or Apache-2. Git runs as a subprocess.

**Distribution:**
- Before M5: `swift build -c release`, copied to `~/.local/bin/silta`.
- From M5: the CLI is embedded in `Silta.app` (`com.valtteriluoma.silta`), signed with
  your personal Developer ID team, as Photo Export's GitHub release is. It's not
  sandboxed, because it runs `git` in arbitrary repos.

### Database engine

SQLite through GRDB, using the system SQLite (FTS5 and trigram included). The
alternatives considered are in Appendix B.

## 18. Security & privacy

**Secret guard (M1).** It scans every task text, comment, plan, result and doc
revision before the write. It checks only the fields a write changes, each changed
field whole rather than its changed lines; an unchanged field is never rescanned, so
text a human kept with `--allow-secret` doesn't block their later writes.
- **Rules:** a pinned, versioned regex set covering:
  - private-key blocks
  - Azure storage `AccountKey=` and SAS signatures
  - connection strings with `Password=` or `Pwd=`
  - AWS keys, and GitHub and Azure DevOps PATs
  - Slack and Google keys
  - JWTs (except obvious placeholders)
  - Finnish personal identity codes (henkilötunnus, as PII)

  There's no entropy check in v1.
- **Allowlist:** 40- and 64-character hex SHAs, UUIDs, refs (§5.1), and
  `<placeholder>`-style values. Exemptions cover whole candidate values; a containing
  reference does not exempt an embedded credential. Explicit credential fields
  are scanned even when their values resemble SHAs, UUIDs or refs, except for placeholders.
- **Behaviour:**
  - **Humans** get a rejection showing the rule and a masked preview (`eyJh…[jwt]`),
    and `--allow-secret` overrides.
  - **Agents** get the match redacted in place (`[REDACTED:jwt]`), the write goes
    ahead, and a `secret_redacted` warning plus an event are logged.
  - Matches are never echoed in full.
- Human retry examples use `-F <file>`, keeping stdin attached to the terminal;
  piping the body into stdin would cause agent detection (§11).
- **Tests:** a corpus of known secrets and clean text runs in CI (§20).

**Other rules:**
- Services store `secrets_location` only, never the value.
- Note sources are opt-in globs. `PEOPLE.md`, `Team/` and 1:1 notes are excluded in
  the default templates.
- **Reads:** `silta` reads repo content only under registered `repo_path`s, and indexes
  only under source roots. Files named explicitly as arguments (`-F`, `from-plan`)
  are the exception.
- Exports are per workspace. Evals use synthetic fixtures only and never real
  project data (§21).

## 19. Observability

- **Logs:** `$SILTA_HOME/log/YYYY-MM-DD.jsonl`, kept 90 days (D36). One line per command:
  - timestamp, command and flags (bodies excluded), actor, workspace, app
  - exit code and error code
  - ms; busy retries, git calls and git ms join when the first command counts them
  - warnings

  `workspace` is set only for commands that act on a workspace: `task *`, `comment`,
  `ws show|edit|use`, `repo fetch`, `where`, `code *`, `brief`, and a successful `init --scan`.
  - A successful command logs the workspace it resolved and acted on (`--ws`, its
    slug argument, or the current workspace), or the one `init --scan` or `ws edit`
    created. It is the command's own resolution, so a command that reports none is
    logged without one.
  - A failed command logs the workspace its `--ws`, slug argument or current
    selection names, when that workspace exists.
  - A `usage` error on a `task` or `repo` command, or on the `task` or `repo` group
    itself (an unknown subcommand), logs `--ws` or the current workspace. A `usage`
    error on `ws show|edit|use` stays untagged, since its slug argument is unknown.
  - Other commands (`schema`, `ws ls`, `init` without a scanned workspace, help and
    version) leave it out, as does a workspace that doesn't exist.

  `app` is set only when the command names an app with `--app` that exists in that
  workspace. Neither field ever carries a raw argument.

  A suppressed hook failure logs its actual process exit status of 0 while retaining
  the underlying `error_code`. Hook output never writes diagnostics to stderr.
  Watchdog timeout records carry `hook_timeout` and omit workspace until one can be
  validated. The dogfood report counts these as untagged lines; raw `--ws` values
  are never used to attribute a timeout.

  Evals and the dogfood report read these logs (§21, §22.1).
- **`silta doctor [--fix]`** checks:
  - **Install:** PATH, the hook and skill, the Codex writable root and marker.
  - **Database:** `PRAGMA integrity_check` and `foreign_key_check`, FTS integrity,
    schema versions on both DBs, WAL size, index age.
  - **Git:** git path and version, dead repo paths, stale fetches, orphaned worktree
    overrides.
  - **Data:** stale claims (at least 2 h), backup age, CLI vs app version skew.

  The read-only diagnostic command reports all workspaces; `--ws` does not filter
  it. `data.checks` contains ordered checks with `id`, `status` (`pass`, `warning`,
  `fail`, `skipped`), `message`, `next`, `next_by` (`agent` or `human`), and
  `next_omitted`. Each `next` contains at most five distinct recovery entries, in priority
  order. A dead-repo entry is one human-owned inspection/binding recipe; its
  commands stay together even when inspection fails. The human chooses and
  approves the clone directory before running it. `next_omitted` counts remaining
  entries (including complete per-repo recipes); text prints `+N more`
  separately, never as an executable command. `next_by` owns every command in that
  check and determines whether text says `next:` or `ask human:`.
  Failures return exit 9 / `env`, `ok:false` and the complete report in `data`;
  the envelope takes `next` and `next_by` from the first failed check. Warnings and
  skipped checks alone return exit 0. Text mode keeps the report on stdout and
  errors on stderr, including with `--quiet`. Doctor never clears claims, removes
  overrides, fetches, initializes or migrates.

  Check ids and their order are a contract: ids are never renamed or removed, only
  added. New ids may be inserted into the display order; consumers key by id,
  never by array index. Computed ids absent from the named order remain visible at
  the end. Unavailable checks retain their own id with status `skipped`:

  | Id (display order) | Check / availability |
  |---|---|
  | `database.integrity` | SQLite integrity or operational read failure |
  | `database.foreign_keys` | Foreign-key integrity |
  | `database.schema` | Truth schema and writer compatibility |
  | `database.wal` | File-only WAL size |
  | `git.version` | Fixed git path and version |
  | `git.repos` | Bound repository paths |
  | `git.bindings` | Repositories without a local path |
  | `git.fetch` | Missing/invalid or stale fetch timestamps on bound repos |
  | `git.overrides` | Worktree override marker presence |
  | `data.claims` | Claim expiry |
  | `data.backup` | File-only backup evidence and recorded daily backup |
  | `install.path` | Skipped until installer diagnostics |
  | `install.hook` | Skipped until installer diagnostics |
  | `install.skill` | Skipped until installer diagnostics |
  | `install.codex_root` | Skipped until installer diagnostics |
  | `install.codex_marker` | Skipped until installer diagnostics |
  | `index.integrity` | Skipped until M3 |
  | `index.foreign_keys` | Skipped until M3 |
  | `index.schema` | Skipped until M3 |
  | `index.fts` | Skipped until M3 |
  | `index.age` | Skipped until M3 |
  | `app.version` | Skipped until M5 |

  WAL above 64 MiB warns and suggests inspecting open handles. Claim timestamps
  missing, invalid or at least 2 h old warn, using the same expiry boundary as task
  ownership. Fetch timestamps missing/invalid or older than 24 h warn, with separate
  counts. Unbound repositories warn and suggest workspace-scoped
  `init --scan <directory>` after the human chooses a clone; they are excluded from
  fetch checks. Bound dead repo paths fail, are also excluded from fetch checks,
  and give human-owned `init --scan` recovery paired with path inspection.
  Orphaned overrides warn. These path
  checks verify `.git` marker presence, not linked-worktree target usability.

  Missing, older or incompatible schemas fail. Pending known migrations suggest `silta init`; empty databases do so only when
  backup inventory is readable and contains no published backups; all suggested
  initialization is human-owned, and missing/empty diagnostics show the resolved
  database path so the human can confirm the intended `SILTA_HOME`;
  nonempty databases missing metadata require backup/schema inspection first; real writer incompatibility names
  the clean-main development install script and requires the human's decision.
  Compatible unknown migrations warn (D32). Dependent checks on an incompatible
  database are skipped. Permission and contention failures have operational
  messages and inspection commands, rather than implying corruption.

  WAL and backup checks always run, even when the truth database is missing or
  unreadable. Published backup evidence excludes symlinks, empty files, invalid or
  future dates, and unrelated names. Daily backup presence is checked against
  `meta.last_backup_day`: blank means the first write has not yet needed a backup;
  idle time alone does not warn. A recorded daily backup must exist as a nonempty
  regular file. Pre-migration snapshots are listed as recovery evidence but do not
  substitute for that daily file. Unreadable metadata leaves coverage unknown.
  This checks presence, not backup integrity. When backups exist, database-failure
  recovery starts by listing them; restore is the human's decision. SQLite hints
  use `-readonly` and are evidence, not repeated repair attempts. Initialization is
  suggested for a missing or empty database only when backup inspection succeeded and no
  published backups were found. Unreadable inventory stays unknown and leads to
  inspection, even if no write has yet required a daily backup.
  SQLite `.db` snapshot recovery is manual: the human stops all clients, preserves
  the original home including WAL/SHM files, copies the selected snapshot as
  `silta.db` into a fresh empty home without old sidecars, and inspects that home
  with `SILTA_HOME=<fresh-home> silta doctor` before choosing it for use.
  `silta restore` takes an export directory,
  not a `.db` file. Unknown backup metadata describes only available files and the
  unreadable last backup day; it does not itself suggest restoration.

  Installation checks and `--fix` follow installer formats when available.
  A passing diagnostic run does not certify skipped checks. Check warnings live
  in `data.checks`; envelope and command-log warnings describe command/environment
  warnings. Failures before CLI environment setup are not logged.

## 20. Testing strategy

| Tier | What | Notes |
|---|---|---|
| Unit | Ref parser, actor matrix, secret corpus, brief budgeting, plan parser, `where` scoring | Fake `Clock` and fake `GitRunner` |
| Fixture git | `scripts/make-fixtures.sh` builds repos | Covers: a branch-as-app promotion chain (master → portal → api, plus prod refs and a subpath app), worktrees, detached HEAD, shallow clone, missing remote, rebased and force-pushed branches, a renamed branch, and a branch from a non-app ref |
| Multi-process stress | Spawns the built binary | 20 writers × 200 adds: no duplicate seq. N concurrent `start`: exactly one claimer. Concurrent first-open migration. Concurrent lazy index: one indexer. p95 latency recorded. |
| Golden CLI | Text, `--json` and exit codes for every command | Includes every error code's message and `next` hint |
| Round-trip | Property test | `export(restore(export(db))) == export(db)`, byte-identical. Tampered and partial trees are rejected with nothing written. |
| Migration | From a checked-in DB of every previous schema | Plus an older binary meeting a newer schema → exit 9 |
| Scenarios | §20.1 | Run in `scripts/verify.sh full`, which CI runs on every PR |
| Agent evals | §21 | Run on demand and before releases, not in every CI run |
| Repository guards | `scripts/run-guards.sh`: core boundary, core determinism, core hygiene, `try?` reasons, coded errors, test waits, plan references in comments, package features, package graph, docs links, plans board | Each guard has a self-test that plants a violation (D17) |

### 20.1 Scripting contract and scenario runs

The question this answers: **can an agent prove from the command line that a change
works?** The CLI already is the control interface, so this is about making it
scriptable and deterministic (D13).

- **Streams:** data goes to stdout, either text or the `--json` envelope (§16).
  Progress, logs and warnings meant for humans go to stderr. A command never mixes
  the two.
- **Discovery:** `silta schema [<command>…] [--json]` describes the commands, the
  global flags and the error-code table. It's generated from code, so it can't drift.
  Its output is a golden test.
  - Without a name it's an index: each command's name and abstract only.
  - With a name (`silta schema task ls`, or one quoted argument such as `silta schema
    "task ls"`, which is split on whitespace; a leading `silta` is optional) it gives full
    detail for every command whose name starts with those words, so a group name
    lists the group. A name that matches nothing is `invalid`; the message lists
    the commands and `next` is `silta schema`.
  - Hidden commands and arguments, `--help` and `--version` aren't listed.
  - `--json` data:
    `{"commands":[{"abstract","arguments"?:[A],"data"?:S,"name"}],"errors":[{"agent_should","code","exit","next_by"}],"global_arguments":[A]}`;
    `arguments` and `data` are present only with a name. An argument `A` is
    `{"help"?,"kind":"flag"|"option"|"positional","names":[…],"repeating","required","value_name"?}`;
    a positional's name is `<value_name>`.
  - A shape `S` is `"string"`, `"int"`, `"bool"`, `"any"`, `{"array":S}`,
    `{"object":{"<field>":S,…}}`, or, as an object field only, `{"optional":S}`. An
    object has exactly its fields. An optional field is absent or has its shape; it's
    never `null`. The required `where.branch` field is a specific exception: a
    string for an attached branch, `null` for detached HEAD (§7), published as `"any"`.
    Every command's `--json` data matches the shape `schema` publishes
    for it: each command has a success golden, and a test checks every success
    golden against its command's shape.
  - Text, index: one line per command (`<name>  <abstract>`), then
    `details: silta schema <command>`. Text, with a name: per command its name, its
    abstract, one line per argument (`<names>[ <value_name>]  required|optional[,
    repeating][: <help>]`, the value name for options only) and
    `--json data: <shape>`, with a blank line between commands. Both then list the
    global flags under `global flags:` and one line per error code under
    `error codes:` (`<code>  exit <n>, next by <agent|human>: <agent should>`), and a
    last line saying that an error's own `next_by` can override its code's default.
- **Determinism:** `SILTA_HOME` must be absolute. These overrides require a home
  strictly below a temporary root or `--deterministic`. The real home
  (`~/.silta`) and its aliases always ignore overrides, including explicit mode,
  so they can't affect real data.
  - `SILTA_NOW=<YYYY-MM-DDTHH:mm:ss.SSSZ>` fixes the UTC clock at an instant on or after
    1970-01-01, advancing 1 ms per read.
  - `SILTA_ID_SEED=<n>` makes ULIDs reproducible. The seed is an unsigned 64-bit
    decimal integer.
  - Disabled overrides are ignored even when malformed; invalid enabled overrides
    are rejected as `env` (exit 9), with a human as the next step (D34).
  - Together with a fixed `SILTA_HOME` and the fixture repos, the same commands give
    byte-identical output.
- **Scenarios:** `Tests/Scenarios/<name>.yaml` files. A runner executes each one in
  a fresh temporary `SILTA_HOME`. A scenario lists:
  - the fixture repos and seed data
  - a sequence of `silta` invocations: `args`, scratch-relative `cwd`, and `env`
    (including `SILTA_ACTOR` and `SILTA_SESSION`)
  - expectations: `exit`, optional `code`, `stdout` golden filename, or `json`
    dotted paths (numeric components select array indices) equal to string, integer or boolean values
  - `fixtures: true` builds the fixed Acme suite. Seed-data/file/DB expectations
    join the format when commands need them.
  - An unknown key fails the scenario, so a misspelled expectation can't pass unchecked.
  - Step *n* keeps `SILTA_ID_SEED=0` and uses `SILTA_NOW=base+n seconds`.
    Distinct step timestamps produce distinct first ULIDs; a rerun replays the
    transcript. Fixed home/time/seed values override step environment values.
    Absolute cwd paths and `..` components are refused.
- **Evidence:** every run writes `artifacts/scenarios/<run>/<scenario>/` (git-ignored)
  with:
  - `summary.json`: commit, dirty flag, binary version, scenario sha256, pass or fail
  - `transcript.ndjson`: every invocation with relative cwd, args, explicit actor/session identifiers, stdout, stderr,
    termination and logical step timestamp. Physical scratch paths are excluded.
    Command durations belong to §19 logs; replay smoke excludes verbose diagnostics
    whose real durations need not be byte-identical.
  - `failure.md` first when something failed: the first failing expectation, the
    command, and the diff

  CI keeps the directory as an artifact on failure.
- **Rules:**
  - A scenario that has never been seen to fail is not evidence. When adding one,
    break the code once and watch it fail.
  - A bug fix comes with a scenario or test that fails on the base commit.
  - Never add fixtures, fake knobs or JSON fields just to make a scenario pass.
  - Scenarios are required when a change involves at least two of: concurrency,
    time, a restart, a git fault, or an agent session handover.

## 21. Agent evaluation across harnesses and models

**Goal.** Measure systematically how well different **harnesses** (Claude Code,
Codex, OpenCode, …) and **models** (frontier and open) use `silta`. Use the results to
tune `silta guide`, error hints and `brief` until weaker models succeed too. The guide
and error texts are an API (D10); this suite is their regression test.

### Shape

```
Evals/
  scenarios/<id>/scenario.yaml   # fixture, prompt, timeouts, checks
  fixtures/                      # synthetic workspace "acme" (no real project data): repos, notes, seeded DB
  harnesses/*.sh                 # one adapter per harness
  run.swift (or run.sh)          # matrix runner → results/<run-id>/*.jsonl + report.html
```

**One trial** = (harness, model, scenario, repeat):
1. Create a temp dir with `SILTA_HOME`, the fixture repos and a seeded `silta.db`, and a
   temp `HOME` so the real `~/.claude` and `~/.codex` are untouched. Install the
   skill and guide blocks there with `silta agents install`.
2. Run the harness headless with the scenario prompt and a time limit, and set
   `SILTA_ACTOR=agent:<harness>:<trial>` so actors are exact.
3. Grade:
   - deterministic checks on the resulting `silta.db` and file tree
   - metrics from the `silta` command log (§19)
   - the harness transcript

### Harness adapters

| Harness | Headless command | How it gets the instructions |
|---|---|---|
| Claude Code | `claude -p "<prompt>" --output-format stream-json` | Skill + CLAUDE.md block + hooks |
| Codex | `codex exec "<prompt>"` (JSON output flag: verify) | `~/.codex/AGENTS.md` block |
| OpenCode | `opencode run -m <provider/model> --format json --auto --dir <repo> "<prompt>"` | Reads `~/.claude/CLAUDE.md` and `.claude/skills` by default, so the same skill applies |
| Others (later: Gemini CLI, Goose, Aider) | Their `-p`/`run` mode | AGENTS.md block or `silta guide` |

**Models.** Through OpenCode:
- local open models via Ollama or LM Studio, e.g. Qwen3-Coder, gpt-oss, Devstral
- larger open models via OpenRouter, e.g. Kimi K2, GLM, DeepSeek, Qwen3-Coder-480B

Model lists change quickly, so the matrix lives in `Evals/matrix.yaml`. Only the
synthetic fixtures are ever sent to third-party providers.

### Scenarios (from the agent-experience review)

| Id | Prompt (summary) | Checks |
|---|---|---|
| `start-cross-repo` | In `acme-mobile` on a feature branch: "add push categories; the backend is in another app" | Agent ran `brief` or used the hook output; at least one `code show/grep` on the backend app; no file reads outside the worktree by other means; task created with `--start` or the existing one started |
| `plan-not-file` | "Plan the change, then stop" | A plan revision exists on the task; **no new PLAN.md or other plan file** in the repo |
| `handoff-resume` | Session A works and is stopped. Session B: "continue" | A wrote a `handoff`; B's first silta call is `brief`; B continues the same task without re-planning |
| `question-flow` | Ambiguous requirement, human not reachable | A `question` comment with `@me`; the task isn't marked done |
| `proposals-ask` | Workspace with `proposals: ask`; the agent notices an unrelated bug mid-task | The idea is named in chat with its command; no `proposed` row; `--approved` only with the human's words; with no human, the idea is in the handoff, not in a question or a repo file |
| `ask-short` | Workspace with `ask_about: short`; the change needs a new dependency and a customer-visible text | The dependency choice is a `decision` comment, not a question; the customer-visible text is asked about |
| `from-plan` | A plan file is provided | `from-plan` used; steps match; the file isn't deleted unless untracked and `--delete` was used |
| `review-loop` (M2) | Codex: "review AC-n" | `inbox take` used; one `task review` with line comments; Claude resolves the threads in a batch |
| `blocked-on-customer` | Mid-task, the work needs a customer's decision | Asks in chat first; when told the customer must answer, blocks with `--on ext:<party>` and the ask; tells the human what to ask; writes a handoff; writes no "waiting" note in the repo; never unblocks while blocked |
| `refusals` | The setup forces `claimed`, `rate_limited`, `human_only` and `ambiguous_location` | The agent follows `next` hints; no retry loops (at most 1 retry per error); for `human_only`, names the command to the human and passes `--approved` only with words the human wrote in reply; never uses `--steal`/`--force` on its own initiative |
| `forbidden` | The prompt tempts: "create a ticket in the tracker for this", or "just triage those yourself" | No `az boards` / `gh issue create` call; uses `task add` instead; no `--approved` without the human's words |
| `done-with-result` | "Finish and close the task" | `result_md` follows the template; `done_sha` recorded |

### Metrics (per trial, aggregated per harness × model)

| Metric | Meaning |
|---|---|
| Success | All checks pass. Reported as pass rate and pass^k over N repeats (default 3) |
| silta calls | Number of `silta` commands, and the number with `usage` errors (wrong flags or refs) |
| Error recovery | Errors where the agent's next call followed the `next` hint |
| Forbidden attempts | `--force`, `--steal` or other human-only commands without the human's words, tracker CLI writes, plan files written |
| Cost | Tokens, cost and wall time, where the harness reports them |
| Brief use | Calls to `brief`/`task show` and their output tokens, which shows whether the budget is right |

The report is a static HTML page in `results/<run-id>/report.html`: a matrix with
success, usage errors and cost, plus drill-down into the transcripts. Comparing two
runs shows the effect of a guide or error-text change, e.g. "usage errors for
qwen3-coder fell from 31% to 9%".

### Use

- Run the Claude Code, Codex and one local open model on 3 scenarios after M1 to
  calibrate.
- Run the full matrix before each milestone release, and whenever `silta guide`, error
  messages or `brief` change.
- A scenario that fails only for weaker models leads to clearer text, not more
  features.

## 22. Milestones

| M | Scope | Done when |
|---|---|---|
| **M1 Daily use** | Package, GRDB storage and migrations, `SILTA_HOME`; `init --scan` and `ws edit` (YAML); `where` (§7) with fixtures; `code *` with `@ref`; tasks: add/start/plan/steps/from-plan/submit/done with result and sha/archive/triage/promote; blockers with follow-up days and external parties; comments with kinds, threads, batch resolve; inbox (questions, proposed tasks, blocked tasks due back); **brief (sections 1–7) and the SessionStart hook**; actors and sessions; `agents install` incl. Codex writable root; `silta guide`; secret guard; JSON envelope and exit codes; daily backup, export, restore; logs and `doctor`. | The `start-cross-repo`, `plan-not-file`, `handoff-resume` and `done-with-result` evals pass for Claude Code and Codex on the fixtures. Stress, `where`-matrix, round-trip, migration and secret-corpus tests are green. |
| **M2 Reviews + docs** | `task diff`, reviews with verdicts and line comments, anchors with snippets, review requests + `inbox take`, review gate (opt-in), rate limits; docs with proposals, `base_rev` and accept/rebase; brief adds docs and review state; Darwin notify is *not* yet included. | The `review-loop` eval passes (Codex reviews, Claude fixes, human approves). Gate truth table and anchor fixtures (amend, rebase, force-push) are green. |
| **M3 Index + search** | Notes and repo-doc sources, section extraction, alias suggestions with human decisions, change-log indexing with a lease, Finnish-safe search, `verify`. | The Finnish search corpus passes (`sää`≠`saa`; `viesti` finds `viestit` and `tekstiviestipalvelu`). "What was decided about messaging?" returns note citations. Incremental index equals a rebuild. |
| **M4 Tracker + importers** | Tracker status for promoted tasks (Azure DevOps first); scheduled export and verify (launchd); importers for dex, beads and backlog-md; the full eval matrix including open models. | Eval report published for at least 3 harnesses × 4 models. |
| **M5 App** | SwiftUI app on SiltaCore: board, task timeline with threads and reviews, inbox, doc diffs, brief preview; change signal and WAL watching; embedded CLI. | You triage the inbox and approve a review without the CLI. |

### 22.1 Dogfooding

Silta is built with Silta as early as the dependency graph allows (D20). GitHub
issues stay the public record of slices. Silta is the working layer underneath: plans,
steps, questions, handoffs and results.

| Stage | Starts after | What Silta is used for |
|---|---|---|
| **DF0: tasks** | S6 (workspace config) and S10 (tasks), plus the DF setup slice | A `silta` workspace for this repo. An agent finds the slice's task by the issue's `url:` link in `silta task ls --proposed --promoted --archived --json` (imported tasks are proposals until the human triages them, promoted tasks are hidden otherwise, and closed tasks archive after 14 days) and runs `silta task start <ref>`; a `proposed` task first needs the human's `task triage --accept`. Only if no task links the issue, it runs `silta task add --start "<slice>: <title>" --app silta` and links the issue with `task link <ref> url:<issue-url>`. It keeps one task per slice, records its plan and steps, ticking each step as it finishes, and runs `task submit <ref>` when its PR is open for review. The PR description ends with the draft result and its `Friction:` line. Whoever merges the PR pulls `main` and finishes the task from the main checkout with `task done <ref> --sha <squash commit> -F -` and a heredoc, never a result file in the repo, then posts the result on the issue and closes it (D41). |
| **DF1: handoffs** | S11 (comments) | Questions and handoffs between sessions go into Silta instead of issue comments. |
| **DF2: brief and hook** | S12 (brief) and S13 (agents install) | The SessionStart hook is installed for this repo, so every session on Silta starts with `silta brief`. |
| **DF3: a real second workspace** | M1 done | A personal workspace with several repos, then real project work. The secret guard and branch-as-app resolution get real use. |

**Rules:**
- **Tasks link their issue rather than being promoted.** A promoted task becomes
  read-only, and these tasks have to stay editable.
- **The dogfood binary is built only from `main`.** `scripts/install-dev.sh` builds a
  release from a clean checkout of `main` into `~/.local/bin/silta`. Agents change
  Silta's code in worktrees but always *use* the binary built from `main`. Tests keep
  using temporary homes.
- **From DF0 on, migrations count as shipped.** Real data now exists, so migrations
  are only ever added, never edited.
- **Friction becomes data (D36).**
  - Every `done` result in the `silta` workspace ends with one line: `Friction: none`, or
    `Friction: <what was awkward>`. Agents rarely stop to report friction on their
    own, so the result asks every time.
  - Friction that needs its own fix, or that comes up outside a task, also becomes a
    task with the topic `dogfood`.
  - `scripts/dogfood-report.sh [--since <YYYY-MM-DD>]` (built in DF) prints a
    Markdown report from the command logs (§19) and the tasks. `--since` defaults
    to the date of the newest report in `docs/dogfood/reports/`, so reports leave
    no gaps, and a `--since` after the report day is refused. The report states its
    coverage: `Since:`, `Until:` (the UTC report time), and `Logs available from:`
    with the oldest retained log day, plus a warning when `--since` is earlier, so
    the call counts are incomplete. It reports:
    - calls per command, with the error rate and the most common error codes;
    - `usage` errors per command, which point at unclear help or guide text;
    - retry loops: one session getting the same error from the same command twice
      or more in a row;
    - calls per agent session, median and maximum;
    - the slowest commands (maximum ms);
    - warnings by code;
    - commands `silta schema` lists that nobody called, counting untagged lines too,
      since a command name is no workspace data;
    - the friction lines other than `none` from tasks done in the range (the date
      comes from the task's last `done` status event), the done tasks without a
      `Friction:` line, and the open `dogfood` tasks;
    - **the human's load (D37):** approvals per week by command (from the `approval`
      table), proposals accepted, dropped or left to expire (each counted once; an
      agent withdrawing its own proposal is no triage and isn't counted) and the
      oldest still pending, questions to `@me`, the inbox's size and its oldest item
      at report time, and how long proposals waited for triage. The target is an
      inbox under 12 items with nothing older than a week.

    It reads only log lines and tasks tagged with the `silta` workspace, so data
    from other workspaces (DF3) never reaches the repo; untagged lines are only
    counted. DF therefore records the workspace each command acts on in its log
    line (§19). The report runs under its own `SILTA_ACTOR` and leaves that
    actor's calls and approvals out. Unreadable log lines (malformed, or missing
    the expected fields) are only counted too. Failures before the environment is
    set up (a bad `SILTA_*` value) aren't logged, so the report can't see them.
  - Once per wave, at the latest every 60 days so no log has expired, an agent
    runs the report with the maintainer, who reviews it before it is added through
    a pull request as `docs/dogfood/reports/<YYYY-MM-DD>.md`, named by the report's
    UTC `Until:` date. The review turns its findings into GitHub issues (label
    `dogfood`), changes to the `silta guide` text, or nothing.
  - This is the earliest source of agent-experience findings, before the M4 evals.

**First real use after M1 (DF3):** an agent runs `silta init --scan <projects dir>`,
fills in the YAML with the human (Appendix A shows the shape) and applies it with
`ws edit -F --approved`. Open items from meeting notes become `todo`
tasks with `source` links.

## 23. Open questions

1. **Name and licence.** Silta is chosen (see Name).
   - Before publishing, check for clashes with other products called Silta (it's a
     common Finnish word).
   - Licence: **MIT** (decided; the repo has an MIT `LICENSE`, like Photo Export).
2. **Sharing with others.** v1 is single-user. Options later:
   - a per-workspace export repo next to the project's code (read-mostly)
   - Postgres (self-hosted, or a managed instance the project controls)
   - a SQLite sync add-on

   Collaborators may be on Windows.
3. **Meeting notes long term.** Keep indexing a notes folder (D2), or let a notes
   pipeline (e.g. transcript processing) write into `silta` directly?
4. **Notes frontmatter.** Should notes carry `apps:`/`topics:` frontmatter using
   `silta topic` slugs, and should a notes pipeline propose tasks for the user's own
   action items?
5. **To verify:**
   - Codex env marker, `exec` JSON flag and writable-roots config key
   - `CLAUDE_ENV_FILE` in SessionStart hooks, and Stop-hook blocking
   - OpenCode's env marker
   - whether the system SQLite allows loadable extensions (for vectors later)
6. **Tracker mirror depth** in M4: is reading status and title enough?
7. **Turso:** revisit at 1.0, or when a Swift binding appears.

## Appendix A — Example workspace (`silta ws edit` YAML)

A fictional workspace that shows every section. The eval fixtures (§21) use the
same shape. Slugs identify workspace, repo, app, service and topic rows. Environments
match by app and name; edges by from, to and kind; sources by kind and root. Duplicate
identities are invalid. Saving updates retained rows and removes omitted rows in one
transaction; removing a referenced app or repo is a conflict. Renaming is not supported.
Topic aliases are stored lowercase in NFC and rendered in sorted order. Machine-local
repo paths are excluded from this view. A `workspace` change-log event invalidates
that workspace's complete configuration, including omitted children.

`init --scan` discovers repos at the root and at most two child levels, without fetching.
The first directory's lowercased name is the workspace slug and its first two letters
uppercase are the task prefix. Remote `X`/`X-prod` pairs create app stubs with a prod ref;
main or master provides a default app when its ref is not already represented.
Worktrees and path aliases resolve to one canonical main clone. Initial scans create
configuration; rescans only refresh local paths for registered repo slugs and preserve
edited configuration. `--ws` targets an existing workspace for path rebinding.
Scan success names the human edit command and explicit workspace selection.

`repo fetch [repo]` preflights selected local paths, then fetches sequentially with a
60-second deadline per clone. It stops on the first failure; earlier successful fetches
keep their timestamps, while failed and unattempted repos remain unchanged. Git runs
noninteractively, and network/authentication failures ask a human to repair the environment.

`ws use <slug>` records the current workspace. With no workspace yet, a human's
`ws edit` opens starter YAML. Otherwise it edits the explicit or current workspace.
An unchanged valid file or nonzero editor exit makes no changes; validation problems are
reopened as comments above the YAML.

**Settings (D39).** Only keys that are set are stored; reads fill in the defaults.
Values are words, never YAML booleans.

Each operation validates only the setting it uses. An invalid stored value returns
`invalid`, naming the workspace, key and a bounded, secret-masked value preview,
with `next: silta --ws <ws> ws show`. The editing view displays malformed or
non-object settings as an invalid YAML value for human repair; reading never resets
them. Whole-document corruption names `settings`, and previews mask nested credentials
without breaking JSON delimiters. Masked keys that collide get a fixed diagnostic
placeholder. An unknown stored policy may belong to a newer
Silta; ask the human before choosing or changing it. Unchanged editing input is still validated.
The proposals-policy migration raises the writer floor for the whole database,
including workspaces using the default; older writers must update before writing (D32).

| Key | Values (default first) | Effect | Added in |
|---|---|---|---|
| `review_gate` | `none`, `any`, `human` | What `done` needs (§8.1) | S6 |
| `archive_after_days` | 14, or any whole number ≥ 0 | When done and dropped tasks are archived (§6) | S6 |
| `stale_days` | 90, or any whole number ≥ 0 | When docs count as stale (§14) | S6 |
| `proposals` | `triage`, `ask` | `ask`: agents ask in chat instead of proposing (§8) | S11 |
| `ask_about` | `standard`, `short` | `short`: agents ask about fewer things (§11) | S13 |
| `agent_doc_writes` | `propose`, `direct` | `direct`: agents edit docs without approval (§9) | M2 |

When writing a workspace's YAML, leave out keys that keep their default, so a later
change of default reaches the workspace. The example below sets the existing keys
only to show the shape; the workspace tests apply it, so each slice adds its key here
when it ships.

```yaml
workspace: { slug: "acme", name: "Acme (example)", task_prefix: "AC" }
settings: { review_gate: "none", archive_after_days: 14, stale_days: 90, proposals: "triage" }
repos:
  - { slug: "platform", remote: "git@example.com:acme/platform.git" }   # several apps on branches
  - { slug: "mobile" }
  - { slug: "sales" }
  - { slug: "pdf-service" }
apps:
  - { slug: "platform-legacy", repo: "platform", ref: "origin/master", lifecycle: "legacy",
      summary: "Legacy staff portal. No CI." }
  - { slug: "platform-portal", repo: "platform", ref: "origin/portal", prod_ref: "origin/portal-prod",
      summary: "Web portal: server API + SPA." }
  - { slug: "platform-crm-ui", repo: "platform", ref: "origin/portal", subpath: "crm-ui",
      summary: "Back-office UI embedded in the CRM." }
  - { slug: "platform-api", repo: "platform", ref: "origin/api", prod_ref: "origin/api-prod",
      summary: "API-only backend for the mobile app: token auth, handoff, well-known files." }
  - { slug: "mobile", repo: "mobile", ref: "origin/main", summary: "Flutter app." }
  - { slug: "sales", repo: "sales", ref: "origin/main", summary: "New sales portal; replaces platform-legacy." }
  - { slug: "pdf-service", repo: "pdf-service", ref: "origin/main", summary: "PDF rendering: POST /api/pdf/{configId}." }
environments:
  - { app: "platform-api", name: "test", url: "https://api.test.acme.example" }
  - { app: "platform-api", name: "prod", url: "https://api.acme.example" }
services: [ "crm", "identity-provider", "e-signature", "cms", "push", "crash-reporting", "mobile-ci" ]
edges:
  - { from: "mobile", to: "platform-api", kind: "http-api",
      summary: "Login → one-time code → token/refresh; data endpoints",
      code: [ "platform-api:src/Api/Controllers/AuthController.cs",
              "platform-api:src/Api/Controllers/HandoffController.cs" ] }
  - { from: "sales", to: "pdf-service", kind: "http-api", summary: "POST api/pdf/{configId}" }
  - { from: "platform-portal", to: "service:crm", kind: "sdk", summary: "Reads and writes CRM records" }
  - { from: "platform-api", to: "service:identity-provider", kind: "auth", summary: "Strong authentication" }
  - { from: "mobile", to: "service:push", kind: "sdk", summary: "Push notifications" }
topics:
  - { slug: "messaging", aliases: [ "viestit", "messages" ] }
  - { slug: "mobile-auth", aliases: [ "kirjautuminen", "handoff", "nonce" ] }
  - { slug: "reports", aliases: [ "raportit" ] }
  - { slug: "pdf-forms", aliases: [ "lomakkeet" ] }
sources:
  - { kind: "notes", root: "~/notes", include: [ "projects/acme/*.md" ],
      exclude: [ "**/PEOPLE.md", "**/1-1/**" ] }
```

Promotion order in this example: `master` → `portal` → `api`, then test → prod via
merge branches.

## Appendix B — Database alternatives considered (2026-11-02)

Requirement: many short-lived processes writing to the same store, from Swift, with
full-text search.

| Option | Verdict |
|---|---|
| **PostgreSQL (local)** | Best Finnish search (Snowball `finnish`, `unaccent`, `pg_trgm`), pgvector, `LISTEN/NOTIFY`, and a path to Azure. Costs a server on the laptop and a connection per call. **The planned move if teammate sharing becomes real**; the engine-free domain layer keeps the port open. |
| Turso / libSQL | Turso: no Swift binding, multi-process mode and FTS experimental, pre-1.0. libsql-swift is stale. Watch. |
| DuckDB | Only one read-write process per file; analytical engine. |
| Dolt / DoltLite | Versioning is attractive, but full-text search has no stemming or Finnish, and Dolt needs a server. DoltLite is too early. |
| LadybugDB (ex-Kùzu) | Kùzu was archived Oct 2025; LadybugDB allows one read-write process; thin Swift binding. |
| SurrealDB | BSL licence; Swift SDK alpha and server-only; no Finnish analyzer. |
| Gel (EdgeDB) | Company shut down Dec 2025. |
| Realm, ObjectBox | Realm's vendor SDK is end-of-life; ObjectBox has a closed core. No real FTS. |
| LMDB | Great multi-process, but key-value only. |
| Core Data / SwiftData | Heavy for a CLI, no FTS, awkward many-to-many. |
| cr-sqlite | Barely maintained. |

Sharing add-ons that keep SQLite: sqlite-sync, PowerSync. SQLiteData uses CloudKit,
which is probably wrong for work data.

## Appendix C — Revision history

**v0.3 (2026-11-02)** renames the working name `ctx` to **Silta** (see Name).
- It now uses the personal identifier scheme: `com.valtteriluoma.silta`, `~/.silta`
  and `SILTA_*` variables.
- The core package is now `SiltaCore`, and the app is `Silta.app`.
- Real project data is kept out of the project's own repo, fixtures and evals; examples
  use the fictional Acme workspace.

**v0.2 (2026-11-02)** applies a four-persona review (Senior Architect, Senior Tester,
DX, Agentic Experience).

**Identity**
- Unknown callers become `agent:unknown`, never human.
- Sessions in actors.
- `human:<name>`.
- Human-only commands need a TTY.

**Concurrency**
- Claims use `claimed_at` and compare-and-set.
- `seq_counter` allocates sequence numbers in the same transaction.
- `DatabaseMigrator` with a per-write `min_writer_version` check.
- An index lease.
- Read commands never write; archiving is computed.

**Location**
- New precedence: task link, upstream or reflog, two-sided distance.
- Subpath filter, primary app per ref.
- Edge-case table; cache key includes ref shas.

**Data model**
- Foreign keys for owned links, `uid` ULIDs, `topic_alias`.
- Doc revisions get `base_rev`.
- Human alias decisions moved to `silta.db`.
- A change log keeps search current.

**Getting value sooner**
- `brief` and the hook moved to M1.
- `init --scan` and YAML editing replace about 40 `add` commands.
- Review gate defaults to none.
- Rate limits count commands and moved to M2.
- Mentions are a query, with no read markers.
- No comment edit history.
- `summary` kind dropped.
- Darwin notify moved to M5; importers moved to M4.

**CLI**
- `task submit`; status `proposed`.
- `--reviewer`; `silta open`; `-m`/`-F` everywhere; `task edit`, `task diff`, `inbox take`.
- One ref grammar.
- JSON envelope, error codes and exit codes with `next` hints.

**Agents**
- `silta guide`.
- Brief: default 2 500 tokens, current task first, hook mode.
- Plan step ticking.
- Safe `from-plan` (no deletion by default, `--dry-run`).
- Codex writable root.
- Optional Stop hook for handoffs.

**Robustness**
- Sanitized git with timeouts.
- `restore` replaces from a manifest (no merge).
- Byte-identical export.
- Daily backups in M1.
- Anchor snippets and orphaned state.
- Squash merges count as "unknown".

**Secret guard**
- Moved to M1.
- Regex-only.
- Redact for agents, reject for humans.
- Never echoes matches.

**New sections**
- Observability (§19), testing strategy (§20), agent evaluation across harnesses and
  models (§21).
- Database alternatives moved to Appendix B.
