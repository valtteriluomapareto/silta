# M1: daily use

Status: active

## Goal

Silta is usable every day:
- an agent in any registered repo gets a brief at session start
- it can read neighbouring apps' code
- it keeps its plan, questions and handoff on a task instead of in files

## Inputs

- Spec §6–§12, §15–§20 and the M1 row of §22.
- Decisions D1–D19.

## Scope

- **In scope:** everything listed for M1 in spec §22.
- **Out of scope:**
  - reviews and docs (M2)
  - indexing and search (M3)
  - tracker sync and importers (M4)
  - the app (M5)

## Slices

The waves show what can run in parallel: every slice in a wave depends only on
earlier waves. Shared files need coordination, and their owner is named:
- `Package.swift`: S1
- the migrations: S3
- the error-code table: S4

| Slice | Scope | Depends on | Verify with |
|---|---|---|---|
| **S1** Package skeleton | `Package.swift` (SiltaCore, silta, test targets; GRDB, ArgumentParser, Yams), `silta --version`, CI build and test steps active | — | `verify.sh quick` |
| **S2** Determinism seams | `Clock`, `IDGenerator` (ULID), `SiltaHome`, `GitRunner` protocol with a sanitized system implementation and a fake; `SILTA_NOW` / `SILTA_ID_SEED` (§20.1) | S1 | Unit tests; determinism guard |
| **S3** Storage | GRDB `DatabaseMigrator`, schema v1 (§6), `seq_counter`, `change_log`, `min_writer_version` check per write, daily `VACUUM INTO` backup | S1, S2 | Migration tests; stress test for seq allocation |
| **S4** Output contract | JSON envelope, error codes and exit codes (§16), stdout/stderr split, `silta schema`, golden-test harness | S1 | Golden tests |
| **S5** Actors and sessions | Actor detection matrix (§11), session ids, human-only policy | S2, S4 | Actor-matrix unit tests |
| **S6** Workspace config | `init --scan`, `ws edit` YAML with validation and "did you mean", `repo fetch` | S3, S4 | Golden tests on the fixture tree |
| **S7** Location | `where` (§7) with all edge cases; `scripts/make-fixtures.sh` builds the fixture repos | S2, S3, S6 | `where` matrix over the fixtures |
| **S8** Code access | `code show/grep/log/ls` with `@ref`, timeouts, fetch hints | S2, S6 | Fixture tests |
| **S9** Secret guard | Pinned regex set, allowlist, redact vs reject (§18), corpus | S4 | Corpus test: 0 misses on known secrets |
| **S10** Tasks | add/start/claim/plan/steps/from-plan/submit/done with result and sha/archive/triage/promote (§8) | S3, S5, S9 | Unit, golden and stress tests (one claimer) |
| **S11** Comments and inbox | Kinds, threads, batch resolve, accept, inbox query (§8.1) | S10 | Golden tests; inbox state tests |
| **S12** Brief and hook | `brief` sections 1–7, budgets, `--hook` mode (§12) | S7, S8, S10, S11 | Golden briefs on the fixtures |
| **S13** Agent integration | `agents install` (skill, CLAUDE/AGENTS blocks, SessionStart hook, Codex writable root), `silta guide` | S4, S12 | Golden install diffs; guide golden |
| **S14** Export, backup, restore | Manifest, byte-identical export, restore with `--dry-run` (§15) | S3, S10, S11 | Round-trip property test; tampered-tree tests |
| **S15** Doctor and logs | JSONL command log, `doctor [--fix]` (§19) | S3, S8 | Doctor green on a fresh DB, red on injected corruption |
| **S16** Scenarios and first evals | Scenario runner with evidence directory (§20.1); four evals: `start-cross-repo`, `plan-not-file`, `handoff-resume`, `done-with-result` (§21) | S12, S13 | The evals pass for Claude Code and Codex |

**Parallel waves:**

| Wave | Slices |
|---|---|
| 1 | S1 |
| 2 | S2, S4 |
| 3 | S3, S5, S9 |
| 4 | S6, S10 |
| 5 | S7, S8, S11, S14, S15 |
| 6 | S12 |
| 7 | S13 |
| 8 | S16 |

## Validation

- Every slice runs `scripts/verify.sh quick`.
- S3, S7, S10, S12 and S14 also run `full`.
- What M1 still won't prove: behaviour with models other than Claude and Codex, which
  comes in the M4 eval matrix.

## Risks

- **`where` heuristics misfire on real repos.** The fixtures mirror real promotion
  chains, and low confidence never guesses.
- **Hook latency.** `--hook` has a 1.5 s budget and never indexes or fetches.
- **Harness details not yet verified** (spec §23 Q5). Check them in S13 before
  relying on them.

## Done when

- The four S16 evals pass for Claude Code and Codex.
- The stress, `where` matrix, round-trip, migration and secret-corpus tests are green.

Then move the lasting rules to the spec and decisions, and delete this file.
