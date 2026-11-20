# Contributing

This covers setup, commands and the merge workflow. Agents should start with
[`AGENTS.md`](AGENTS.md); this file holds the details it links to.

## Toolchain

| Tool | Version | Where it's pinned |
|---|---|---|
| Xcode / Swift | Xcode 27.1 (Swift 6.4) | [`.xcode-version`](.xcode-version) |
| SwiftLint | 0.65.1 | [`scripts/ci/install-swift-tools.sh`](scripts/ci/install-swift-tools.sh) |
| swift-format | 603.0.0 | same |
| Python | system `python3` | guard scripts and offline agent-eval tooling |

CI selects exactly this Xcode (`scripts/ci/select-xcode.sh`) and installs the
SHA-checked tools. Use the same pinned tools locally; Homebrew's current versions
can produce different lint results. Use the
[development installer requirements](docs/getting-started.md#1-requirements).
On arm64 with Command Line Tools, install the pinned tools as follows:

```sh
silta_tools=$(mktemp -d)
: > "$silta_tools/path"
RUNNER_TEMP="$silta_tools" GITHUB_PATH="$silta_tools/path" bash scripts/ci/install-swift-tools.sh
export PATH="$(paste -sd: "$silta_tools/path"):$PATH"
```

## Commands

| Command | What it does | What it doesn't prove |
|---|---|---|
| `scripts/run-guards.sh` | Guard self-tests, then the repository guards: app boundary, control release, app pins, core boundary, determinism, test waits, plan references, core hygiene, `try?` reasons, coded errors, package features, package graph, docs links, plans board | That the code builds or behaves |
| `python3 -B -m unittest discover -s scripts/tests` | Guard self-tests: each guard passes a clean tree and fails a planted violation | — |
| `scripts/lint-check.sh` | swift-format and SwiftLint in `--strict` mode, no changes | Behaviour |
| `scripts/lint-fix.sh` | Apply swift-format and SwiftLint fixes | — |
| `scripts/verify.sh quick` | Guards, lint, `swift build` with warnings as errors, `swift test` (a run with zero tests fails) | Concurrency under load, wall-clock deadlines, real agent use |
| `scripts/verify.sh full` | `full-swift`, `evals`, then `app`: everything CI runs | Real agent use (spec §21 evals) |
| `scripts/verify.sh full-swift` | `quick` plus stress/scenarios and the prior-writer compatibility tests (`SILTA_SLOW_TESTS=1`), then the wall-clock deadline tier (`SILTA_DEADLINE_TESTS=1`, the `WallClock…` suites: hook, Git and `where` lock deadlines) alone and serially | The offline eval replays |
| `scripts/verify.sh app` | Guards/lint, isolated hosted Debug app tests, nonempty/no-skip required-suite xcresult checks, then native Release build | Visual appearance, interaction and Screen Recording permission |
| `scripts/verify.sh evals` | Builds the CLI, then the offline agent eval replays (`scripts/run-eval-tests.py`: one process per `Evals/tests` module, in parallel) | Swift tests, real agent use |

`full-swift` bounds parallel test cases using the pinned Swift Testing runner.
Concurrency and stress tests still create their own concurrent work; their assertions
and timeouts are unchanged. The wall-clock tier runs separately and serially.

CI runs `full-swift`, `evals` and `app` as three parallel jobs on the `xcode-27` runner, and a
`verify` job, the required check, passes only when all succeed. Three macOS jobs per run
also means three chances to wait for a preview runner. The `swift` job reuses the prior-writer
binaries from the Actions cache, keyed by `scripts/ci/prior-writer-cache-key.sh` on the
Swift toolchain and `scripts/build-prior-writer.sh`; the weekly scheduled run builds them
from source. A push to `main` runs only `warm-caches`, which fills that cache in `main`'s
scope where every PR can read it; it verifies nothing, because the PR already verified the
same tree. That holds only while the `main` ruleset has no bypass actors; if one is added,
restore the full push run (D19).

Each script's header comment says how to run it. What each target and folder holds is
in [coding guidelines §5](docs/coding-guidelines.md#5-layout-and-naming-d25).

## Workflow

1. **Issue or slice.** Work starts from a slice in the active plan, or from a GitHub
   issue that names one.
2. **Plan.** Follow the [workflow](AGENTS.md#workflow) and the current
   [dogfooding stage](AGENTS.md#dogfooding) for where to record a plan.
3. **Plan review.** Use the [workflow](AGENTS.md#workflow) to determine when review
   is required and the [persona table](skills/persona-review/SKILL.md#who) to find
   the independent reviewers for the change.
4. **Tests first**, following the
   [test-first flow](docs/coding-guidelines.md#test-first-flow).
   - A bug fix starts with a committed reproduction that fails for the reported
     reason (`withKnownIssue`).
   - A feature starts from its acceptance tests.
   - A PR labelled `bug` must change a test; CI checks this.
5. **Implementation review.** Follow [AGENTS.md](AGENTS.md#reviews) for
   reviewer selection and follow-up.
6. **Merge** on green CI for the current head. Use squash merges titled
   `<slice or #issue> <type>: summary`, e.g. `S4 feat: JSON envelope and exit codes`.
   `main` is protected (D19): the branch must be up to date with `main`, so rebase or
   merge `main` in when GitHub asks. `gh pr merge --auto --squash` queues the merge for
   when CI passes. The [dogfooding workflow](AGENTS.md#dogfooding) covers task
   submission and the steps after a merge.

## Branches and commits

- **Branches:** `<agent>/<slice>-<slug>`, e.g. `claude/s7-where`, `codex/s8-code-show`,
  or `docs/<slug>` for documentation.
- **Commits:**
  - imperative, sentence case, under ~72 characters, e.g. "Add JSON envelope for
    errors"
  - a body that explains why when it isn't obvious
  - the `Co-Authored-By` trailer for agent-written commits
- **Golden output:** a change to golden files (guide text, JSON, error messages) says
  so in the commit body: "Golden update: …".

## Definition of done

- [ ] `scripts/verify.sh quick` passes, or `full` for storage, concurrency, location
      and agent-facing changes.
- [ ] New behaviour has tests written first; a bug fix has a reproduction that failed first
      (PR field "Test-first evidence").
- [ ] Spec, decisions and plan board are updated when behaviour or scope changed.
- [ ] Agent-facing changes have updated goldens and an agent-experience review.
- [ ] The PR says what remains unverified.

Native app tests require an isolated temporary home before the host starts. Use
`scripts/verify.sh app`; it supplies `SILTA_APP_TEST_HOME` and keeps xcresult evidence
under `.build/app/`. For manual Xcode tests, configure `SILTA_APP_TEST_HOME` to an
existing temporary directory containing a `user/` directory, and
`SILTA_APP_TEST_CLI` to the same checkout’s built `.build/debug/silta`. Missing or unexpanded
settings refuse startup before a reader can be constructed. App and root shared
package pins must match; the app never links test support.

To open the Debug Mac app against a fresh private Acme fixture, run
`scripts/run-mac-fixture.sh` (or `--no-build` after a successful Debug build).
The app seeds an absent temporary data home and freezes the fixture clock.
Closing the app leaves that temporary fixture available for copied CLI commands.
No product view executes those commands.
