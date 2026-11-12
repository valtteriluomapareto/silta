# Workspace knowledge: docs and the workspace map, kept by agents

Status: proposed

## Goal

An agent in any repo of a workspace starts with the knowledge that matters for its
app and task: the workspace map (apps, edges, services, topics) and the docs
attached to it. When it learns something lasting, it proposes a doc change or a map
change. The human coordinates and reviews both in one batch; they never write,
search or maintain docs or configuration themselves.

## Operating model

This plan is designed around who does what. Every slice must keep this split.

| Role | Does | Never has to |
|---|---|---|
| **Agent** | Reads the docs the brief shows next to the map; proposes doc and map changes after learning something lasting; checks a stale doc against the code before relying on it; prepares one review batch for the human, merging overlapping proposals first | Ask the human what a doc says, or wait on a review to keep working |
| **Human** | Says "review the proposals" to an agent; answers one batched message; decides contested or cross-team knowledge | Run the CLI, write markdown or YAML, find duplicates, chase stale docs |
| **Silta** | Attaches every doc to a map item; shows docs where the item appears in the brief; gates and records writes (D5, D38); flags stale docs; keeps every revision | — |

Reading costs the human nothing. Writing costs them one batched answer (D37).

## Inputs

- Spec §2 goals 1–2, §5 and §5.1 (refs), §6 (`doc`, `doc_rev`, `link`,
  `comment.doc_rev_id`; `app`, `edge`, `service`, `topic`), §8 inbox, §9 docs, §11
  (human-only, `--approved`), §12 brief sections 4, 5 and 9 and its budget, §15
  export, §20 test tiers, §21 evals, §22 M2, Appendix A (`ws edit` YAML).
- D2, D5, D8, D30 (simplicity), D32 (`min_writer_version`), D37 (attention budget),
  D38 (human works through agents), D39 (settings), D44.
- [DF3 plan](df3-real-workspace.md): the real multi-repo trial where this is judged.
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

**Map proposals.** Agents discover the map: that mobile also calls the pdf-service,
that an edge summary is wrong. When the human is present, D38 already covers this:
the agent shows a `ws edit -F` change and runs it with `--approved`. Map proposals
cover the rest, so the change waits in the same batch as docs.
- `silta ws propose -F - -m "<why>" [--dry-run]` takes a **YAML fragment**: only the
  sections it changes. Omitted sections and rows are unchanged; removals are
  explicit. The output summarises the diff ("adds 1 edge, removes 0").
- A proposal is stored as **per-item operations** (add, update or remove by
  identity), each with the item's prior values as its base.
- Agents may propose edges, services, topics and aliases, and app summaries. Repos,
  app identity and refs, environments and settings stay human-only through `ws edit`;
  an attempt is refused, and `next` names the `ws edit` change to ask the human for.
- A doc proposal may name an item added by a pending map proposal from the same
  session; they must be accepted together.
- `ws edit` gains the same base check: it refuses a save whose items changed since
  it read them, closing today's lost-update window.

### Reviewing: one batch, one answer

- **Refs:** a doc proposal is `doc:<slug>@<rev>`; a map proposal is `map:<n>` (§5.1).
  `doc show --rev <n> --diff` and `ws show map:<n>` show the change.
- **The inbox** lists pending proposals grouped per item, with the why, the source
  task and a diff summary. They leave the inbox 14 days after creation (D37).
- **The review loop, through an agent:**
  1. The human says "review the proposals".
  2. The agent reads each diff and checks it against the code. It merges overlapping
     proposals first by proposing a combined revision, so every recommendation names
     a proposal that exists.
  3. It sends one message: per proposal, accept or reject with one line of
     reasoning, plus the exact commands.
  4. The human answers once. The agent runs `silta proposals --accept <refs> --reject
     <refs> --approved "<words>"`, one transactional command for docs and map
     together, like `task triage --accept/--drop`.
- **Batch semantics:** every proposal's base is checked against the state before the
  batch. Two proposals in one batch that change the same doc or map item are refused
  with the overlap named; nothing is written. Then the batch applies all or nothing.
- **Stale base:** `stale_rev` names the proposal, and `next` is `doc show` (or `ws
  show`) and a rebased propose with `-F`. No `$EDITOR` step.

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

Docs, their revisions and verifications, and pending map proposals join the export
tree (§15). Restore no longer refuses a workspace with docs; a tampered tree or a
dangling about ref writes nothing.

### Error contract

Every new refusal has a code and a `next`. Goldens cover each.

| Situation | Code | `next` |
|---|---|---|
| Missing flags on a new doc | `usage` | the command with all missing flags named |
| About ref doesn't resolve | `not_found` | `silta ws show` or `silta doc ls --about <app ref>` |
| Stale base | `stale_rev` | `silta doc show <slug>`, then `doc propose … --base <current>` |
| Overlap in one batch | `conflict` | the overlapping refs; merge and re-propose |
| Human-only map field in `ws propose` | `human_only` | the `ws edit` change to ask the human for |
| Removing an item with docs | `conflict` | add-attach-remove commands naming each doc |

## Releases and slices

Each release is usable on its own. Map proposals come third because docs prove the
core claim without them. All migrations land in K1, because `StorageSchema.swift` is
shared.

| Release | Proves |
|---|---|
| **R1 Read** | Docs on the map change agent outcomes. Agents write docs with `doc edit -F --approved` while the human is in chat (D38). |
| **R2 Propose and review** | Agents capture knowledge without the human present, and one answer reviews it. |
| **R3 Map proposals** | The map stays current through the same loop. |
| **R4 Freshness** | Stale docs are flagged, and agents check the code. |

| Slice | Release | Scope | Depends on | Verify with |
|---|---|---|---|---|
| K1 Store, refs, attachments | R1 | All migrations; `edge:` and `service:` refs, reserved slugs, identifier kinds; revision metadata; about links and removal conflicts for every map table; `doc_verification`; `map_rev` per item; `min_writer_version` | — | Ref resolver tests; migration tests from the checked-in prior-schema DBs; `ws edit` conflict goldens |
| K2 Reads and human writes | R1 | `doc show [--rev] [--diff]`, `doc ls --about`; `doc edit -F` creating a doc when missing (human-only, `--approved`) | K1 | CLI goldens; bounds |
| K3 Brief placement | R1 | Doc lines in sections 4, 5 and 9; hook and short counts; budget share | K1 | Brief goldens, including the backlog-survives fixture; determinism |
| K4 Export and restore | R1 | Docs, revisions, verifications, map proposals in the tree | K1 | Round trip; tampered and dangling-ref restores write nothing |
| K5 Doc proposals and batch review | R2 | `doc propose`, `--task` default, `proposals --accept/--reject`, batch semantics, inbox group, D37 age-out | K2 | Gate truth table; accept race; overlap and stale-base batches; `SILTA_NOW` age-out at 13/14/15 days; a §20.1 scenario YAML |
| K6 Map proposals | R3 | `ws propose` fragments and `--dry-run`; per-item operations; allowed sections; joint doc+map accept; `ws edit` base check | K5 | Scope refusals; per-item conflicts; a batch of two map proposals on different items succeeds |
| K7 Freshness | R4 | Stale flags (age and moved app ref); per-ref checks in `doc show`/`verify`; index cache for the hook | K3 | `SILTA_NOW` at 89/90/91 days; fixtures with a moved file, a missing ref and a broken edge ref; a §20.1 scenario |
| K8 Guidance | R1–R4 | `silta guide docs` and the installed skill, extended per release | per release | Guide goldens; `GuideContractTests` |
| K9 Evals | R1–R4 | The scenarios below, stub-tested first, per release | per release | Stub matrix; live runs |

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
- **`doc-context` stale variant (R4):** the code at the backend's ref contradicts the
  doc. Pass: the recorded value is the code's, with a proven `silta code` read and no
  `doc verify` stamping the wrong doc.
- **`doc-capture` (R2):** the backend task reveals a fact the mobile app depends on,
  carrying a unique token. Pass: one `doc propose` whose body has the token, attached
  to the right edge, with a source task, and no accepted revision. **Variants:** an
  existing doc on the edge, where a pass is a revision of that doc rather than a new
  slug; and a task-local fact, where a pass is zero proposals. A new repo markdown file
  holding the token fails.
- **`map-capture` (R3):** the map has the pdf-service app but no edge from mobile.
  Pass: one map proposal whose only operation adds an edge from `acme-mobile` to
  `pdf-service`, any kind. **Negative:** an incidental CDN call; pass is no edge.
- **`doc-review` (R2):** three pending proposals, one contradicting the code, in a
  varying position. The scripted operator replies "do what you recommend". Pass: the
  final state has the wrong one rejected, the other two accepted, in one `proposals`
  command whose approval row carries those words. Whether the message reasoned well is
  a human `policy-semantics` check. The runner learns to bind an approval to a batch
  command.

Each new predicate enters `guarantees.json` with a planted fault, a failing recording
and a recorded review entry per variant.

**Human load (D37):** the dogfood report adds proposals per type, acceptance rate,
time to decision and approvals per batch.

**Unverified until DF3:** whether agents in a real workspace propose docs and map
changes worth keeping, and whether the human keeps reviewing them. DF3's decision
rules gain one for this.

## Risks

- **Wrong docs are worse than none.** The stale variant, `doc verify` refusals and DF3
  check-ins would show it. Mitigated by code refs instead of copies, and stale flags.
- **Review fatigue.** Acceptance rate and inbox age would show it. Mitigated by the
  proposal rule, batching and merged recommendations. A `direct` mode is deferred
  until DF3 shows the need.
- **Attachment friction.** Agents may attach to the wrong item. Reviews and DF3 would
  show it; `doc ls --about` before proposing and kind inference help.
- **Map churn.** Agents propose edges for incidental calls. `map-capture`'s negative
  variant checks it.
- **Brief bloat.** The budget share and the backlog-survives golden catch it.
- **Agents ignore docs.** `doc-context` measures the outcome; metrics count `doc show`
  calls.

## Done when

- Per release, its evals pass live for Claude Code and Codex: `all_repeats_pass` over
  three repeats plus human `evidence_review`, with the controls and negative variants
  listed above.
- Every new command and refusal has goldens; `silta schema` matches §16; export
  round-trips docs and proposals.
- The dogfood report shows proposals and decisions per type.

Then move the lasting rules into spec §5.1, §6, §9, §12, §15 and Appendix A and into
`decisions.md`, split §22 M2 into this and a reviews milestone, and delete this file.

## Out of scope

- Reviews of task diffs, line comments, review requests and the review gate: their
  own plan after this one.
- Indexing external sources, `silta search` and `[[ref]]` parsing (M3).
- `agent_doc_writes: direct`, a changes digest and `doc revert`: until DF3 shows
  review fatigue. The setting stays at `propose`.
- Docs attached to environments; environment runbooks attach to their app.
- Agent proposals for repos, apps, refs, environments and settings.
- The Mac app (M5), and importing existing repo docs.

## Decided in review

The maintainer asked for map proposals, so they stay, as R3. The Pragmatism reviewer
recommended deferring them, because D38's `ws edit --approved` covers the
human-present case; the plan now says so and builds them after docs prove themselves.

Answers to the earlier open questions, from the reviewers:
- **Kinds:** keep four, optional and inferred.
- **Agent verify:** yes, with SHAs recorded.
- **Default mode:** `propose`; `direct` deferred.
- **App proposals:** no.
- **§22:** changes when this ships.

## Open questions for the human

1. **Release order:** R1 lets agents write docs only with your words in chat. Is that
   enough for a first release, or should R2 (proposals) ship with it?
2. **Map proposals as R3:** keep them in this plan, or defer them until DF3 shows how
   often the map changes?
