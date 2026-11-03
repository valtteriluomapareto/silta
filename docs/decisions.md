# Decisions

Numbered decisions, cited as `D#` in docs, plans and reviews. The numbers are never
reused. Change a decision by adding a dated **↳ update** line under it, or by
superseding it with a new entry that says "supersedes D#".

D1–D10 are the core product decisions, explained in [`spec.md` §4](spec.md#4-core-design-decisions).
They're summarised here so every decision has one index.

## Product

- **D1: SQLite is the source of truth.** It holds everything Silta owns. YAML is only
  an editing view of the configuration (`silta ws edit`).
- **D2: External sources are indexed, never owned.** That means meeting notes and repo
  docs.
- **D3: Deterministic export** to a text tree for backup and diff. `restore` replaces
  a workspace.
- **D4: CLI only, `--json` everywhere.** No MCP server and no daemon.
- **D5: Agent writes are gated.** Unsolicited tasks start as `proposed`, doc edits are
  proposals, and some commands are human-only. Since D38, an agent runs those with
  the human's quoted go-ahead.
  - ↳ update (D39): with `proposals: ask`, an agent's unsolicited task needs the
    human's go-ahead in chat instead of triage.
- **D6: Silta resolves "where am I"** from cwd, branch, upstream and claimed task.
- **D7: Code access is read-only**, through `git show`, `grep` and `log` on
  configured refs.
- **D8: Truth (`silta.db`) and derived data (`index.db`) live in separate files.**
  Human decisions are never stored only in the derived file.
- **D9: Every write has an actor with a session.** Unknown callers are agents, never
  humans.
- **D10: Agent-facing contracts are tested like an API**, across harnesses and
  models.

## Technology

- **D11: Swift 6 with SwiftPM.**
  - Targets: `SiltaCore` (library), `silta` (executable), and later `SiltaApp`.
  - macOS 15+.
  - Domain types don't import GRDB; record conformances live in the storage layer.
- **D12: SQLite through GRDB**, using the system SQLite.
  - PostgreSQL is the planned move if Silta is ever shared by several people.
  - Turso is revisited when it reaches 1.0, or when a Swift binding appears.
  - The comparison is in spec Appendix B.
  - **↳ update 2026-11-02:** a home-local advisory file lock covers database
    initialization: WAL setup, pending-migration discovery, backup and migration.
    GRDB discovers pending work before its migration transaction, and simultaneous
    WAL setup can fail without waiting; SQLite write transactions alone do not
    serialize the complete initialization section. Ordinary writes still use
    `BEGIN IMMEDIATE` and reads never take this lock.
- **D13: Scripting contract.** This is the "control plane" idea applied to a CLI: an
  agent must be able to prove from the command line that a change works.
  - Data goes to stdout; logs and diagnostics go to stderr.
  - `silta schema` describes commands, JSON shapes and error codes, generated from
    code.
  - Time, ids and the data directory are injectable, so runs are deterministic.
  - Scenario runs leave an evidence directory.
  - The details are in spec §20.1.

## Process

- **D14: One canonical `AGENTS.md`.** `CLAUDE.md` is a stub. Skills live in
  `skills/` and are symlinked into `.claude/skills/`. Rules are never duplicated
  across tool-specific files.
- **D15: Plans are named after the feature, never dated or phase-numbered.**
  - The board in `docs/README.md` mirrors `docs/plans/`.
  - When a plan ships, its lasting rules move to the spec or this file, and the plan
    is deleted.
- **D16: Reviews use independent subagents.**
  - Architect, Tester and Pragmatism review every plan and every implementation.
  - An Agent experience reviewer joins for changes to agent-facing output.
  - Tests come first, and a bug fix includes a test that failed first.
  - **↳ update 2026-11-02:** test-first is a written flow
    (`coding-guidelines.md`, "Test-first flow").
    - A bug's reproduction is committed first, wrapped in `withKnownIssue`, and the fix
      removes the wrapper.
    - Features start from failing acceptance tests.
    - Goldens are written from the spec.
    - PRs give "Test-first evidence".
    - CI requires a test change on PRs labelled `bug`.
- **D17: Invariants are enforced by guards, and every guard has a self-test.**
  - Each guard must pass a clean tree and fail a planted violation, because a guard
    that silently stops matching passes forever.
  - `scripts/run-guards.sh` runs them all and reports every failure.
- **D18: The toolchain is pinned.**
  - Xcode comes from `.xcode-version`.
  - SwiftLint and swift-format are pinned by version and SHA256.
  - GitHub Actions are pinned by commit SHA.
  - Builds treat warnings as errors, and lint runs in `--strict` mode.
  - A test run with zero tests fails.
  - **↳ update 2026-11-02:** Xcode 27.1, the same build (27A9275) locally and in CI.
    CI runs on GitHub's `xcode-27` image, which is a public preview. If that image
    breaks, the fallback is `macos-26` with Xcode 26.6, which reports the same Swift 7
    feature list (D29).
  - **↳ update 2026-11-02:** Swift package dependencies are pinned with `exact:`, and
    `Package.resolved` is committed. `scripts/verify.sh` builds only from the resolved
    file, so a manifest change without a matching resolve fails.
- **D19: Branch and merge flow.**
  - Branches are `<agent>/<slice>-<slug>`, squash-merged on green CI.
  - Until the first code lands, documentation changes may be committed directly to
    `main`.
  - **↳ update 2026-11-02:** code has landed, so every change goes through a pull
    request. A ruleset on `main` enforces this:
    - no direct pushes, force pushes or deletion
    - squash merges only, with linear history
    - the `verify` check must pass on a branch that is up to date with `main`
    - no approvals are required and nobody bypasses the rules

    Auto-merge is on, so a PR can be queued to merge when CI passes.
- **D20: Dogfood from DF0** (spec §22.1).
  - GitHub issues are the public record, and Silta is the working layer. Tasks link
    their issue with a `url:` link and are not promoted, so they stay editable.
  - The binary used on real data is built only from `main`, by
    `scripts/install-dev.sh`.
  - From DF0 on, migrations count as shipped.
  - Dogfooding friction is recorded as Silta tasks with the topic `dogfood` (and, from
    D36, a `Friction:` line in every result), and triaged once per wave.

## Code

The rules themselves are in [`coding-guidelines.md`](coding-guidelines.md).

- **D21: Concurrency.**
  - A synchronous, nonisolated core built from `Sendable` value types.
  - `async` only for real I/O waits.
  - No global mutable state, and no actors in the core.
  - Swift 6 strict concurrency (the upcoming-feature flags are in D29).
  - Default MainActor isolation only in the app target (M5).
- **D22: Errors.**
  - Per-area error enums conforming to `CodedError`, mapped to the §16 table and
    checked by a golden test.
  - Plain `throws` by default.
  - No `try!`, `as!`, force unwraps or IUOs in `Sources/`.
  - `try?` needs a reason.
- **D23: Seams.**
  - One `SiltaEnvironment`, passed explicitly.
  - Naming: `System…`, `Fake…`, `Scripted…`.
  - Fakes live in a `SiltaTestSupport` target.
  - A conformance suite for every seam.
- **D24: Access control.**
  - `public` only for the app-facing façade.
  - `package` for the CLI and test support.
  - `internal` by default.
  - `@testable` only in unit tests.
- **D25: Layout.**
  - Feature folders.
  - GRDB records in `Storage/Records/`.
  - One primary type per file.
  - Commands named `<Noun><Verb>Command`.
- **D26: Tests.**
  - Swift Testing, with `#require` for preconditions.
  - Parameterized matrices.
  - The slow tier selected by tag.
  - Per-test scratch directories.
  - A home-made golden helper; goldens are never regenerated in CI.
- **D27: Logging.**
  - An injected `Log` seam; no `print` or `os` in the core.
  - Output only from the output layer.
  - Logs never contain bodies.
- **D28: Doc comments.**
  - Required on public and CLI-facing package API.
  - Elsewhere, only where the reason isn't obvious.
- **D29: Language level: "future Swift" up to the stable line.**
  - Swift 6 language mode, plus all six Swift 7 upcoming features on every target:
    `ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility`,
    `InferIsolatedConformances`, `NonisolatedNonsendingByDefault`,
    `ImmutableWeakCaptures`.
  - This is the list the pinned toolchain (Swift 6.4, Xcode 27.1; D18) reports as
    enabled in Swift 7 mode (`swiftc -print-supported-features`).
  - New stable APIs are allowed case by case.
  - Experimental features need a decision.
  - Switching language mode is its own planned change.
- **D30: Simplicity.** Write the smallest code the acceptance tests and the spec
  need: no options, types or validation without a current caller, and no generality
  for later slices. Pragmatism reviews over-engineering first. Errors that can reach
  the caller are always `CodedError` (guard).
- **D31: `silta schema` reads ArgumentParser's own definitions.**
  - It uses two underscored, unstable ArgumentParser APIs: `_dumpHelp()` (the
    `--experimental-dump-help` JSON) for arguments, and `_commandName` for names. In
    exchange the schema can't drift from what the parser accepts.
  - Mitigations:
    - ArgumentParser is pinned exactly (D18)
    - only the fields the schema needs are decoded
    - the `schema` goldens fail on any change
  - On an ArgumentParser upgrade, check `silta schema` first.

## Wave-3 follow-up (2026-11-03)

- **D32: `min_writer_version` is the one write gate.**
  - A binary that meets a newer schema (unknown migrations) never migrates it, and
    writes while `min_writer_version` is at most its own writer version.
  - Why: the rule lives in the older binary, so it must be right before the first
    release; and the app and the CLI can run at different versions. Under "any unknown
    migration blocks", adding one column would lock out the app until it updated, and
    a long-running app would answer differently from a fresh CLI.
  - **When to raise it:** whenever an older writer's normal writes could leave data a
    newer reader misreads. That includes new constraints, invariants kept in code
    (a mirrored or denormalized column), and new values in a vocabulary (a status, a
    comment kind) or in a JSON column; a vocabulary change with no schema change ships
    as a migration that only raises the version.
  - Writers keep what they don't know: JSON columns keep unknown keys, and owned
    writes use `UPDATE` or `INSERT`, never `REPLACE`, which would reset a newer
    binary's columns.
  - A newer schema that also lacks one of this binary's migrations has diverged, and
    is refused. So migrations are never squashed or renamed once shipped.
- **D33: Actors are `ActorID` values, validated where they enter.**
  - `human(name)` or `agent(tool, session)`, recorded as `human:<name>` or
    `agent:<tool>:<session>`. A name or session is 1 to 64 letters, digits, `.`, `_`
    or `-`, starting and ending with a letter or digit; a tool is lowercase. So
    `agent:Claude` can't be a second claimant, and a mention (`@human:acme.`) ends
    before trailing punctuation.
  - D9 amended: an agent's claim compares its session; a human's compares its name.
  - A target meaning "any session of a tool" (M2's `review_request.reviewer`, `inbox
    --for agent:codex`) is not an `ActorID`; that slice names its own type.
  - Why: rows store actors from S10 on, and claims compare sessions (D9); a malformed
    value in a row is permanent after DF0. The name avoids Swift's `Actor` protocol.
  - `SILTA_ACTOR=agent:<tool>` gets the resolved session appended, so D9 holds without
    agents computing a session.
  - `human_only` names the detected actor, and why an unknown agent was detected.
- **D34: Bad `SILTA_*` configuration is `env`, for the human.**
  - Covers `SILTA_HOME`, `SILTA_NOW`, `SILTA_ID_SEED`, `SILTA_ACTOR` and
    `SILTA_SESSION`.
  - Why: the harness, the eval runner or the human's profile sets them, not the agent.
    An agent's shell may not keep an `unset` between calls, so "unset it and retry"
    loops, and for `SILTA_HOME` the obvious workaround writes to the real
    `~/.silta`.
- **D35: Blockers name what would unblock them.**
  - `task block --on <ref> -m <why>` links a task to what it waits on (`blocked_by`):
    another task, an external party (`ext:acme`, `ext:app-store`) or a `url:`. For a
    party, `-m` is the ask; Silta sends nothing.
  - An external party is a plain name, not an actor and not a YAML entity: it is
    waited on but never writes, claims or passes a human-only check, and it is never
    renamed. A `new_party` warning catches typos.
  - A follow-up day (default 7 days) brings every blocked task back to the human's
    inbox, so nothing waits unnoticed. Silta never unblocks by itself, because reads
    never write.
  - `block` releases the claim and `unblock` always returns to `todo`, so no previous
    status has to be stored and no stale claim comes back. `task start` on a blocked
    task fails with its own `blocked` code, and suggests `unblock` only when every
    blocker is a task and all are done, so following `next` never bypasses an open
    blocker; a party or URL blocker comes back only on its follow-up day.
  - Rejected: a customer question as a separate comment kind that the task blocks on.
    It took two commands and a comment ref, and the answer arrives by email or in a
    meeting anyway, where the human records it and unblocks.
  - Non-code work (releases, store submissions, contracts) is an ordinary task; one
    with no app records no branch, worktree or commit.
  - ↳ update (2026-11-03, D40): unblocking a block that isn't ready needs the human's
    go-ahead. An agent's `unblock` of a batch with such a task is `human_only` unless
    it carries `--approved`; a ready block still unblocks without one.
  - Why: "waiting for the customer's input on messaging" and "waiting for App Store
    approval" are the most common non-code blockers. Free text in a status can't say
    what a task waits on, can't remind anyone, and can't notice a prerequisite landing.
- **D36: Dogfooding measures itself.**
  - Command logs are kept 90 days instead of 14. They hold codes, flag names and
    actors, never bodies, so they stay small, and a report can cover several waves.
  - Every dogfood task's result ends with a `Friction:` line, `none` included. Agents
    rarely stop to report friction on their own, so the result asks every time.
  - `scripts/dogfood-report.sh` turns the logs and friction lines into a Markdown
    report: error rates, `usage` errors and retry loops per command, calls per
    session, slow commands, unused commands and friction. Once per wave the
    maintainer commits it under `docs/dogfood/reports/`. It reads only lines and
    tasks tagged with the `silta` workspace, so other workspaces' data never reaches
    the repo; DF makes every log line record its workspace and app.
  - Not now: comparing Silta against plan files or other tools. That needs a
    without-Silta arm in the evals (§21) and is revisited after S16.
  - ↳ update (2026-11-03, D39): "dogfood task" means a task in the `silta` workspace.
    The rule lives in this repo's AGENTS.md, so other workspaces never see it.
  - Why: the logs were collected but nothing read them, and friction depended on
    agents volunteering it.
- **D37: The human's attention is the budget.**
  - Silta should cost the human about ten minutes a day, in one sitting. During a
    session it interrupts them only for what an agent can't do or decide.
  - Agents decide and record: a choice becomes a `decision` comment, not a question,
    except for a fixed list (§11): scope, new dependencies, public APIs, schemas and
    migrations, anything another app or the customer sees, deleting what they didn't
    create, anything irreversible, and money.
  - What needs the human comes in one batch: approvals, proposals and questions in
    one message, never one at a time.
  - Fewer proposals: usually none, never more than two per session, only what the
    agent would bet the human wants. An untriaged proposal leaves the inbox after 14 days
    ("not now") without any write.
  - Agents pick their next work: "work the backlog" takes the first `todo` task for the
    app, by priority, then age.
  - The inbox is short, ordered and grouped: blocked tasks past follow-up are one item
    per party or URL, at most 12 items, then `--all`. `triage --accept … --drop …` and
    `unblock` take several refs, all or nothing, so one answer is one command.
  - The dogfood report measures the load: approvals, proposal outcomes, questions,
    inbox size and age.
  - Why: every inbox item, question and refusal costs the human's attention, and
    nothing in the design limited or measured it. A backlog the human stops looking
    at rots, and the agents' work with it.
  - ↳ update (D39): the ask-list is fixed; a workspace's `ask_about: short` shortens
    it.
- **D38: The human works through agents.**
  - The human talks to an agent, which runs `silta` for them. They don't use the CLI
    themselves. The Mac app (M5) is their own surface and counts as `human:*`.
  - `me` and `@me` mean the human, `human:<USER>`. An agent asked "what needs me?"
    runs `silta inbox --for me`.
  - Human-only commands stay gated. A human actor (a TTY or the app) runs them
    directly. An agent names the exact commands to the human in chat, and after a yes
    runs them with `--approved "<the human's words>"`. Only words the human wrote in
    reply count, and they cover only the commands named. They are stored in an
    exported `approval` row in the same write, with the actor and the command's refs
    and flag names.
  - Without `--approved`, `human_only` (exit 3) tells the agent to ask in chat; `next`
    shows the command with the placeholder, which is itself refused as `invalid`.
  - When no answer can come, the agent doesn't wait: it leaves a `question` for `@me`
    listing the pending commands, writes a handoff and picks other work.
  - Every `$EDITOR` command also reads `-F <file>`: `ws edit`, `task edit`, `doc edit`
    and `doc accept --rebase` (M2). `ws show` prints the current YAML, so an agent can
    show the change first. An agent edits a task it claims without approval.
  - Still a guard against accidents, not security: an agent could invent a quote. The
    `refusals` and `forbidden` evals check that agents never do.
  - Rejected:
    - Dropping the gate: no pause before a human decision, and no record of who
      allowed it.
    - A boolean `--human-ok`: easy to add by reflex, and it doesn't record what the
      human agreed to.
  - Why: the maintainer never runs the CLI. Commands that need a terminal would be
    unreachable, and `ws edit`, the only way to configure a workspace, would be
    unusable.
  - ↳ update (D39): with `proposals: ask`, an agent write that would create a
    `proposed` task is human-only too. A human's request in chat for such a write
    counts as its go-ahead.
  - ↳ update (2026-11-03, D40): `--steal` and `--force` are human-only only when they
    bypass something (a fresh claim, an unmet review gate); an agent's `unblock` of a
    block that isn't ready joins the list. `task edit --print` prints the document, as
    `ws show` does. An approval row of a creating command names the refs it created,
    and an edit that changes nothing stores no approval.
- **D39: Each workspace chooses how much ceremony it wants.**
  - Two new workspace settings (§6, Appendix A). Each defaults to what the spec
    already describes:
    - `proposals: triage | ask`.
      - With `triage`, the default, an agent's unsolicited task becomes `proposed`
        and waits for triage.
      - With `ask`, any agent write that would create a `proposed` task is
        human-only. That covers `task add`, `--parent` on a task the agent doesn't
        claim, and `from-plan` with or without `--split`. The agent names the idea to
        the human in chat, and after a yes runs the same command with `--approved`.
      - `human_only` names the setting, so an agent that read the default rules
        understands why.
      - Generated proposals, from `verify --fix-tasks` (M3) and importers (M4), still
        go to triage. Their slices decide otherwise if needed.
    - `ask_about: standard | short`.
      - With `short`, agents stop asking about scope changes, new dependencies, and
        public APIs, schemas and migrations.
      - They still ask about anything another app or the customer sees, deleting
        what they didn't create, anything irreversible, and money.
      - A repo's own rules, such as its AGENTS.md, still apply.
      - This setting changes only what agents are told. The evals check it (§21).
  - **Approved tasks are `todo` under either setting.**
    - An agent write that would create a `proposed` task creates `todo` when given
      `--approved`, with one `approval` row. The human already said yes, so triage
      would ask twice.
    - When the human's own message in chat asks for the write (add this task,
      import this plan), that message counts as its go-ahead, so the agent doesn't
      ask again. A task prompt, or the agent's own text, still never counts (D38).
    - This is the one exception to `approval_unused`: under `triage`, `--approved`
      on such a write is used, not ignored.
  - **Switching:** proposals that already exist stay in triage, or leave the inbox
    after 14 days as usual.
  - **No human present under `ask`:** ideas go under "what's left" in the handoff
    or the `done` result. Never a `question`, which would be triage in a heavier
    form, and never a TODO comment or file.
  - The complete list of settings: `review_gate`, `archive_after_days`, `stale_days`,
    `proposals`, `ask_about`, and `agent_doc_writes` (M2).
  - **Rules for every setting:**
    - A setting changes what Silta does and what agents are told. It never changes
      `silta schema` or the error codes. A switched-off feature answers with an
      existing code and a `next`.
    - Only explicitly set keys are stored. Defaults are filled in when settings are
      read, in one typed value, so a changed default reaches every workspace that
      didn't set the key. "Non-default" means the value differs from the default.
    - A rule that depends on a setting is decided inside the write's transaction,
      as `review_gate` already is.
    - Settings change only through `ws edit`, or with the whole workspace through
      `restore`. `ws edit` is human-only under every setting, so every change is
      approved and recorded (D38), and settings can't loosen themselves. S14
      decides whether `restore` is human-only too.
    - Never from environment variables: an agent can set those.
    - Values are words, not booleans: YAML 1.1 reads `on`, `off`, `yes` and `no` as
      booleans, and validation rejects them with a hint.
    - A setting needs a current user (D30). The maintainer asked to switch off what
      they don't use (2026-11-03), and their workspaces are the first users.
    - D32 applies as written. A value that older writers would violate in their
      normal writes (`proposals: ask`) needs a migration that only raises
      `min_writer_version`. `ask_about` changes only the text agents are told.
    - Tests:
      - goldens use the defaults;
      - every non-default value gets a policy test (for `ask_about`, the brief and
        guide goldens);
      - an absent key behaves like its default;
      - the evals cover the agent's side.
  - **Agents learn the settings from `brief`.**
    - Its location section always names the non-default settings in one fixed line,
      e.g. `settings: proposals: ask (ask in chat before adding a task)`. Trimming
      never cuts that line.
    - `brief --json` always has a `settings` object, which is empty when everything
      is the default.
    - `silta guide`, and the skill that copies it, stay the same in every workspace.
      Each non-default value gets one conditional sentence there. A guide that
      varied per workspace would need storage and location resolution, and the
      static skill couldn't follow it.
  - **Never configurable:**
    - the secret guard, claims, backups and the write gate;
    - actor detection, location rules and read-only code access;
    - the inbox's order;
    - batching what needs the human into one message;
    - writing an `approval` row whenever an approval is required.
  - **Not now:**
    - **Profiles (named presets).** An agent writes the YAML for the human (D38), so
      the human never tunes keys one by one. Presets would be a second mechanism to
      test.
    - **A general per-command approval toggle.** Each gate change is its own named
      setting, like `proposals` and `agent_doc_writes`. The dogfood report counts
      approvals per week by command (D37). A new setting comes if some other
      command turns out to cost the human time.
    - **Other values nobody has asked to change:** the inbox cap and proposal window,
      the follow-up default, the claim length, the rate limit, log retention and
      backups.
    - **A setting for the `Friction:` line.** The rule lives in this repo's AGENTS.md
      and covers only the `silta` workspace (D36 update), so other workspaces never
      see it.
  - **Slices:**
    - S11 adds the typed settings value and `proposals`, and touches task creation
      and `from-plan` as well as the inbox. It also adds `proposals` to Appendix A,
      and the migration that raises `min_writer_version` for the whole database.
      The doc comment on `ActorID.requireHuman` ("before command input or storage is
      opened") doesn't hold for this gate.
    - S12 adds the brief's settings line.
    - S13 adds the guide sentences, `ask_about`, and the eval scenarios.
    - S14's restore validates `workspace.yaml` settings like `ws edit` does, and
      decides whether `restore` is human-only.
  - Why: the human wants to switch off what they don't use. Proposals waiting for
    triage and questions in chat are the parts of D37 that most often wait on the
    human, and these two settings remove most of them where the human chooses.

## S10 review follow-up (2026-11-03)

- **D40: Task rows stay rebuildable, and approval follows what a write bypasses.**
  - **Event bodies.** A `status` event's body is always the new status, so status
    history can be rebuilt from events. `task submit` takes no body: nothing read it
    (D30). The event kinds are listed in §6, `secret_redacted` included.
  - **`task ls --json` is a summary**: `ref`, `title`, `status`, `priority`, `app`,
    `parent`, `claimed_by`, `claimed_at`, `external_ref`, `waiting`, `follow_up_at`,
    `created_by`, `created_at` and `updated_at`, without the description, plan,
    acceptance or result. `task show` keeps the full detail. Data shapes only gain
    fields (§16), so the smaller shape is fixed now, before agents depend on the old
    one.
  - **`parent`** appears in `task show` and `task ls`: the parent's ref, absent when
    there is none (an optional field is never `null`, §20.1). Text output names it in
    the header line, e.g. `AC-4 todo (priority 2, parent AC-3): …`.
  - **Approval rows say what they created.** For a command that creates tasks (`task
    add`, `from-plan`), the recorded `command` ends with ` -> <created refs>`. The
    command names only the flags actually passed, and stays body-free.
  - **`promote` is refused from `proposed` and `blocked`** (`conflict`, exit 6). The
    `next` is the exact triage command for a proposal and `silta task unblock <ref>`
    for a blocked task, so no proposal or block is left where nothing can change it.
  - **`triage --priority` is optional**: without it, accepted tasks keep their stored
    priority.
  - **Unblocking a block that isn't ready needs the human's go-ahead.** Ready means
    every blocker is a task and all are done (§8). An agent's `unblock` of a batch
    with any other task is `human_only` unless `--approved` is given, decided inside
    the write, with one approval row for the batch, all or nothing. A ready unblock
    needs no approval, and `--approved` on it warns `approval_unused`. Humans are
    unchanged.
  - **`from-plan --split` children take the root's status**, decided once per import:
    `todo` under a `todo` or `doing` root, `proposed` under a `proposed` one.
    `--dry-run` shows the same.
  - **`task edit <ref> --print`** prints the exact edit document, a read with no
    approval. An agent's edit that blanks a stored Result or Plan is `invalid` and
    names the field; humans may clear them. An edit that changes nothing writes no
    approval row, so `--approved` warns `approval_unused`. Only changed fields pass
    the secret guard.
  - **Promoted tasks are left out of `task ls`** unless `--promoted` is given. Their
    tracker owns them, so `read_only_promoted` points the agent at other work: `next`
    is `silta task ls --status todo` and `next_by` is `agent`.
  - **An unreadable `-F` file is `invalid`** (exit 1) with the failing command's
    `--help`: it's the caller's mistake, not the environment's.
  - **`--force` and `--steal` need approval only when they bypass something**: `done
    --force` when the review gate is unmet, `start --steal` when another session holds
    a fresh claim. Otherwise the flag changes nothing and needs no approval.
  - **`--status proposed` implies `--proposed`.** The proposal refusal's `next` is the
    exact `silta task triage --accept <ref> --approved "<the human's words>"`.
  - Why: DF0 makes rows permanent (D20). Free text in status events and approval rows
    that can't be tied to their tasks can't be repaired afterwards. The rest are
    places where following the contract led an agent into a loop, lost data (a
    priority, a Result), or asked the human for something that bypassed nothing.
