# Workspace knowledge: docs and the workspace map, kept by agents

Status: proposed

## Goal

An agent in any repo of a workspace starts with the knowledge that matters for its
app and task: the workspace map (apps, edges, services, environments, topics) and
the docs attached to it. When it learns something lasting, it proposes a doc change
or a map change. The human coordinates and reviews both in one batch; they never
write, search or maintain docs or configuration themselves.

## Operating model

This plan is designed around who does what. Every slice must keep this split.

| Role | Does | Never has to |
|---|---|---|
| **Agent** | Reads the docs the brief shows next to the map; proposes doc and map changes after learning something lasting; keeps proposals small; checks a stale doc against the code before relying on it; prepares one review batch for the human when asked | Ask the human what a doc says, or wait on a review to keep working |
| **Human** | Says "review the proposals" to an agent; answers one batched message; decides contested or cross-team knowledge | Run the CLI, write markdown or YAML, find duplicates, chase stale docs |
| **Silta** | Attaches every doc to a workspace item; shows docs where the item appears in the brief; gates and records writes (D5, D38); flags stale docs and broken code refs; keeps every revision | — |

Two consequences shape the design:
- **Reading costs the human nothing, writing costs a little.** The human spends
  attention only on accepting proposals, and only in one batch (D37).
- **A workspace can trade review for speed.** `agent_doc_writes: direct` (D39)
  accepts agent doc revisions at once. The human then sees a digest of changes and
  can revert. Map changes are always reviewed.

## Inputs

- Spec §2 goals 1–2 ("docs live in the app"), §5 and §5.1 (refs), §6 (`doc`,
  `doc_rev`, `link`, and `comment.doc_rev_id`, already in the schema; `app`,
  `edge`, `service`, `environment`, `topic`), §8 inbox, §9 docs, §12 brief sections
  4, 5 and 9, §15 export, §22 M2, Appendix A (`ws edit` YAML).
- D2, D5, D8, D37 (attention budget), D38 (human works through agents), D39
  (`agent_doc_writes`, `stale_days`), D44.
- [DF3 plan](df3-real-workspace.md): the real multi-repo trial where this is judged.
- Spec §23 Q8 (code access): docs and edges point at code through `silta code`, so
  all three are measured together.

## Design

### The map and the docs

The workspace configuration is the map: structured, small, and what Silta routes
by. Docs are the knowledge hung on the map. **A doc never stands alone: it is
attached to at least one workspace item**, and it appears wherever that item does.

| Map item | Ref | What its docs explain |
|---|---|---|
| App | `app:platform-api` | What the app is beyond its one-line summary: structure, conventions, gotchas |
| Edge | `edge:mobile>platform-api:http-api` | The interface: payloads, rules, versioning, error handling (`contract`) |
| Several edges | each edge it crosses | A path through several apps, e.g. push from API to device (`flow`) |
| Service | `service:push` | Setup, quirks, limits, where credentials live (`runbook`, `reference`) |
| Environment | `env:platform-api/test` | Deploying, releasing, test data (`runbook`) |
| Topic | `topic:messaging` | Cross-cutting domain knowledge (`reference`) |

**What goes where:**
- **The map** holds what Silta needs to route and resolve: identity, location,
  refs, who talks to whom, and one-line summaries.
- **Docs** hold explanations. A summary that grows past one line becomes a doc
  attached to the same item.
- **Repos' own docs** (README, AGENTS.md, `docs/`) stay in the repos (D2). A
  workspace doc links to them by code ref instead of copying them.

**Attachments are kept consistent:**
- `doc new` and `doc propose` for a new doc require at least one `--about <ref>`,
  and every ref must resolve to an existing item.
- A map change that would remove an item with attached docs is a conflict naming
  those docs. The fix is part of the same proposal: re-attach each doc, or archive
  it. Renaming is not supported in the map (Appendix A), so refs stay stable.
- Edge refs use the edge's identity (from, to, kind). A new ref form
  `edge:<from>><to>:<kind>` and `env:<app>/<name>` join §5.1; `service:` already
  exists in edges.

### What a doc is

- A short markdown document: slug, title, kind, about refs and body. Revisions are
  kept forever; `current_rev` is the accepted one.
- **Kinds:** `contract`, `flow`, `runbook` and `reference`, as in the table above.
  The kind changes only how the brief labels and ranks a doc.
- **A summary line:** the first line of the body, at most 120 characters. The brief
  shows it.
- **Point at code, don't copy it.** Code appears as refs
  (`platform-api:src/Push/Category.cs#L10-30`) at an app's ref, so `silta code
  show` gives the current text, and freshness checks can tell when a ref breaks.

### Reading: docs appear where their item appears

The brief already prints the map around the agent: the app card (section 4) and the
neighbours, one line per edge (section 5). Docs join those lines instead of forming
a separate list:
- under the app card: docs about the app, and about its environments;
- under each neighbour edge: docs about that edge, then `flow` docs crossing it;
- under a service edge: docs about the service;
- in section 9: docs about the task's topics and docs linked from the task.

Each doc line is the slug, kind, summary line and a stale flag, within the brief
budget; the rest appear as a count and a `more: silta doc ls --about <ref>` line.

- `silta doc show <slug> [--section <heading>] [--rev <n>]` prints a doc or one
  section, bounded like `code show`.
- `silta doc ls [--about <ref>] [--kind <kind>]` lists docs; `--about app:<slug>`
  includes the app's edges and environments.
- `silta guide docs`: when to read docs, how to treat a stale one, when to propose.

### Writing: agents propose docs and map changes

**Doc proposals:**
- `silta doc propose <slug> -F - -m "<why>" [--base <rev>]` writes a proposed
  revision. A new slug also needs `--title`, `--kind` and at least one `--about`.
- **When:** after learning something another app's agent would need, typically at
  `task done` or a handoff. The guide gives the test: "would an agent in another app
  waste time rediscovering this?" Task-local detail stays in the task result.
- **Small and few:** one pending proposal per doc per agent session; a newer one
  supersedes it. At most two doc proposals per session, like task proposals (D37).
- **No duplicates:** before proposing a new doc, the agent runs `doc ls --about` for
  the item and proposes a section in an existing doc where one fits.
- **Provenance:** a proposal links to its source task (`source` link), so the human
  sees what work it came from.

**Map proposals:** agents discover the map: that mobile also calls the pdf-service,
that the API gained a test environment, that an edge summary is wrong. Today that
knowledge can only go into a task comment, because `ws edit` is human-only.
- `silta ws propose -F - -m "<why>"` takes the same YAML as `ws edit`, validates it,
  and stores the difference against the current configuration as a proposal.
  `ws show` prints the YAML to start from.
- **Agents may propose** changes to edges, environments, services, topics and
  aliases, and to app summaries. Repos, app identity and refs, and settings stay
  human-only through `ws edit`, because they change routing and policy.
- A proposal that removes an item with attached docs must re-attach or archive them
  (above), so accepting it never leaves a doc unattached.
- The same per-session cap counts map and doc proposals together.

### Reviewing: one batch, one answer

- **The inbox** lists pending proposals grouped per item: doc proposals per doc, map
  proposals per changed item, each with the why, the source task and a diff
  summary. They leave the inbox after 14 days without a write (D37).
- **The review loop, through an agent:**
  1. The human says "review the proposals".
  2. The agent reads each diff, checks it against the code where it can, and sends one
     message: per proposal, a recommendation (accept, reject or merge) with one line of
     reasoning, plus the exact commands.
  3. The human answers once, e.g. "accept 1 and 3, reject 2".
  4. The agent runs one `silta doc accept …` / `ws accept …` and one reject command
     per type, each taking several refs, with `--approved "<words>"`, all or nothing,
     like `task triage`.
- **Feedback:** a comment on a proposed doc revision (`doc:slug@4`) goes to the
  proposer's inbox; it revises with a new proposal.
- **Conflicts:** an accept refuses a proposal whose base is no longer current (the
  doc's `base_rev`, or the map's revision). The agent proposes a rebased version with
  `-F`; there is no `$EDITOR` step.
- **Direct mode:** with `agent_doc_writes: direct`, `doc propose` is accepted at
  once. The inbox shows a "docs changed since you last looked" digest instead, and
  `doc revert <slug> <rev>` restores an earlier revision as a new one.

### Staying true

- A doc is **stale** when `verified_at` is older than `stale_days` (default 90), or
  when one of its code refs no longer resolves at the app's ref.
- **One check for the whole map:** the same code-ref check covers edge `code` refs,
  so a broken edge reference and a broken doc reference are flagged the same way, in
  the brief and in `doc show`.
- `silta doc verify <slug> -m "<what was checked>"`: an agent that checked a doc
  against the code stamps it. The stamp records the actor, the message and the SHAs
  of the apps it refers to. A doc whose code refs don't resolve cannot be stamped.
- Accepted revisions are parsed for `[[ref]]` links (spec §9), so tasks, docs, map
  items and code refs connect both ways.

### Export and restore

Docs join the export tree (`docs/<slug>.md` plus a revision log, spec §15), and map
proposals export with the workspace. Backups, diffs and restore cover them; restore
no longer refuses a workspace with docs.

## Scope

- **In scope:** the design above, the evals, and the dogfood measures.
- **Out of scope:**
  - Reviews of task diffs, line comments, review requests and the review gate. They
    become their own plan after this one ships.
  - Indexing external sources (meeting notes, repo docs) and `silta search` (M3).
    This plan leaves the seam: brief placement reads only owned docs and the map.
  - Agent proposals for repos, app identity and refs, and settings.
  - The Mac app (M5). Batch review through an agent must stand on its own.
  - Importing existing docs from repos. An agent can propose them by hand.

## Slices

| Slice | Scope | Depends on | Verify with |
|---|---|---|---|
| K1 Doc store, attachments and reads | `edge:` and `env:` refs; docs with kind, about refs (at least one, all resolving) and summary line; `doc ls --about`, `doc show` with `--section`/`--rev` and bounds; human `doc new` and `doc edit -F`; the map-removal conflict for attached docs in `ws edit`; export and restore with docs | — | CLI goldens; ref resolver tests; `ws edit` conflict tests; export round trip |
| K2 Doc proposals and batch review | `doc propose` (new and existing docs, supersede, session cap), `doc accept`/`reject` with several refs and `--approved`, base-rev refusal, comments on revisions, inbox grouping and age-out, `agent_doc_writes: direct` with digest and `doc revert` | K1 | Gate truth table; accept race test; approval rows; inbox goldens |
| K3 Brief placement | Doc lines under the app card, neighbour edges and service edges; topic and task-linked docs in section 9; budget; `[[ref]]` parsing on accept | K1 | Brief goldens per fixture; budget tests; determinism |
| K4 Freshness | `stale_days`; one code-ref check for doc refs and edge `code` refs; `doc verify` with message and SHAs; stale flags in brief and `doc show` | K1, K3 | Fixtures with a moved file, a missing ref and a broken edge ref |
| K5 Map proposals | `ws propose` for edges, environments, services, topics and app summaries; map revision as base; `ws accept`/`reject` with several refs; attached-doc handling; inbox entries in the same batch | K1, K2 | Validation and scope tests (a repo or ref change is refused); conflict tests; inbox goldens |
| K6 Agent guidance | `silta guide docs`, the installed skill and instructions, the "another app's agent" rule, the what-goes-where rule, the review-batch recipe | K2, K3, K4, K5 | Guide goldens; `GuideContractTests` |
| K7 Evals | The scenarios below, in the eval runner, stub-tested first | K6 (scenarios can be drafted red from K1) | Stub matrix; live runs on Claude Code and Codex |

K2, K3 and K4 can run in parallel worktrees after K1. K2 owns the inbox and K3 owns
the brief, so they don't share files. K5 extends K2's inbox grouping, so it follows
K2.

## Validation

**The evals, outcome-graded like the cross-repo trap:**
- **`doc-context` (read):** the mobile agent must handle unknown push categories. The
  rule (fall back to `GENERAL`, never drop the push) exists only in a `contract` doc
  attached to the `mobile>platform-api` edge. Passing means the recorded plan or
  result follows the rule. A control run without the doc shows whether the doc made
  the difference.
- **Stale variant of `doc-context`:** the doc's code ref no longer resolves. Passing
  means the agent checks the code and follows it.
- **`doc-capture` (write):** the backend agent's task makes it learn a fact the
  mobile app depends on. Passing means one `doc propose` naming the fact, attached to
  the right edge, with a source link, and no accepted revision without approval.
- **`map-capture` (write):** the task reveals that mobile calls the pdf-service,
  which the map lacks. Passing means one `ws propose` adding that edge, and no
  change to repos, refs or settings.
- **`doc-review` (human present):** three pending proposals, one wrong against the
  code. Passing means one message to the human recommending to reject the wrong
  one, then a single accept and a single reject command with the human's words.

**Human load (D37):** the dogfood report adds proposals per type, acceptance rate,
time to decision, and approvals per review batch.

**Unverified until DF3:** whether agents in a real multi-repo workspace propose docs
and map changes worth keeping, and whether the human keeps reviewing them. DF3's
decision rules should gain one for this.

## Risks

- **Wrong docs are worse than none.** Agents trust what the brief shows. We'd notice
  through the stale variant eval, `doc verify` refusals and DF3 check-ins.
  Mitigated by code refs instead of copies, and stale flags.
- **Review fatigue.** Too many proposals and the human stops reviewing, and docs and
  map rot. We'd notice through acceptance rate and inbox age. Mitigated by the
  session cap, batching, and `direct` mode for docs.
- **Attachment friction.** Requiring an item may push agents to attach docs to the
  wrong one. Reviews and DF3 would show it; the guide's what-goes-where rule and
  `doc ls --about` before proposing are the mitigations.
- **Map churn.** Agents propose edges for every incidental call. The guide limits map
  proposals to dependencies another app's agent must know; `map-capture` checks
  that a single, correct edge is proposed.
- **Brief bloat.** Doc lines under every edge push out task context. Brief goldens
  and budget tests catch it.
- **Agents ignore docs**, as they could ignore `silta code`. The `doc-context` eval
  measures the outcome, and metrics count `doc show` calls.

## Done when

- `doc-context` (with its stale variant), `doc-capture`, `map-capture` and
  `doc-review` pass live for Claude Code and Codex, three repeats each.
- Every new command has goldens, `silta schema` matches §16, and export round-trips
  docs and map proposals.
- The dogfood report shows proposals and decisions per type.

Then move the lasting rules into spec §5.1, §9, §12, §15 and Appendix A and into
`decisions.md`, split §22 M2 into this and a reviews milestone, and delete this file.

## Open questions for the human

1. **Kinds:** are `contract`, `flow`, `runbook` and `reference` the right four?
2. **Agent verify:** may agents stamp `doc verify`, or only propose that a doc is
   still true?
3. **Default mode:** should new workspaces default to `propose` (spec today) or
   `direct` with a digest for docs?
4. **Map proposal scope:** is "edges, environments, services, topics and app
   summaries" right, or should agents also propose new apps (a repo plus a ref)?
5. **Order:** this plan replaces the docs half of M2 and comes before reviews. Should
   §22 change now, or when this plan ships?
