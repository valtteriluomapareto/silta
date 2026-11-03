# M1: daily use

Status: active · tracking issue [#1](https://github.com/valtteriluomapareto/silta/issues/1)

## Goal

Silta is usable every day:
- an agent in any registered repo gets a brief at session start
- it can read neighbouring apps' code
- it keeps its plan, questions and handoff on a task instead of in files

## Inputs

- Spec §6–§12, §15–§20.1 and the M1 row of §22.
- Decisions D1–D20.

## Scope

- **In scope:** everything listed for M1 in spec §22.
- **Out of scope:**
  - reviews and docs (M2)
  - indexing and search (M3)
  - tracker sync and importers (M4)
  - the app (M5)

## Slices

**Where things live:**
- **The issues** hold each slice's scope, out-of-scope and acceptance.
- **This plan** holds the dependency graph and the reasoning.
- **GitHub** records the same dependencies as "blocked by" links, and the slices are
  sub-issues of #1.

**How to work a slice:** pick any open slice whose blockers are closed. Then post its
plan on the issue and get it reviewed (`skills/persona-review`) before coding.

**Shared files** need coordination, and their owner is named:
- `Package.swift`: S1
- the migrations: S3
- the error-code table (`ErrorCode`) and the `CodedError` registry in
  `ErrorReachabilityTests`: S4; later slices append their error types and take their
  codes off `notYetProduced`
- `GlobalOptions` and `CommandContext`: S4. CP adds `--deterministic` and
  `--verbose`, puts S2's `SiltaEnvironment` into `CommandContext`, and writes the
  §19 log line from the runner's `Rendered`.

| Slice | Issue | Depends on | Wave | Dogfooding |
|---|---|---|---|---|
| S1 Package skeleton | [#2](https://github.com/valtteriluomapareto/silta/issues/2) | — | 1 | |
| S2 Determinism seams | [#3](https://github.com/valtteriluomapareto/silta/issues/3) | S1 | 2 | |
| S4 Output contract and `silta schema` | [#4](https://github.com/valtteriluomapareto/silta/issues/4) | S1 | 2 | |
| S3 Storage | [#5](https://github.com/valtteriluomapareto/silta/issues/5) | S1, S2 | 3 | |
| CP Control plane: scenario runner and fixtures | [#6](https://github.com/valtteriluomapareto/silta/issues/6) | S2, S4 | 3 | |
| S5 Actors and sessions | [#7](https://github.com/valtteriluomapareto/silta/issues/7) | S2, S4 | 3 | |
| S9 Secret guard | [#8](https://github.com/valtteriluomapareto/silta/issues/8) | S4 | 3 | |
| S6 Workspace config | [#9](https://github.com/valtteriluomapareto/silta/issues/9) | S3, S4 | 4 | |
| S10 Tasks | [#10](https://github.com/valtteriluomapareto/silta/issues/10) | S3, S5, S9 | 4 | Adds binary-driven20 writers ×200 adds; S3 covers20 GRDB connections/threads |
| S7 Location | [#11](https://github.com/valtteriluomapareto/silta/issues/11) | S2, S3, S6, CP | 5 | built with Silta |
| S8 Code access | [#12](https://github.com/valtteriluomapareto/silta/issues/12) | S2, S6, CP | 5 | built with Silta |
| S11 Comments and inbox | [#13](https://github.com/valtteriluomapareto/silta/issues/13) | S10 | 5 | unlocks DF1 |
| DF Dogfood setup | [#19](https://github.com/valtteriluomapareto/silta/issues/19) | S6, S10 | 5 | **starts DF0**: Silta tracks its own work |
| S14 Export, backup, restore | [#14](https://github.com/valtteriluomapareto/silta/issues/14) | S3, S10, S11 | 6 | built with Silta |
| S15 Doctor and logs | [#15](https://github.com/valtteriluomapareto/silta/issues/15) | S3, S8 | 6 | built with Silta |
| S12 Brief and hook | [#16](https://github.com/valtteriluomapareto/silta/issues/16) | S7, S8, S10, S11 | 6 | unlocks DF2 with S13 |
| S13 Agent integration | [#17](https://github.com/valtteriluomapareto/silta/issues/17) | S4, S12 | 7 | unlocks DF2 with S12 |
| S16 First agent evals | [#18](https://github.com/valtteriluomapareto/silta/issues/18) | S12, S13, CP | 8 | built with Silta |

**Workspace settings (D39)** land with the slices that use them:
- S11: the typed settings value and `proposals`. This touches task creation and
  `from-plan`, not only the inbox.
- S12: the brief's settings line.
- S13: the guide sentences, `ask_about`, and the `proposals-ask` and `ask-short`
  eval scenarios.
- S14: restore validates the settings.

**Why the control plane (CP) comes early.** CP is the scenario runner and the
fixture repos. Together with the seams (S2) and the output contract (S4), it lets
every later slice prove itself from the command line (spec §20.1). So from wave 5
on, "has scenarios" is part of each slice's acceptance, rather than something added
at the end. S16 then only adds real agents on top.

## Dogfooding

Spec §22.1, D20. Silta is used to build Silta from **DF0** on, which starts when DF
(#19) lands. That's after waves 4–5, so roughly half of M1 (S7, S8, S11–S16) is
built with Silta.

| Stage | Starts after | Used for |
|---|---|---|
| DF0 | S6, S10, DF | Tasks, plans, steps and results for the remaining slices |
| DF1 | S11 | Questions and handoffs between sessions |
| DF2 | S12, S13 | Every session starts with `silta brief` through the hook |
| DF3 | M1 done | A second, multi-repo workspace |

At the end of each wave, review the tasks with topic `dogfood`. Each becomes a
GitHub issue (label `dogfood`), a `silta guide` text fix, or nothing.

## Validation

- Every slice runs `scripts/verify.sh quick`.
- S3, CP, S7, S10, S12 and S14 also run `full`.
- What M1 still won't prove: behaviour with models other than Claude and Codex, which
  comes in the M4 eval matrix.

## Risks

- **`where` heuristics misfire on real repos.** The fixtures mirror real promotion
  chains, and low confidence never guesses.
- **Hook latency.** `--hook` has a 1.5 s budget and never indexes or fetches.
- **Harness details not yet verified** (spec §23 Q5). S13 verifies them first.

## Done when

- S16's four evals pass for Claude Code and Codex.
- The stress, `where` matrix, round-trip, migration and secret-corpus tests are green.

Then move the lasting rules to the spec and decisions, delete this file, and close #1.
