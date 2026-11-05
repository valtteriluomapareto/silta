# Briefing an agent on a slice

Use this when you hand a slice to another agent (Codex, a Claude session, a
subagent). The repo's rules already live in `AGENTS.md` and the coding guidelines, so
the brief only adds what they can't know: what "done" is, what other slices are doing
right now, and where to stop.

Copy the block, fill in the `<…>`, and delete lines that don't apply.

```text
Work slice <Sn> "<title>" (GitHub issue #<n>, Silta task <SI-n>) in this repo.

Read AGENTS.md first; it is the single source of truth. Then read issue #<n>,
docs/coding-guidelines.md (especially §9 Simplicity), and <spec sections, D#>.

Done means: the issue's acceptance items pass as tests. Write only the code those
tests and the spec need. When the spec or issue doesn't decide something, pick the
simplest option and say so in the PR; don't build options for both.

Size: aim for about <500> lines of source and tests. If you'll go past <800>, stop
and say why before continuing.

Style: match <an existing file, e.g. Sources/SiltaCore/Output/OutputRouter.swift>:
`///` on every package member, no one-line declarations, errors conform to
CodedError.

What other slices are doing now:
- <e.g. S4 has landed: errors conform to CodedError and go in the
  ErrorReachabilityTests registry>
- <e.g. S7 is in progress in another agent; don't touch Sources/SiltaCore/Location/>
- Shared files and their owners are listed in docs/plans/m1-daily-use.md; don't edit
  one you don't own without saying so first.

Setup: install the pinned lint tools (Homebrew's versions differ from CI's):
  T=$(mktemp -d); : > "$T/path"
  RUNNER_TEMP="$T" GITHUB_PATH="$T/path" bash scripts/ci/install-swift-tools.sh
  export PATH="$(paste -sd: "$T/path"):$PATH"

Steps:
1. Record your plan where AGENTS.md's current dogfooding stage requires it,
   including the out-of-scope work, then get it reviewed before coding. Proceed
   with authorized work; stop and name any decision that needs the maintainer.
2. Tests first (coding guidelines, "Test-first flow"). For every safety rule in the
   slice (isolation, limits, refusals), plant a fault once and show its test fails.
   Subprocess and timeout tests get `.timeLimit`.
3. Branch <agent>/<slice>-<slug>. `scripts/verify.sh quick` (or `full` for storage,
   concurrency, location or agent-facing output) must pass.
4. Open one PR using .github/pull_request_template.md. Add this table:
   | Rule | Followed? | Evidence |
   with one row each for: acceptance tests, §9 Simplicity, CodedError, doc comments,
   test-first and planted faults, size budget, shared files.
5. You may push the branch and open the PR, then run `task submit` as AGENTS.md's
   dogfooding stage says. Don't merge it.
```

After the plan comes back, review it with the persona review (the Pragmatism persona
looks for over-engineering first) and reply "go" or with changes.
