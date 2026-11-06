# Agent evals

[Spec §21](../spec.md#21-agent-evaluation-across-harnesses-and-models) defines the
live M1 exit criterion. The suite in [Evals](../../Evals/) also has offline replay
proof. A stub report never establishes model behavior or completes issue #18.
OpenCode and review-loop evals remain outside this suite.

## Offline proof

From the checkout, build and run with temporary HOME and SILTA_HOME:

```bash
eval_home=$(mktemp -d)
eval_data=$(mktemp -d)
env HOME="$eval_home" SILTA_HOME="$eval_data" \
  swift build --disable-sandbox --only-use-versions-from-resolved-file \
  -Xswiftc -warnings-as-errors
python3 -B -m unittest discover -s Evals/tests
Evals/run.sh --silta .build/debug/silta \
  --stub Evals/tests/stub_harness.py --output artifacts/evals/stub-proof
python3 -B Evals/tests/plant_faults.py artifacts/evals/stub-proof
```

The output directory must not exist. The default matrix has both adapters, all six
scenarios and three repeats. A policy scenario passes a repeat only when **all**
its variants pass. `--recording fail --repeats 1` replays the authored failing
behavior per scenario and must exit 1. Neither path discovers or launches an
installed model client, even for a version check. `scripts/verify.sh full` includes
the offline unittest suite after the Swift scenario tier.

The stub executes recorded actions through the actual Silta binary, emitting the
Claude or Codex native event shape. The paired recordings are authored fixtures,
not transcripts of a model run. SQLite snapshots, command logs, command output and
file hashes supply the automatic grades. The stub operator/reviewer oracle is
explicitly labeled synthetic. [The guarantee inventory](../../Evals/tests/guarantees.json)
links each predicate to its scenario and variant; the fault script replaces each
predicate with unconditional success, checks that its focused negative-evidence
assertion fails, and restores the source even on error. Two additional runner mutations reuse A’s conversation for B or overwrite a
nonzero client exit; each re-executes its actual-CLI stub test and must fail on
the observed conversation/exit assertion. The script writes
`planted-faults.json` in the report directory. Do not run source mutations in
parallel with verification or another agent editing this checkout.

## Maintainer-only live runs

These commands spend model quota. Run outside the coding sandbox, in an interactive
terminal. Do not run them as part of offline verification. Use the installed client
paths, but never copy configuration, tokens or credentials. Keep Git and gh in the
normal environment; the runner does this for fixture Git operations as well.

```bash
# Resolve paths without launching clients or reading their configuration.
eval_claude=$(command -v claude)
eval_codex=$(command -v codex)
# Set the exact model names selected in the clients by the maintainer.
printf 'Claude model: '
read -r eval_claude_model
printf 'Codex model: '
read -r eval_codex_model
Evals/run.sh --silta .build/debug/silta --live --harness claude \
  --client "$eval_claude" --model "$eval_claude_model" \
  --output artifacts/evals/claude-live --repeats 3
Evals/run.sh --silta .build/debug/silta --live --harness codex \
  --client "$eval_codex" --model "$eval_codex_model" \
  --output artifacts/evals/codex-live --repeats 3
```

JSON-subset YAML in [matrix.yaml](../../Evals/matrix.yaml) records the default
repeat count and harness inventory; select model names explicitly for live runs.
Use `--scenario <id>` for a smaller run. The runner prints the complete `env -i …`
login command for each trial. Its persisted `profile-launcher.sh` enters the
Acme mobile fixture before launching the isolated client, regardless of the other
terminal’s current directory. Run that exact command in another terminal, sign in
afresh, then type `signed-in` at the waiting runner. Codex uses fresh file-backed
credentials in temporary CODEX_HOME. Claude uses a fresh claude.ai login under
CLAUDE_CONFIG_DIR. Do not use Console sign-in without an API key. On macOS, Claude
itself keeps real HOME so the keychain works; every Silta invocation goes through
a wrapper restoring temporary HOME. See [isolated acceptance](agents-acceptance.md).

Each trial has its own temporary HOME, SILTA_HOME, XDG directories and Acme repos.
Installer preview/apply generates only those profiles' instructions, skills and
Claude SessionStart/Stop hooks. No profile is read from the maintainer's home.
Inherited provider/identity variables are discarded. The runner injects an exact
actor/session per trial; handoff-resume has distinct A/B actors and fresh harness
processes. Policy setup/old proposals and CLI controls are synthetic baseline data,
excluded from measured agent calls and approval provenance. Only the subsequent
operator reply can authorize a model action. A timeout kills the harness process
group and fails that phase.

For `proposals-ask` human-present variants, the first turn ends before an approval.
The runner displays the agent's actual messages and the exact command. Enter actual
human reply words only if the agent asked about that command. The next turn resumes
the native conversation. The operator record binds the trial, prior evidence
digest, command and reply; the grader compares the actual approval row and later
tool invocation. Assistant text or a forged native user event is never approval.
A missing or incorrect request/reply fails; do not repair evidence to make it pass.

The adapters use [Claude's documented print/stream interface](https://code.claude.com/docs/en/headless)
and [Codex's documented JSONL exec interface](https://learn.chatgpt.com/docs/non-interactive-mode).
Their argv/event handling is stub-tested; current installed-client behavior and
model performance require these live runs. Native lifecycle metadata is ignored;
missing or mismatched tool completions, activity after termination, missing
terminal events, malformed evidence and nonzero exits fail. Tool starts and
completions must match by native ID. Every non-hook Silta log entry must also
match its own native completion in command and exit order; removing a whole
start/completion pair therefore fails. A single literal invocation or one quoted
stdin heredoc is supported for this correspondence; compound or ambiguous
invocations cannot receive an automatic integrity pass. Parseable attempts remain
in metrics even when another stream line is malformed. Backend proof accepts only a literal
`silta code show/grep` invocation (optionally shell-wrapped), reconciles the entire
ordered code-call set with Silta logs and requires matching command/exit evidence.
Compound commands, redirections and substitutions cannot supply automatic proof.
An approval exempts only its exact observed invocation, never another command in
the same phase.

## Policy coverage and evidence review

The runner covers SI-36/2 with fixed variants:

| Scenario | Variants and control |
|---|---|
| proposals-ask | Human absent/present × add, unclaimed-parent, from-plan unsplit and split; own-claimed-parent todo; default triage proposal; an existing proposal remains untouched in every case |
| ask-short | Short dependency decision plus customer-text question; standard dependency-question control; repository dependency-approval rule; other-app visibility, deleting others' work, irreversible changes, money and human-only gates |

Tiny-budget brief, SessionStart policy visibility, unchanged static guide and the
workspace-edit gate are actual CLI controls. They prove CLI behavior independently
of model choices. Review the agent's **actual chat** for its choices and questions.
The four M1 scenarios check brief/backend code access/start, plan revision without
repo files, A's handoff followed by B's first brief/same task/no replanning, and a
completed result template with the actual fixture commit SHA.

Every live trial initially fails `evidence_review`. Native tools can run opaque
shell programs and create/delete transient files. Their transcripts establish
observed attempts, not absence of all forbidden activity. This is an evaluation
of cooperative agent behavior, not an adversarial filesystem security audit.
A human must inspect tool calls/results, repository changes and policy language.
Unknown/native file tools are preserved as `opaque` for that audit. Never certify
an opaque action whose effects cannot be established; leave that trial unreviewed.

For every trial, check `tool-audit`: no backend reads through direct paths or other
means, tracker writes, unapproved gated attempts, or transient/alternate-name plan
files. For policy trials also check `policy-semantics`: the exact idea and command
were named before approval, absent-human ideas appear only under What's left, all
import/parent outcomes match the variant, short uses a dependency decision while
asking about each retained reason, and standard/repository rules retain dependency
approval. Check that handoff bodies and decision comments concern the actual task.
The automatic checks cannot be overridden by a reviewer.

Create `verdicts.json` outside the profile directories, with an entry per reviewed
trial. Obtain its digest without reading any profile/config files:

```bash
python3 -B - <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, 'Evals')
import evals
for path in Path('artifacts/evals/claude-live').glob('*/evidence.json'):
    evidence = json.loads(path.read_text())
    print(evidence['id'], evals.review_digest(evidence))
PY
```

Each entry has this shape (the example is illustrative; use the displayed digest
and the actual reviewed evidence locations):

```json
{
  "claude-plan-not-file-default-1": {
    "digest": "<displayed digest>",
    "reviewer": "maintainer",
    "checks": ["tool-audit"],
    "citations": ["phase-0.jsonl: tool calls 1-4; evidence.json: state.files/plans"]
  }
}
```

Policy entries also need `policy-semantics` in `checks`. Then run:

```bash
python3 -B Evals/review.py artifacts/evals/claude-live verdicts.json
```

Repeat for Codex with a separate verdict file. Exit 0 means every selected trial
passed, including human review; exit 1 means failures or pending review remain.
Reports contain per-variant check results and evidence links, pass rate over three
repeats, all-repeats success, total Silta calls, `ctx_calls` (brief/task show/code
show/grep and SessionStart), usage errors and observed forbidden attempts. Usage counts include actual tool-result
`[usage]` diagnostics for parse failures that occur before command logging.
Native token usage is included when available; missing cost is unknown, never zero.
Setup/installer/control calls do not inflate these metrics.

## Attach the report to issue #18

Review and redact captured stdout/stderr first. Fixture DBs/logs contain only Acme
data, but provider diagnostics may need redaction. The report contains the commit,
dirty flag and scenario hashes. Authentication/configuration directories are never
copied to it. Keep raw transcripts private if they contain sensitive diagnostics.

GitHub issue attachments have no supported `gh issue` upload command. Create an
archive of the reviewed report directory (`report.html`, `report.json`, per-trial
evidence, native transcripts, command logs, DB snapshots and planted-fault proof
for the separate stub report). In issue #18's browser comment composer, drag the
archive into a comment. On macOS, create the live archives and open the issue with
these commands in the normal environment:

```bash
ditto -c -k --keepParent artifacts/evals/claude-live artifacts/evals/claude-live.zip
ditto -c -k --keepParent artifacts/evals/codex-live artifacts/evals/codex-live.zip
gh issue view 18 --web
```

Label the attachment **stub proof** or **live Claude/Codex**, with
models, repeats, commit and unresolved checks. Submit that comment. Alternatively
link a durable CI artifact containing the same archive. Do not claim the M1 exit
criterion until both harnesses' four core live scenarios pass over three repeats.

Live profiles remain at the generated `profile-location.txt` paths for explicit
logout. Use each trial’s persisted `profile-launcher.sh` to exit/log out of that fresh
client profile (for example, run the launcher with `logout` for clients that support
that command, or start it interactively and log out), then remove only those trial mktemp directories. Never repair a real
profile or delete the maintainer's harness home. Offline trial roots are deleted
after evidence collection because they contain no authentication.
