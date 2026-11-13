# Silta dogfood report

Since: 2023-11-14 (UTC, inclusive).
Until: 2023-11-30T00:00:00Z (UTC, report time).
Logs available from: 2023-11-14.
Untagged log lines: 2. Unreadable log lines: 0. Report calls excluded.

## Calls

| Command | Calls | Error rate | Common error codes | Usage errors | Max ms |
|---|---|---|---|---|---|
| silta task add | 3 | 66.7% | usage: 2 | 2 | 9 |
| silta task ls | 1 | 0% | - | 0 | 4 |
| silta task start | 3 | 100% | claimed: 3 | 0 | 30 |
| silta ws edit | 1 | 0% | - | 0 | 25 |

## Repeated failures

Consecutive failures within the selected silta stream; flag values are unavailable.

| Actor session | Command | Code | Calls |
|---|---|---|---|
| agent:claude:acme-b | silta task add | usage | 2 |
| agent:codex:acme-a | silta task start | claimed | 2 |

## Agent sessions

2 sessions; median 3.5 calls; maximum 4 calls.

## Warnings

| Code | Calls |
|---|---|
| secret_redacted | 1 |
| stale_context | 1 |

## Unused commands

- `silta agents install`
- `silta agents uninstall`
- `silta backup`
- `silta brief`
- `silta code grep`
- `silta code log`
- `silta code ls`
- `silta code show`
- `silta comment`
- `silta comment accept`
- `silta comment delete`
- `silta comment reopen`
- `silta comment resolve`
- `silta doc ls`
- `silta doc show`
- `silta doctor`
- `silta export`
- `silta guide`
- `silta inbox`
- `silta init`
- `silta repo fetch`
- `silta restore`
- `silta session check`
- `silta status`
- `silta task archive`
- `silta task block`
- `silta task done`
- `silta task drop`
- `silta task edit`
- `silta task from-plan`
- `silta task keep`
- `silta task link`
- `silta task plan`
- `silta task promote`
- `silta task show`
- `silta task submit`
- `silta task triage`
- `silta task unblock`
- `silta where`
- `silta ws ls`
- `silta ws show`
- `silta ws use`

## Friction in the silta workspace

- 2023-11-15 SI-1: Re-reading the Acme plan was awkward.

Done tasks without a Friction line: 1 (SI-13).

Open dogfood tasks:

- SI-4 todo: Acme command repair

## Human load

Approvals per ISO week by command:

| Week | Command | Approvals |
|---|---|---|
| 2023-W46 | other | 1 |
| 2023-W46 | silta task start | 2 |
| 2023-W46 | silta task triage | 1 |
| 2023-W46 | silta ws edit | 1 |
| 2023-W47 | silta task triage | 1 |
| 2023-W47 | silta ws edit | 1 |

Proposals accepted: 5; dropped: 1; left untriaged past 14 days: 1.
Oldest pending proposal: 14 days.
Triage wait: median 20159.5 min; maximum 30240 min.
Questions to @me: n/a (S11).
Inbox size and oldest item: n/a (S11).
Target: under 12 inbox items, none older than one week.
