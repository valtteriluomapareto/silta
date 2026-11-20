## Summary

- What changed, and why
- Slice or issue: <!-- e.g. S4, or #12 -->

## Test-first evidence

<!-- Bug fix: the reproducing test and the commit or output where it failed
     (withKnownIssue). Feature: the acceptance tests written first.
     Otherwise: "n/a" plus the reason. -->

## Verification

- [ ] `scripts/run-guards.sh` (docs-only changes)
- [ ] `scripts/verify.sh quick`
- [ ] `scripts/verify.sh app` (Mac app and Xcode project changes)
- [ ] `scripts/verify.sh full` (storage, concurrency, location, agent-facing output)
- [ ] Evals (spec §21), if agent behaviour changed

**What remains unverified:** <!-- required: say what these checks don't prove -->

## Reviews

- [ ] Implementation reviewed by separate subagents, scaled as in `skills/persona-review`; every finding fixed or answered
- [ ] Plan reviewed (only for targets, dependencies, storage, migrations, concurrency, agent-facing output or shared mechanisms)
- [ ] Agent-experience review (only for guide text, `--json`, error codes, `brief`)

## Agent-facing contract

- [ ] No change
- [ ] Changed: golden files updated on purpose, and the commit says "Golden update: …"

## Documentation

- [ ] `docs/spec.md`
- [ ] `docs/decisions.md`
- [ ] Plan and board (`docs/plans/`, `docs/README.md`)
- [ ] `AGENTS.md` / `CONTRIBUTING.md`
- [ ] No documentation changes needed

<!-- For a slice tracked in Silta: the result as it should read once merged, ending
     with a "Friction: …" line (AGENTS.md, Dogfooding). Delete the section otherwise. -->
## Draft result
