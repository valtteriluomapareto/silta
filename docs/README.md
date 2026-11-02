# Documentation map

| Audience | Where |
|---|---|
| Agents working in this repo | [`../AGENTS.md`](../AGENTS.md) |
| Contributors (commands, workflow) | [`../CONTRIBUTING.md`](../CONTRIBUTING.md) |
| Product and technical design | [`spec.md`](spec.md) |
| Why things are the way they are | [`decisions.md`](decisions.md) |
| Plans and their lifecycle | [`plans/README.md`](plans/README.md) |
| Reviewing plans and implementations | [`../skills/persona-review/SKILL.md`](../skills/persona-review/SKILL.md) |

## What to update when behaviour changes

| You changed… | Also update |
|---|---|
| A command, flag, JSON shape, error code or exit code | `spec.md` §16, the golden tests, and `silta guide` text |
| The data model or a migration | `spec.md` §6, and add a new migration (never edit a shipped one) |
| A design choice or trade-off | `decisions.md`: a new D# entry, or a dated "↳ update" under the old one |
| Scope or order of work | The active plan and the board below |
| A guard | Its self-test in `scripts/tests/`, and the invariant list in `AGENTS.md` |

## Active plans

The board mirrors `docs/plans/` one-to-one; `scripts/run-guards.sh` checks this. When
a plan ships:
1. Move its lasting rules into `spec.md` or `decisions.md`.
2. Delete the plan file and its row. Git history is the record.

<!-- plans-board:start -->
| Plan | Status | Summary |
|---|---|---|
| [`plans/m1-daily-use.md`](plans/m1-daily-use.md) | active | M1 broken into slices with dependencies, for parallel agents |
<!-- plans-board:end -->
