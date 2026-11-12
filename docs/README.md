# Documentation map

| Audience | Where |
|---|---|
| Agents working in this repo | [`../AGENTS.md`](../AGENTS.md) |
| New users: what Silta is, install | [`../README.md`](../README.md) |
| New users: install to first task in their workspace | [`getting-started.md`](getting-started.md) |
| Annotated app, repo and edge configuration | [`examples/acme-workspace.yaml`](examples/acme-workspace.yaml) |
| Contributors (toolchain, commands, workflow) | [`../CONTRIBUTING.md`](../CONTRIBUTING.md) |
| Contributors (product contract and technical design) | [`spec.md`](spec.md) |
| Why things are the way they are | [`decisions.md`](decisions.md) |
| How Swift code is written, and what each target and folder holds | [`coding-guidelines.md`](coding-guidelines.md) |
| Plans and their lifecycle | [`plans/README.md`](plans/README.md), [`plans/_template.md`](plans/_template.md) |
| Reviewing plans and implementations | [`../skills/persona-review/SKILL.md`](../skills/persona-review/SKILL.md) |
| Briefing another agent on a slice | [`agent-brief.md`](agent-brief.md) |
| Building Silta with Silta | [`dogfood/README.md`](dogfood/README.md) (below) |
| Pull requests and slice issues | [`../.github/pull_request_template.md`](../.github/pull_request_template.md), [`../.github/ISSUE_TEMPLATE/slice.yml`](../.github/ISSUE_TEMPLATE/slice.yml) |
| The agent manual, as agents read it | `silta guide`; its text is in `Sources/silta/Commands/GuideCommand.swift` (spec §11) |

## What to update when behaviour changes

| You changed… | Also update |
|---|---|
| A command, flag, JSON shape, error code or exit code | `spec.md` §16, the golden tests, and `silta guide` text; parity tests check the spec against code |
| A command, flag or user-visible behavior | Check `../README.md` and `getting-started.md` |
| Workspace configuration fields or shape | `getting-started.md`, `examples/acme-workspace.yaml`, and its CLI test |
| The data model or a migration | `spec.md` §6, and add a new migration (never edit a shipped one) |
| A design choice or trade-off | `decisions.md`: a new D# entry, or a dated "↳ update" under the old one |
| Scope or order of work | The active plan and the board below |
| A guard | Its self-test in `scripts/tests/`, the invariant list in `AGENTS.md`, and the `run-guards.sh` row in `CONTRIBUTING.md` |
| A script's arguments or environment | Its header comment |
| A target or a `SiltaCore` feature folder | The layout table in `coding-guidelines.md` §5 |
| The dogfooding stage | The stage line in `AGENTS.md` |

## Active plans

The board mirrors `docs/plans/` one-to-one; `scripts/run-guards.sh` checks this. When
a plan ships:
1. Move its lasting rules into `spec.md` or `decisions.md`.
2. Delete the plan file and its row. Git history is the record.

<!-- plans-board:start -->
| Plan | Status | Summary |
|---|---|---|
| [`plans/df3-real-workspace.md`](plans/df3-real-workspace.md) | proposed | Onboarding a real multi-repo workspace and measuring whether Silta helps |
| [`plans/m1-daily-use.md`](plans/m1-daily-use.md) | active | M1 broken into slices with dependencies, for parallel agents |
| [`plans/workspace-knowledge.md`](plans/workspace-knowledge.md) | proposed | Docs agents read from the brief and propose after work; the human reviews in batches |
<!-- plans-board:end -->

## Dogfooding

[Setup and daily workflow](dogfood/README.md), [workspace YAML](dogfood/workspace.yaml),
[isolated harness acceptance](dogfood/agents-acceptance.md),
[agent evals](dogfood/agent-evals.md) and
[reviewed reports](dogfood/reports/README.md). Setup was completed on 2026-11-04;
the current stage is in [`AGENTS.md`](../AGENTS.md#dogfooding).
