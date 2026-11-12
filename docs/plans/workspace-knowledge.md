# Workspace knowledge: docs on the workspace map, kept by agents

Status: proposed

## Goal

An agent in any repo of a workspace starts with the knowledge that matters for its
app and task: the workspace map (apps, edges, services, topics) and the docs
attached to it. When it learns something lasting, it proposes a doc change. The
human coordinates and reviews proposals in one batch; they never write, search or
maintain docs themselves.

## Operating model

This plan is designed around who does what. Every slice must keep this split.

| Role | Does | Never has to |
|---|---|---|
| **Agent** | Reads the docs the brief shows next to the map; proposes doc changes after learning something lasting; notes map gaps for the human; checks a stale doc against the code before relying on it; prepares one review batch for the human, merging overlapping proposals first | Ask the human what a doc says, or wait on a review to keep working |
| **Human** | Says "review the doc proposals" to an agent; answers one batched message; approves map changes in chat (D38); decides contested or cross-team knowledge | Run the CLI, write markdown or YAML, find duplicates, chase stale docs |
| **Silta** | Attaches every doc to a map item; shows docs where the item appears in the brief; gates and records writes (D5, D38); flags stale docs; keeps every revision | — |

Reading costs the human nothing. Writing costs them one batched answer (D37).

## Inputs

- Spec §2 goals 1–2, §5 and §5.1 (refs), §6 (`doc`, `doc_rev`, `link`,
  `comment.doc_rev_id`; `app`, `edge`, `service`, `topic`), §8 inbox, §9 docs, §11
  (human-only, `--approved`), §12 brief sections 4, 5 and 9 and its budget, §15
  export, §20 test tiers, §21 evals, §22 M2, Appendix A (`ws edit` YAML).
- D2, D5, D8, D30 (simplicity), D32 (`min_writer_version`), D37 (attention budget),
  D38 (human works through agents), D39 (settings), D44.
- [DF3 plan](df3-real-workspace.md): the real multi-repo trial where this is judged,
  and whose question E5 decides whether map proposals are needed.
- Spec §23 Q8 (code access): docs and edges point at code through `silta code`.

## Design

### The map and the docs

The workspace configuration is the map: structured, small, and what Silta routes
by. Docs are the knowledge hung on it. **A doc never stands alone: it is attached
to at least one map item**, and it appears wherever that item does.

| Map item | Ref | What its docs explain |
|---|---|---|
| App | `app:platform-api` | What the app is beyond its one-line summary: structure, conventions, environments, release |
| Edge | `edge:mobile/platform-api/http-api` | The interface: payloads, rules, versioning, error handling |
| Several edges | each edge it crosses | A path through several apps, e.g. push from API to device |
| Service | `service:push` | Setup, quirks, limits, where credentials live |
| Topic | `topic:messaging` | Cross-cutting domain knowledge |

**Refs are shell-safe and printed by Silta.** Slugs can't contain `/`, so
`edge:<from>/<to>/<kind>` parses unambiguously and needs no quoting. Edge kinds
become identifiers like slugs; a migration check refuses stored kinds that don't
fit and names them for `ws edit`. The brief prints each edge's exact ref, so an
agent copies it instead of composing it. `edge`, `service` and `doc` become
reserved app slugs, like `none`. `service:` joins §5.1.

**What goes where:**
- **The map** holds what Silta needs to route and resolve: identity, location,
  refs, who talks to whom, and one-line summaries.
- **Docs** hold explanations. A summary that grows past one line becomes a doc.
- **Repos' own docs** stay in the repos (D2). A workspace doc links to them by code
  ref instead of copying them. Cross-app knowledge goes to a workspace doc, not into
  one repo's docs.

### What a doc is

- A short markdown document. Each revision stores its body **and its metadata**:
  title, kind and about refs. Accepting a revision applies them to the doc.
- A doc with no accepted revision is invisible to the brief and to removal checks,
  so a pending proposal never pins a map item or reaches an agent.
- **Kinds:** `contract`, `flow`, `runbook`, `reference`. Optional: inferred from the
  about refs (one edge → `contract`, several edges → `flow`, a service → `runbook`,
  otherwise `reference`). The kind is a label only.
- **Summary line:** the first non-heading line of the body, at most 120 characters.
  The guide says to write the key rule itself there.
- **Point at code, don't copy it.** Code appears as file refs
  (`platform-api:src/Push/Category.cs`) at an app's ref. Line ranges are allowed but
  drift; the guide prefers file refs.

### Attachments stay consistent

- An `about` link is the attachment. Links parsed from a body later (M3) use
  `rel=cites` and never pin anything.
- `link.to_kind` gains `edge` and `service`. A map change that would remove an item
  with attached docs is a `conflict` that names the docs, for every map table, not
  only apps and topics as today.
- Archiving a doc deletes its about links, so no link keeps the id of a deleted row.
- Changing an edge's kind is a removal plus an addition. The fix is ordered: add
  the new edge, re-attach the docs (a doc may have several about refs), then remove
  the old one. The conflict's `next` gives these commands.
- Older binaries would delete attached items, so K1 raises `min_writer_version`
  (D32).

### Reading: docs appear where their item appears

The brief prints the map around the agent: the app card (section 4) and the
neighbours, one line per edge (section 5). Docs join those lines:
- under the app card: docs about the app;
- under each neighbour edge: docs about that edge, then docs about several edges
  crossing it;
- under a service edge: docs about the service;
- in section 9: docs about the task's topics.

A doc line is the slug, kind, summary line and a stale flag.

**Budget:** the brief trims later sections first, so doc lines in sections 4 and 5
could push out open tasks.
- **Hook and short mode:** a count per item only, e.g. `docs: 2 (silta doc ls --about
  edge:mobile/platform-api/http-api)`.
- **Full brief:** at most two doc lines per item, ranked by the task's edge and
  topics, and docs at most about 20% of the budget. The rest become a count.
- A golden fixture with many docs proves open tasks survive.

`silta doc show <slug> [--rev <n>]` prints a doc, bounded like `code show`. `silta
doc ls --about <ref>` lists the docs on an item, including pending proposals and
their comments, so any agent working there sees them and doesn't duplicate them.
`silta guide docs` teaches when to read, how to treat a stale doc, and when to
propose.

### Writing: agents propose docs and map changes

**Doc proposals:**
- `silta doc propose <slug> -F - -m "<why>" [--base <rev>] [--about <ref>]…
  [--title <t>] [--task <ref>]`. A new slug needs `--title` and at least one
  `--about`; every missing flag is listed in one `usage` error.
- **Source task:** `--task`, defaulting to the session's claimed task. The guide says
  to propose before `task done`, while the claim is held.
- **When:** after learning something another app's agent would need. The guide's
  test: "would an agent in another app waste time rediscovering this?" Task-local
  detail stays in the task result.
- **No duplicates:** first `doc ls --about` for the item; propose a revision of an
  existing doc where one fits.
- **Few:** one rule for every proposal type (tasks, docs, map): usually none, at most
  two per session. It stays guide text, as for tasks today.

**Map gaps.** Agents discover the map: that `sales` also calls `pdf-service`, or
that an edge summary is wrong. The map changes rarely, so this plan adds no new
mechanism for it:
- **Human present:** the agent shows the `ws edit -F` change in chat and, after a
  yes, runs it with `--approved` (D38).
- **Human absent:** the agent writes the gap under "What's left" in its handoff or
  result, as a line starting `Map gap:`, never a task or a file (D39).
- DF3 counts these lines and the chat changes for E5. Map proposals, an agent
  write that waits in the review batch, are built only if E5 shows gaps that
  waited on an absent human.

### Reviewing: one batch, one answer

- **Refs:** a proposal is `doc:<slug>@<rev>` (§5.1). `doc show --rev <n> --diff`
  shows the change.
- **The inbox** lists pending doc proposals grouped per doc, with the why, the source
  task and a diff summary. They leave the inbox 14 days after creation (D37).
- **The review loop, through an agent:**
  1. The human says "review the doc proposals".
  2. The agent reads each diff and checks it against the code. It merges overlapping
     proposals first by proposing a combined revision, so every recommendation names
     a proposal that exists.
  3. It sends one message: per proposal, accept or reject with one line of
     reasoning, plus the exact commands.
  4. The human answers once. The agent runs `silta doc triage --accept <refs>
     --reject <refs> --approved "<words>"`, one transactional command, like
     `task triage --accept/--drop`.
- **Batch semantics:** every proposal's base is checked against the state before the
  batch. Two proposals in one batch that change the same doc are refused with the
  overlap named; nothing is written. Then the batch applies all or nothing.
- **Stale base:** `stale_rev` names the proposal, and `next` is `doc show` and a
  rebased propose with `-F`. No `$EDITOR` step.

### Staying true

- A doc's verification records the actor, a message and the SHA of each app it refers
  to (a `doc_verification` row). Accepting a revision counts as verifying it.
- **In the brief, cheap:** a doc is stale when its verification is older than
  `stale_days`, or when a referenced app's ref has moved since that SHA. One
  `rev-parse` per app; hook mode shows only what the index cache (`index.db`, D8)
  already knows.
- **On demand, precise:** `doc show` and `doc verify` check each code ref, including
  the edge's own `code` refs. `silta doc verify <slug> -m "<what was checked>"`
  refuses while a ref doesn't resolve.

### Export and restore

Docs, their revisions and verifications join the export tree (§15). Restore no
longer refuses a workspace with docs; a tampered tree or a dangling about ref writes
nothing.

### Error contract

Every new refusal has a code and a `next`. Goldens cover each.

| Situation | Code | `next` |
|---|---|---|
| Missing flags on a new doc | `usage` | the command with all missing flags named |
| About ref doesn't resolve | `not_found` | `silta ws show` or `silta doc ls --about <app ref>` |
| Stale base | `stale_rev` | `silta doc show <slug>`, then `doc propose … --base <current>` |
| Overlap in one batch | `conflict` | the overlapping refs; merge and re-propose |
| Removing an item with docs | `conflict` | add-attach-remove commands naming each doc |

## Releases and slices

Each release is usable on its own. All migrations land in K1, because
`StorageSchema.swift` is shared.

| Release | Proves |
|---|---|
| **R1 Read** | Docs on the map change agent outcomes. Agents write docs with `doc edit -F --approved` while the human is in chat (D38). |
| **R2 Propose and review** | Agents capture knowledge without the human present, and one answer reviews it. |
| **R3 Freshness** | Stale docs are flagged, and agents check the code. |

| Slice | Release | Scope | Depends on | Verify with |
|---|---|---|---|---|
| K1 Store, refs, attachments | R1 | All migrations; `edge:` and `service:` refs, reserved slugs, identifier kinds; revision metadata; about links and removal conflicts for every map table; `doc_verification`; `min_writer_version` | — | Ref resolver tests; migration tests from the checked-in prior-schema DBs; `ws edit` conflict goldens |
| K2 Reads and human writes | R1 | `doc show [--rev] [--diff]`, `doc ls --about`; `doc edit -F` creating a doc when missing (human-only, `--approved`) | K1 | CLI goldens; bounds |
| K3 Brief placement | R1 | Doc lines in sections 4, 5 and 9; hook and short counts; budget share | K1 | Brief goldens, including the backlog-survives fixture; determinism |
| K4 Export and restore | R1 | Docs, revisions and verifications in the tree | K1 | Round trip; tampered and dangling-ref restores write nothing |
| K5 Doc proposals and batch review | R2 | `doc propose`, `--task` default, `doc triage --accept/--reject`, batch semantics, inbox group, D37 age-out; the `Map gap:` guide rule | K2 | Gate truth table; accept race; overlap and stale-base batches; `SILTA_NOW` age-out at 13/14/15 days; a §20.1 scenario YAML |
| K6 Freshness | R3 | Stale flags (age and moved app ref); per-ref checks in `doc show`/`verify`; index cache for the hook | K3 | `SILTA_NOW` at 89/90/91 days; fixtures with a moved file, a missing ref and a broken edge ref; a §20.1 scenario |
| K7 Guidance | R1–R3 | `silta guide docs` and the installed skill, extended per release | per release | Guide goldens; `GuideContractTests` |
| K8 Evals | R1–R3 | The scenarios below, stub-tested first, per release | per release | Stub matrix; live runs |

K2, K3 and K4 run in parallel after K1. Each slice must fit one reviewable PR (about
800 lines); a slice that grows splits before review.

## Validation

**Evals, outcome-graded, each with a control or a negative variant.** The fixture
self-checks that each grading token appears only where the scenario puts it.

- **`doc-context` (R1):** the mobile agent must handle unknown push categories. The
  rule is an unguessable token (fall back to `UNSORTED_Q7`) in the body of a doc
  attached to `edge:acme-mobile/acme-backend/http-api`, below the summary line, so
  `doc show` is needed. Pass: the recorded plan or result names the token. **Control:**
  the same task without the doc must fail in the stub; the live control pass rate is
  reported as a diagnostic.
- **`doc-context` stale variant (R3):** the code at the backend's ref contradicts the
  doc. Pass: the recorded value is the code's, with a proven `silta code` read and no
  `doc verify` stamping the wrong doc.
- **`doc-capture` (R2):** the backend task reveals a fact the mobile app depends on,
  carrying a unique token. Pass: one `doc propose` whose body has the token, attached
  to the right edge, with a source task, and no accepted revision. **Variants:** an
  existing doc on the edge, where a pass is a revision of that doc rather than a new
  slug; and a task-local fact, where a pass is zero proposals. A new repo markdown file
  holding the token fails.
- **`doc-review` (R2):** three pending proposals, one contradicting the code, in a
  varying position. The scripted operator replies "do what you recommend". Pass: the
  final state has the wrong one rejected, the other two accepted, in one `doc triage`
  command whose approval row carries those words. Whether the message reasoned well is
  a human `policy-semantics` check. The runner learns to bind an approval to a batch
  command.

Each new predicate enters `guarantees.json` with a planted fault, a failing recording
and a recorded review entry per variant.

**Human load (D37):** the dogfood report adds doc proposals, acceptance rate, time
to decision and approvals per batch.

**Unverified until DF3:** whether agents in a real workspace propose docs worth
keeping, and whether the human keeps reviewing them. DF3's decision rules gain one
for this, and E5 counts `Map gap:` lines to decide on map proposals.

## Risks

- **Wrong docs are worse than none.** The stale variant, `doc verify` refusals and DF3
  check-ins would show it. Mitigated by code refs instead of copies, and stale flags.
- **Review fatigue.** Acceptance rate and inbox age would show it. Mitigated by the
  proposal rule, batching and merged recommendations. A `direct` mode is deferred
  until DF3 shows the need.
- **Attachment friction.** Agents may attach to the wrong item. Reviews and DF3 would
  show it; `doc ls --about` before proposing and kind inference help.
- **Brief bloat.** The budget share and the backlog-survives golden catch it.
- **Agents ignore docs.** `doc-context` measures the outcome; metrics count `doc show`
  calls.

## Done when

- Per release, its evals pass live for Claude Code and Codex: `all_repeats_pass` over
  three repeats plus human `evidence_review`, with the controls and negative variants
  listed above.
- Every new command and refusal has goldens; `silta schema` matches §16; export
  round-trips docs and proposals.
- The dogfood report shows doc proposals and decisions.

Then move the lasting rules into spec §5.1, §6, §9, §12, §15 and Appendix A and into
`decisions.md`, split §22 M2 into this and a reviews milestone, and delete this file.

## Out of scope

- Reviews of task diffs, line comments, review requests and the review gate: their
  own plan after this one.
- Indexing external sources, `silta search` and `[[ref]]` parsing (M3).
- `agent_doc_writes: direct`, a changes digest and `doc revert`: until DF3 shows
  review fatigue. The setting stays at `propose`.
- Docs attached to environments; environment runbooks attach to their app.
- Map proposals (`ws propose`): deferred until DF3's E5 shows map gaps waiting on
  an absent human. The map changes through `ws edit` as today.
- The Mac app (M5), and importing existing repo docs.

## Decided in review

- **Map proposals deferred.** The Pragmatism reviewer recommended it: D38's `ws edit
  --approved` covers the human-present case, and the map changes rarely. The
  maintainer agreed after weighing concrete cases. Agents record gaps as `Map gap:`
  lines, and DF3's E5 decides.
- **Kinds:** keep four, optional and inferred.
- **Agent verify:** yes, with SHAs recorded.
- **Default mode:** `propose`; `direct` deferred.
- **§22:** changes when this ships.
- **R1 ships alone first.** The maintainer chose it: R1 is smaller and its
  `doc-context` eval tests the core claim. R2 starts only if that eval shows docs
  change agent outcomes; otherwise the proposal machinery isn't built.
