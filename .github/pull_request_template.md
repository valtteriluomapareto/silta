## Summary

- What changed, and why
- Slice or issue: <!-- e.g. S4, or #12 -->

## Verification

- [ ] `scripts/run-guards.sh` (docs-only changes)
- [ ] `scripts/verify.sh quick`
- [ ] `scripts/verify.sh full` (storage, concurrency, location, agent-facing output)
- [ ] Evals (spec §21), if agent behaviour changed

**What remains unverified:** <!-- required: say what these checks don't prove -->

## Reviews

- [ ] Plan reviewed by Architect, Tester and Pragmatism (separate subagents)
- [ ] Implementation reviewed by the same reviewers; every finding fixed or answered
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
