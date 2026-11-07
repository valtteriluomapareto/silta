#!/usr/bin/env python3
"""Plant independent unattended-eval faults; fake key/client only; always restore."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TEST = 'test_open_models.OpenModels.'
FAULTS = [
    ('key_echo_export', 'evals.py', "return value.replace(secret, '[REDACTED]')", 'return value',
     'test_fake_key_absent_from_shell_console_and_every_export', 'unexpectedly found'),
    ('key_in_agent_shell', 'evals.py', 'shell_environment_policy.exclude = ["FIREWORKS_API_KEY"]',
     'shell_environment_policy.exclude = ["UNRELATED"]',
     'test_fake_key_absent_from_shell_console_and_every_export', 'Key reached simulated agent shell'),
    ('key_in_setup_git', 'evals.py', "if k != 'FIREWORKS_API_KEY'", 'if True',
     'test_key_never_reaches_setup_or_git_and_errors_are_sanitized', 'unexpectedly found'),
    ('scripted_grant_provenance', 'evals.py', "'source': 'scripted-operator' if operator == 'scripted'",
     "'source': 'operator-stdin' if operator == 'scripted'",
     'test_scripted_grant_is_bound_and_cannot_impersonate_human', 'False is not true'),
    ('scripted_denial_provenance', 'evals.py', "'source': 'scripted-operator' if operator == 'scripted'",
     "'source': 'operator-stdin' if operator == 'scripted'",
     'test_scripted_denial_records_source_and_sends_no_approval', "'operator-stdin' != 'scripted-operator'"),
    ('unsolicited_scripted_reply', 'evals.py', "if command in '\\n'.join(previous['messages']) else ''", 'if True else \'\'',
     'test_scripted_denial_records_source_and_sends_no_approval', "'Add the Acme retry fix for later.' != ''"),
    ('unsolicited_reply_grading', 'evals.py', "and approval['command'] in '\\n'.join(phases[0]['messages'])", 'and True',
     'test_scripted_grant_is_bound_and_cannot_impersonate_human', 'True is not false'),
    ('inflight_token_cap', 'codex_usage.py', 'total is not None and total > self.limit', 'False',
     'test_usage_cap_kills_before_terminal_and_prevents_next_phase', "'timeout' != 'token-limit'"),
    ('trial_cumulative_tokens', 'codex_usage.py', 'self.spent += self.phase_tokens', 'self.spent = 0',
     'test_two_turn_cap_counts_native_usage_once_and_preserves_failure', "0 != 'token-limit'"),
    ('unattended_login_prompt', 'evals.py', "if not stub and provider != 'fireworks':", 'if not stub:',
     'test_fake_key_absent_from_shell_console_and_every_export', 'Unattended input prompt'),
    ('unattended_operator_prompt', 'evals.py', "if operator == 'scripted':", 'if False:',
     'test_scripted_grant_is_bound_and_cannot_impersonate_human', 'Unattended input prompt'),
]


def main():
    report = Path(sys.argv[1])
    report.parent.mkdir(parents=True, exist_ok=True)
    results = []
    for name, file, marker, replacement, test, expected in FAULTS:
        path = ROOT / file
        original = path.read_text()
        if original.count(marker) != 1:
            raise SystemExit('Non-unique mutation marker: ' + name)
        try:
            path.write_text(original.replace(marker, replacement))
            run = subprocess.run([sys.executable, '-B', '-m', 'unittest', TEST + test],
                                 cwd=ROOT / 'tests', text=True, capture_output=True)
            detected = run.returncode != 0 and expected in run.stderr
            results.append({'guarantee': name, 'detected': detected, 'exit': run.returncode})
            if not detected:
                print(run.stdout + run.stderr)
                raise SystemExit('Fault escaped or failed for another reason: ' + name)
        finally:
            path.write_text(original)
            report.write_text(json.dumps(results, indent=2) + '\n')
    print(f'Detected and restored {len(results)} unattended-eval faults')


if __name__ == '__main__':
    main()
