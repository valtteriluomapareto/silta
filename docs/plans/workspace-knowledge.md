# Workspace knowledge: docs that agents read and write

Status: proposed

## Goal

An agent in any repo of a workspace starts with the knowledge that matters for its
app and task, including what other repos' agents learned. When it learns something
another agent will need, it leaves a proposed doc change. The human coordinates and
reviews in batches; they never write, search or maintain docs themselves.

## Operating model

This plan is designed around who does what. Every slice must keep this split.

| Role | Does | Never has to |
|---|---|---|
| **Agent** | Reads relevant docs from the brief; proposes changes after learning something lasting; keeps proposals small; checks a stale doc against the code before relying on it; prepares one review batch for the human when asked | Ask the human what a doc says, or wait on a review to keep working |
| **Human** | Says "review the docs" to an agent; answers one batched message; decides contested or cross-team knowledge | Run the CLI, write markdown, find duplicates, chase stale docs |
| **Silta** | Picks the docs relevant to an app and task within the brief's budget; gates and records writes (D5, D38); flags stale docs; keeps every revision | — |

Two consequences shape the design:
- **Reading costs the human nothing, writing costs a little.** The human spends
  attention only on accepting proposals, and only in one batch (D37).
- **A workspace can trade review for speed.** `agent_doc_writes: direct` (D39)
  accepts agent revisions at once. The human then sees a digest of changes instead
  of proposals, and can still revert.

## Inputs

- Spec §2 goals 1–2 ("docs live in the app"), §5 and §5.1 (doc refs), §6 (`doc`,
  `doc_rev`, `link`, and `comment.doc_rev_id`, already in the schema), §8 inbox,
  §9 docs, §12 brief section 9, §15 export, §22 M2.
- D2, D5, D8, D37 (attention budget), D38 (human works through agents), D39
  (`agent_doc_writes`, `stale_days`), D44.
- [DF3 plan](df3-real-workspace.md): the real multi-repo trial where this is judged.
- Spec §23 Q8 (code access): docs point at code through `silta code`, so both are
  measured together.

## Design

### What a doc is

- A short, workspace-level markdown document: slug, title, kind and body. Revisions
  are kept forever; `current_rev` is the accepted one.
- **Kinds:** `contract` (an interface between apps), `flow` (a path through several
  apps), `runbook` (how to do an operation) and `reference` (everything else).
  The kind changes only how the brief ranks and labels a doc.
- **About links:** each doc links to the apps and topics it is about. A `contract` or
  `flow` names every app it touches. A doc about nothing is workspace-wide.
- **A summary line:** the first line of the body, at most 120 characters. The brief
  shows it.
- **Point at code, don't copy it.** Code appears as refs
  (`platform-api:src/Push/Category.cs#L10-30`) at an app's ref, so `silta code
  show` gives the current text, and freshness checks can tell when a ref breaks.

### Reading: agents get docs without looking

- **Brief section 9** lists the docs relevant to where the agent is:
  - docs about the current app;
  - `contract` and `flow` docs touching the current app and a neighbouring app;
  - docs about the task's topics, and docs linked from the task;
  - workspace-wide docs, last.

  Each row is the slug, kind, summary line and a stale flag, within the brief budget.
  The rest appear as a count and a `more: silta doc ls --app <app>` line.
- `silta doc show <slug> [--section <heading>] [--rev <n>]` prints a doc or one
  section, bounded like `code show`. `doc ls [--app] [--topic] [--kind]` lists them.
- `silta guide docs`: when to read docs, how to treat a stale one, when to propose.

### Writing: agents propose, and say why

- `silta doc propose <slug> -F - -m "<why>" [--base <rev>]` writes a proposed
  revision. A new slug with `--title`, `--kind` and `--about` proposes a new doc.
- **When:** after learning something another repo's agent would need, typically at
  `task done` or a handoff. The guide gives the test: "would an agent in another app
  waste time rediscovering this?" Task-local detail stays in the task result.
- **Small and few:** one pending proposal per doc per agent session; a newer one
  supersedes it. At most two doc proposals per session, like task proposals (D37).
- **No duplicates:** before proposing a new doc, the agent runs `doc ls` for the app
  and proposes a section in an existing doc where one fits.
- **Provenance:** a proposal links to its source task (`source` link), so the human
  sees what work it came from.

### Reviewing: the human answers once

- **The inbox** lists pending doc proposals, grouped per doc: the why, the source
  task and a diff summary. Like task proposals, they leave the inbox after 14 days
  without a write (D37).
- **The review loop, through an agent:**
  1. The human says "review the doc proposals".
  2. The agent reads each diff, checks it against the code where it can, and sends one
     message: per proposal, a recommendation (accept, reject or merge) with one line of
     reasoning, plus the exact commands.
  3. The human answers once, e.g. "accept 1 and 3, reject 2".
  4. The agent runs one `silta doc accept doc:a@4 doc:b@2 --approved "<words>"` and
     one `doc reject`, all or nothing, like `task triage`.
- **Feedback:** a comment on a proposed revision (`doc:slug@4`) goes to the
  proposer's inbox; it revises with a new proposal.
- **Conflicts:** `doc accept` refuses a proposal whose `base_rev` is not current.
  The agent proposes a rebased revision with `-F`; there is no `$EDITOR` step.
- **Direct mode:** with `agent_doc_writes: direct`, `doc propose` is accepted at
  once. The inbox shows a "docs changed since you last looked" digest instead, and
  `doc revert <slug> <rev>` restores an earlier revision as a new one.

### Staying true

- A doc is **stale** when `verified_at` is older than `stale_days` (default 90), or
  when one of its code refs no longer resolves at the app's ref. The brief and
  `doc show` flag it; the guide says to check the code before relying on a stale doc.
- `silta doc verify <slug> -m "<what was checked>"`: an agent that checked a doc
  against the code stamps it. The stamp records the actor, the message and the SHAs
  of the apps it refers to. A doc whose code refs don't resolve cannot be stamped.
  Agents can verify; every stamp is visible in the doc's history.
- Accepted revisions are parsed for `[[ref]]` links (spec §9), so tasks, docs and
  code refs connect both ways.

### Export and restore

Docs join the export tree (`docs/<slug>.md` plus a revision log, spec §15), so
backups, diffs and restore cover them. Restore no longer refuses a workspace with
docs.

## Scope

- **In scope:** the design above, the docs evals, and the dogfood measures.
- **Out of scope:**
  - Reviews of task diffs, line comments, review requests and the review gate. They
    become their own plan after this one ships.
  - Indexing external sources (meeting notes, repo docs) and `silta search` (M3).
    This plan leaves the seam: brief relevance reads only owned docs.
  - The Mac app (M5). Batch review through an agent must stand on its own.
  - Importing existing docs from repos. An agent can propose them by hand.

## Slices

| Slice | Scope | Depends on | Verify with |
|---|---|---|---|
| K1 Doc store and reads | `doc ls`, `doc show` with `--section`/`--rev` and bounds; kinds, about links and summary line; human `doc new` and `doc edit -F`; export and restore with docs | — | CLI goldens, export round trip, restore of a tree with docs |
| K2 Proposals and batch review | `doc propose` (new and existing docs, supersede, two per session), `doc accept`/`reject` with several refs and `--approved`, base-rev refusal, comments on revisions, inbox group, 14-day age-out, `agent_doc_writes: direct` with digest and `doc revert` | K1 | Gate truth table; accept race test; approval rows; inbox goldens |
| K3 Brief relevance | Brief section 9: ranking by app, contract/flow neighbours, topics, task links; budget; `[[ref]]` link parsing on accept | K1 | Brief goldens per fixture; budget tests; determinism |
| K4 Freshness | `stale_days`, code-ref checks at the app ref, `doc verify` with message and SHAs, stale flags in brief and `doc show` | K1, K3 | Stale fixtures with a moved file and a missing ref |
| K5 Agent guidance | `silta guide docs`, the installed skill and instructions, the "would another app's agent need this?" rule, the review-batch recipe | K2, K3, K4 | Guide goldens; `GuideContractTests` |
| K6 Docs evals | The three scenarios below, in the eval runner, stub-tested first | K5 (scenarios can be drafted red from K1) | Stub matrix; live runs on Claude Code and Codex |

K2, K3 and K4 can run in parallel worktrees after K1. K2 owns the inbox changes and
K3 owns the brief, so they don't share files.

## Validation

**The evals, outcome-graded like the cross-repo trap:**
- **`doc-context` (read):** the mobile agent must handle unknown push categories. The
  rule (fall back to `GENERAL`, never drop the push) exists only in a workspace
  `contract` doc. Passing means the recorded plan or result follows the rule. A
  control run without the doc shows whether the doc made the difference.
- **`doc-capture` (write):** the backend agent's task makes it learn a fact the
  mobile app depends on. Passing means one `doc propose` naming the fact on a fitting
  doc, with a source link, and no accepted revision without approval.
- **`doc-review` (human present):** three pending proposals, one of them wrong against
  the code. Passing means one message to the human recommending to reject the wrong
  one, then a single accept and a single reject command with the human's words.
- A **stale variant** of `doc-context`: the doc's code ref no longer resolves.
  Passing means the agent checks the code and follows it.

**Human load (D37):** the dogfood report adds doc proposals, acceptance rate, time
to decision, and approvals per review batch.

**Unverified until DF3:** whether agents in a real multi-repo workspace propose docs
worth keeping, and whether the human keeps reviewing them. DF3's decision rules
should gain one for docs.

## Risks

- **Wrong docs are worse than none.** Agents trust what the brief shows. We'd notice
  through the stale variant eval, `doc verify` refusals and DF3 check-ins. Mitigated
  by code refs instead of copies, and stale flags.
- **Review fatigue.** Too many proposals and the human stops reviewing, and the docs
  rot. We'd notice through the acceptance rate and inbox age. Mitigated by the
  two-per-session cap, batching, and `direct` mode.
- **Duplicates and sprawl.** Many overlapping small docs. We'd notice similar titles
  per app in `doc ls`. The guide prefers sections in existing docs.
- **Brief bloat.** Relevance ranking pushes out task context. Brief goldens and budget
  tests catch it.
- **Agents ignore docs**, as they could ignore `silta code`. The `doc-context` eval
  measures the outcome, and metrics count `doc show` calls.

## Done when

- `doc-context` (with its stale variant), `doc-capture` and `doc-review` pass live for
  Claude Code and Codex, three repeats each.
- Every new command has goldens, `silta schema` matches §16, and export round-trips
  docs.
- The dogfood report shows doc proposals and decisions.

Then move the lasting rules into spec §9, §12 and §15 and into `decisions.md`, split
§22 M2 into this and a reviews milestone, and delete this file.

## Open questions for the human

1. **Kinds:** are `contract`, `flow`, `runbook` and `reference` the right four?
2. **Agent verify:** may agents stamp `doc verify`, or only propose that a doc is
   still true?
3. **Default mode:** should new workspaces default to `propose` (spec today) or
   `direct` with a digest?
4. **Order:** this plan replaces the docs half of M2 and comes before reviews. Should
   §22 change now, or when this plan ships?
