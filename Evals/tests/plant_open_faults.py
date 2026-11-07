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
    ('inflight_token_cap', 'codex_usage.py', 'if total is not None and total > self.limit:', 'if False:',
     'test_usage_cap_kills_before_terminal_and_prevents_next_phase', "'timeout' != 'token-limit'"),
    ('trial_cumulative_tokens', 'codex_usage.py', 'self.terminal[self.thread] = max(self.terminal.get(self.thread, 0), self.current_terminal)',
     'self.terminal[self.thread] = 0',
     'test_fresh_handoff_token_budget_adds_distinct_threads', '15 != 30'),
    ('late_resume_identity', 'codex_usage.py', 'max(self.native.get(key, 0), terminal.get(key, 0))',
     'self.native.get(key, 0) + terminal.get(key, 0)',
     'REVIEW.test_late_cumulative_resume_usage_is_not_charged_twice', '45 != 30'),
    ('terminal_cumulative_usage', 'codex_usage.py',
     'terminal[self.thread] = max(terminal.get(self.thread, 0), self.current_terminal)',
     'terminal[self.thread] = terminal.get(self.thread, 0) + self.current_terminal',
     'REVIEW.test_terminal_usage_is_cumulative_across_resume_without_session_files', '45 != 30'),
    ('final_read_cap', 'codex_usage.py', 'if not failure and total is not None and total > self.limit:',
     'if False:', 'REVIEW.test_final_usage_observation_still_enforces_cap_and_retains_native_exit',
     "7 != 'token-limit'"),
    ('closed_pipe_exit', 'codex_usage.py', 'child.wait(timeout=max(0, deadline - time.monotonic()))',
     'pass', 'REVIEW.test_closed_pipes_do_not_kill_a_process_before_its_exit',
     "Expected 'killpg' to not have been called"),
    ('matrix_loses_exit_on_bad_report', 'open_matrix.py', 'except (OSError, ValueError):',
     'except OSError:', 'REVIEW.test_malformed_optional_report_never_loses_model_exit_or_later_models',
     'json.decoder.JSONDecodeError'),
    ('raw_config_comment_key', 'evals.py', 'config.write_text(FIREWORKS_CONFIG + config.read_text())',
     "config.write_text(FIREWORKS_CONFIG + config.read_text() + '# ' + key + '\\n')",
     'test_fake_key_absent_from_shell_console_and_every_export', 'Raw config contains fake key'),
    ('key_in_auxiliary_profile_file', 'evals.py', 'config.write_text(FIREWORKS_CONFIG + config.read_text())',
     "config.write_text(FIREWORKS_CONFIG + config.read_text()); (Path(env['HOME']) / 'leak.txt').write_text(key)",
     'test_fake_key_absent_from_shell_console_and_every_export', 'Fake key in written file'),
    ('cli_hidden_core_input', 'evals.py', "    secret = os.environ.get('FIREWORKS_API_KEY', '') if args.provider == 'fireworks' else ''",
     "    if args.live and args.core: input('Unexpected core prompt')\n    secret = os.environ.get('FIREWORKS_API_KEY', '') if args.provider == 'fireworks' else ''",
     'test_unattended_cli.UnattendedCLI.test_actual_matrix_core_pilot_has_no_input_and_exact_coverage',
     'Unattended CLI requested input'),
    ('cli_cap_forwarding', 'evals.py', 'args.operator, args.max_trial_tokens)', 'args.operator, None)',
     'test_unattended_cli.UnattendedCLI.test_actual_cli_low_cap_stops_before_present_second_phase',
     'CLI cap forwarding was lost'),
    ('cli_operator_forwarding', 'evals.py', 'args.operator, args.max_trial_tokens)', "'interactive', args.max_trial_tokens)",
     'test_unattended_cli.UnattendedCLI.test_actual_cli_scripted_grant_and_empty_denial',
     'Unattended CLI requested input'),
    ('audit_loses_tool_output', 'audit.py', "excerpt(output, locator + ' ' + retained)", "'<omitted>'",
     'test_audit_evidence.AuditEvidence.test_audit_exposes_outputs_full_state_order_and_intermediate_files',
     "'OPAQUE_PROGRAM_READ_BACKEND_SECRET_SENTINEL' not found"),
    ('audit_loses_state_rows', 'audit.py', "TABLES = ('tasks', 'plans', 'comments', 'approvals', 'events')", 'TABLES = ()',
     'test_audit_evidence.AuditEvidence.test_audit_exposes_outputs_full_state_order_and_intermediate_files',
     "'STORED_PLAN_BODY' not found"),
    ('audit_loses_intermediate_files', 'audit.py', "files(before.get('files', {}), state['files'],", 'files({}, {},',
     'test_audit_evidence.AuditEvidence.test_audit_exposes_outputs_full_state_order_and_intermediate_files',
     "'intermediate.txt' not found"),
    ('audit_invents_exit_success', 'audit.py', "item.get('exit_code', 'unknown')", "item.get('exit_code', 0)",
     'test_audit_evidence.AuditEvidence.test_missing_native_exit_is_unknown_instead_of_success',
     "Regex didn't match"),
    ('unbound_transcript_order', 'evals.py', "'transcript_sha256': hashlib.sha256(result['stdout'].encode()).hexdigest(),", '',
     'test_unattended_cli.UnattendedCLI.test_actual_matrix_core_pilot_has_no_input_and_exact_coverage',
     'Missing bound transcript hash'),
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
            qualified = test.replace('REVIEW.', 'test_open_review.OpenReview.')
            if '.' not in qualified:
                qualified = TEST + qualified
            run = subprocess.run([sys.executable, '-B', '-m', 'unittest', qualified],
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
