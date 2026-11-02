---
name: persona-review
description: Review a plan or an implementation in this repo with independent reviewer subagents (Architect, Tester, Pragmatism, plus Agent experience for agent-facing changes). Use before starting implementation of a slice or non-trivial change, and again before merging. Triggers - "review the plan", "review this", "persona review", "before merge".
---

# Persona review

Every plan and every implementation gets reviewed by **separate, independent
subagents**, one per persona (D16). One agent playing several personas doesn't
count. If subagents aren't available, say so in the PR, and don't present a
single-agent review as the real thing.

## When

- **Plan review:** before writing code for a slice or any non-trivial change.
- **Implementation review:** after `scripts/verify.sh` passes, before merging. Use
  the same personas as the plan review.

## Personas

| Persona | Looks at |
|---|---|
| **Architect** | Boundaries (SiltaCore stays UI- and CLI-free), data model and migrations, concurrency (`BEGIN IMMEDIATE`, claims, leases), consistency with the spec and the D# decisions, what will be hard to change later |
| **Tester** | Requirements that can't be tested, missing edge cases, failure and recovery paths, determinism (injected clock and ids, no wall-clock waits), which test tier covers what, what remains unverified. **Test-first evidence:** plan reviews check that the plan names the reproduction or acceptance tests; implementation reviews check that the reproduction really failed for the reported reason, and that goldens match the spec rather than the code |
| **Pragmatism** | **Over-engineering first:** abstractions, protocols, parameters, options and validation that no current test or caller needs; generality "for later slices"; configurability nobody asked for; defensive code for cases that can't happen; a hand-rolled mechanism where a simpler one or the platform would do. For each, name the simpler version and what it would cost. Then: scope against the slice, cheaper alternatives, what to cut or defer, and whether the change fits in one reviewable PR (about 800 lines or less) |
| **Agent experience** (only when the change touches `silta guide` text, `--json`, error codes, exit codes or `brief`) | Simulate an agent using the change step by step. Is every error actionable (code + `next` command)? Token cost? Could an agent loop, get stuck, or prefer writing a PLAN.md instead? |

## How to run it

1. **Write one shared brief.** Include:
   - what is being reviewed: the plan text, or the diff range (`git diff <base>..HEAD`)
   - the slice and the spec sections it implements
   - the relevant D# decisions
   - what you already know is out of scope

   Don't include your own conclusions, so the reviews aren't anchored to them.
2. **Start one subagent per persona in parallel.** Each gets the shared brief plus its
   persona row. The subagents are read-only and don't edit files.
3. **Ask each reviewer for:**
   - its top three issues
   - a findings table: severity (blocker / major / minor), file or spec section,
     issue, recommendation
   - a short "keep" list of what is sound
4. **Reconcile:**
   - Merge duplicate findings.
   - Note where reviewers disagree, and decide with a reason.
   - Fix every blocker and major finding, or answer it in writing.
5. **Record the outcome** in the PR description:
   - who reviewed
   - what changed because of the review
   - what was deliberately not changed, and why

   If a finding changes a decision, add a D# entry or a dated update to
   `docs/decisions.md`.

## Don't

- Don't let reviewers edit code. Investigation and review only.
- Don't re-run a review until it comes back clean. Fix the findings, then review the
  new diff once.
- Don't count "no findings" as a review unless each reviewer says what it checked.
