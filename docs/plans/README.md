# Plans

A plan describes work that spans more than one session or more than one agent. Small
changes don't need a plan file; a few lines in the issue or PR are enough.

## Rules

- **Name plans after the feature or outcome**, e.g. `m1-daily-use.md` or
  `review-loop.md`. Don't use dates, phase numbers or words like "final".
- **Start from [`_template.md`](_template.md).** Keep the `Status:` line current:
  `proposed`, `active` or `blocked`.
- **Register every plan on the board** in [`../README.md`](../README.md#active-plans),
  in the same change that adds the file. `scripts/run-guards.sh` fails if the board
  and this folder disagree.
- **Slices:** a plan that several agents will work on lists slices with their
  dependencies, so independent slices can run in parallel worktrees.
- **When a plan ships:**
  - Move what should last into `spec.md` (behaviour) or `decisions.md` (choices and
    trade-offs).
  - Delete the plan and its board row in the same change. Git history keeps the
    record, so there are no archive folders and no development diaries.
- **Plans don't belong in code comments** (AGENTS.md invariant 4).
