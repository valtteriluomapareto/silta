#!/usr/bin/env python3
"""Mutate one isolation guarantee at a time; only explicit fake clients execute."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SHARED = 'test_one_signin_and_fresh_data_hooks_config_grants_per_trial'
FAILURE = 'test_cleanup_conflict_and_unknown_state_abort_future_trials'
FAULTS = [
    ('missing_signin', 'evals.py', '            profile.sign_in()', '            pass', SHARED, 'Sign-in must be run-scoped'),
    ('per_trial_signin', 'evals.py', "    root = Path(tempfile.mkdtemp(prefix='silta-eval-')).resolve()",
     "    profile.sign_in()\n    root = Path(tempfile.mkdtemp(prefix='silta-eval-')).resolve()", SHARED, 'Sign-in must be run-scoped'),
    ('confirmation_without_login_completion', 'profiles.py', " or not self.marker.is_file()", '',
     'test_missing_confirmation_or_marker_aborts_before_any_trial', 'Trial launched without login confirmation'),
    ('retained_silta_data_and_hook_log', 'profiles.py', '                shutil.rmtree(root)', '                pass',
     SHARED, 'Previous trial data, hooks, history or config survives'),
    ('retained_native_history', 'profiles.py', '        for path in disposable:', '        for path in []:',
     SHARED, 'Previous trial data, hooks, history or config survives'),
    ('retained_ordinary_config', 'profiles.py', '        for path, content in self.baseline.items():',
     '        for path, content in []:', SHARED, 'PRIVATE_TRIAL_CONFIG'),
    ('retained_codex_writable_root', 'profiles.py', '                path.write_bytes(content)',
     "                path.write_bytes(content + (('\\n[sandbox_workspace_write]\\nwritable_roots = ' + json.dumps([self.context[1]['SILTA_HOME']]) + '\\n').encode() if self.context and self.harness == 'codex' else b''))",
     SHARED, 'sandbox_workspace_write'),
    ('skipped_uninstall_apply', 'profiles.py', "                applied = self.call(args + ['--apply', preview['token']], json_output=True)",
     '                applied = preview', SHARED, '1 != 3'),
    ('skipped_installer', 'evals.py', '        profile.install(binary, env, cwd)', '        pass', SHARED, 'Lists differ'),
    ('uninstall_conflict_continues', 'evals.py', '                if profile or isinstance(error, KeyboardInterrupt):',
     '                if isinstance(error, KeyboardInterrupt):', FAILURE, 'False is not true'),
    ('unknown_entry_discarded', 'profiles.py', "                raise RuntimeError('Unknown profile entry retained: ' + str(path))",
     '                path.unlink()', FAILURE, 'False is not true'),
    ('config_symlink_followed', 'profiles.py', '            self.safe_config(path)\n            self.baseline[path]',
     '            self.baseline[path]', 'test_config_aliases_and_unexpected_grant_are_refused_without_reads', 'FORBIDDEN_PROFILE_READ_COPY'),
    ('real_config_imported', 'profiles.py', "            self.configs[0].write_text('cli_auth_credentials_store = \"file\"\\n')",
     "            self.configs[0].write_bytes((Path(os.environ['HOME']) / '.codex/config.toml').read_bytes())",
     SHARED, 'FORBIDDEN_PROFILE_READ_COPY'),
    ('opaque_auth_read', 'profiles.py', '        self.reset()\n\n    def safe_config',
     "        (self.directory / ('auth.json' if self.harness == 'codex' else '.credentials.json')).read_bytes()\n        self.reset()\n\n    def safe_config",
     SHARED, 'FORBIDDEN_PROFILE_READ_COPY'),
    ('opaque_auth_deleted', 'profiles.py', '        allowed = {p.name', '        runtime.add(auth)\n        allowed = {p.name',
     SHARED, '1 != 3'),
    ('unexpected_login_grant', 'profiles.py', "            if config.get('sandbox_workspace_write', {}).get('writable_roots'):",
     '            if False:', 'test_config_aliases_and_unexpected_grant_are_refused_without_reads', 'False is not true'),
    ('missing_logout_command', 'profiles.py', "        print('Log out of the temporary profile:", "        print('Temporary profile:",
     SHARED, '0 != 1'),
    ('retained_root_omitted_from_cleanup', 'profiles.py', '*map(str, self.retained)', '*[]', FAILURE, 'not found in'),
    ('cancelled_client_survives', 'evals.py', '    except BaseException:\n        try:\n            os.killpg(child.pid, signal.SIGKILL)\n        except ProcessLookupError:\n            pass\n        finally:\n            out, err = child.communicate()\n            if capture:\n                capture.save(out, err, process_exit=child.returncode)\n        raise',
     '    except BaseException:\n        raise', 'test_exception_terminates_client_before_caller_cleanup', 'Called 0 times'),
    ('conversation_reused_between_trials', 'evals.py', 'prompt, conversation], run_env',
     "prompt, ('reused-a' if profile and phase == 0 else conversation)], run_env",
     'test_handoff_sessions_are_distinct_within_each_shared_profile_trial', '3 != 4'),
    ('claude_trial_scratch_unconfined', 'evals.py', "        env['CLAUDE_CODE_TMPDIR'] = env['TMPDIR']", '        pass',
     'test_claude_scratch_is_trial_local_and_login_scratch_is_profile_local', 'None !='),
    ('claude_login_scratch_unconfined', 'profiles.py', "            login_env['CLAUDE_CODE_TMPDIR'] = self.env['TMPDIR']", '            pass',
     'test_claude_scratch_is_trial_local_and_login_scratch_is_profile_local', 'None !='),
    ('successful_attempt_not_counted', 'evals.py', "t['checks'].get('infrastructure', True)", "t['checks'].get('infrastructure', False)",
     SHARED, '0 != 3'),
    ('receipt_failure_loses_retained_root', 'profiles.py', '        try:\n            destination.mkdir(parents=True, exist_ok=True)',
     '        destination.mkdir(parents=True, exist_ok=True)\n        try:',
     'test_receipt_directory_failure_retains_trial_for_final_cleanup', 'Lists differ'),
    ('cleanup_discards_known_evidence', 'evals.py', '                if evidence_path.is_file():', '                if False:',
     FAILURE, 'Known calls were discarded'),
    ('operator_eof_discards_attempt', 'evals.py',
     '            except (Exception, KeyboardInterrupt) as error:\n                trial_id =',
     '            except (OSError, RuntimeError, ValueError, KeyError, TypeError, KeyboardInterrupt) as error:\n                trial_id =',
     'test_operator_eof_retains_attempt_phase_evidence_and_known_usage', 'Operator EOF dropped an attempted trial'),
    ('operator_eof_loses_completed_phase', 'evals.py', "        if profile:\n            write_json(trial_dir / 'evidence.json', redact(evidence, key))",
     '        if profile:\n            pass', 'test_operator_eof_retains_attempt_phase_evidence_and_known_usage', 'Completed phase usage lost'),
    ('review_loses_run_lifecycle', 'review.py', 'updated.update({key: report[key] for key in evals.RUN_FIELDS if key in report})',
     'pass', 'test_review_preserves_aborted_zero_trial_report_and_exit', 'Review converted an aborted run to success'),
    ('review_aborted_empty_run_passes', 'review.py', "not updated.get('aborted', False) and all", 'all',
     'test_review_preserves_aborted_zero_trial_report_and_exit', 'Review converted an aborted run to success'),
    ('present_turn_starts_fresh', 'evals.py', "if scenario != 'handoff-resume':", 'if False:',
     'test_present_continuation_keeps_conversation_auth_and_task_state', ' != '),
    ('unknown_home_path_omitted', 'profiles.py', "'Unknown temporary HOME entry retained: ' + str(path)",
     "'Unknown temporary HOME entry retained'", 'test_unknown_temporary_home_entry_names_exact_owned_path', 'not found in'),
    ('returned_failure_continues', 'evals.py', '    if failed:', '    if False:',
     'test_returned_token_limit_aborts_and_retains_failed_trial', 'Returned failure reused the shared profile'),
    ('returned_failure_deletes_runtime', 'evals.py', 'retain=failed)', 'retain=False)',
     'test_returned_token_limit_aborts_and_retains_failed_trial', 'Failed runtime was deleted'),
    ('native_failure_launches_next_phase', 'evals.py', "if profile and (observed['exit'] != 0", "if False and (observed['exit'] != 0",
     'test_native_transport_failures_abort_before_next_phase', 'Another native process launched after failure'),
    ('retained_history_jsonl_only', 'profiles.py', '        for path in disposable:',
     "        for path in disposable:\n            if path.name == 'history.jsonl':\n                continue",
     'test_all_supported_history_and_memory_is_unreadable_to_later_trials', 'Earlier answers readable in native state'),
    ('retained_project_memory_only', 'profiles.py', '        for path in disposable:',
     "        for path in disposable:\n            if path.name == 'projects':\n                continue",
     'test_all_supported_history_and_memory_is_unreadable_to_later_trials', 'Earlier answers readable in native state'),
    ('retained_state_database_only', 'profiles.py', '        for path in disposable:',
     "        for path in disposable:\n            if path.name.startswith('state_'):\n                continue",
     'test_all_supported_history_and_memory_is_unreadable_to_later_trials', 'Earlier answers readable in native state'),
    ('retained_archived_sessions_only', 'profiles.py', '        for path in disposable:',
     "        for path in disposable:\n            if path.name == 'archived_sessions':\n                continue",
     'test_all_supported_history_and_memory_is_unreadable_to_later_trials', 'Earlier answers readable in native state'),
    ('uncapped_interrupt_discards_native', 'evals.py',
     '            if capture:\n                capture.save(out, err, process_exit=child.returncode)', '            pass',
     'test_native_failures.NativeFailures.test_late_interruptions_keep_exact_native_output', 'Native stdout bytes lost or duplicated'),
    ('capped_drain_discards_unread_bytes', 'codex_usage.py',
     "                buffers['stdout'].extend(out or b'')\n                buffers['stderr'].extend(err or b'')", '                pass',
     'test_native_capture.Capture.test_capped_exception_drains_unread_bytes_once_and_filters_key', 'Unread native bytes lost or duplicated'),
    ('capped_interprets_before_capture', 'codex_usage.py',
     "                    if capture:\n                        capture.save(buffers['stdout'], buffers['stderr'], final=False)", '                    pass',
     'test_native_capture.Capture.test_capped_exception_drains_unread_bytes_once_and_filters_key', 'Native interpreted before capture'),
    ('uncapped_usage_precedes_capture', 'evals.py',
     '            capture.save(out, err, process_exit=child.returncode)\n            return', '            return',
     'test_native_failures.NativeFailures.test_usage_parser_exceptions_keep_exact_native_output', 'Native stdout bytes lost or duplicated'),
    ('capture_key_filter_removed', 'native_capture.py', "raw.replace(self.key, b'[REDACTED]') if self.key else raw", 'raw',
     'test_native_capture.Capture.test_every_split_key_boundary_is_filtered_before_persistence', 'Full key not filtered'),
    ('capture_split_key_tail_published', 'native_capture.py',
     "safe[:max(0, len(safe) - len(self.key) + 1)]", 'safe',
     'test_native_capture.Capture.test_every_split_key_boundary_is_filtered_before_persistence', 'Unsafe key prefix published'),
    ('main_misses_attribute_errors', 'evals.py',
     '            except (Exception, KeyboardInterrupt) as error:\n                trial_id =',
     '            except (OSError, RuntimeError, ValueError, KeyError, TypeError, EOFError, KeyboardInterrupt) as error:\n                trial_id =',
     'test_native_failures.NativeFailures.test_helper_exceptions_preserve_known_and_unknown_observations', '0 != 1'),
    ('failure_retries_metrics_helper', 'evals.py', "metrics=failure_metrics(evidence)", 'metrics=metrics(evidence)',
     'test_native_failures.NativeFailures.test_helper_exceptions_preserve_known_and_unknown_observations', '0 != 1'),
    ('malformed_fields_grade_as_complete', 'evals.py', 'valid and not schema_errors and terminal', 'valid and terminal',
     'test_native_failures.NativeFailures.test_malformed_native_schemas_still_finish_aborted_reports', 'False is not true'),
    ('unknown_metrics_break_aggregation', 'evals.py', 'return sum(values) if values and all(valid_number(value) for value in values) else None',
     'return sum(values)', 'test_native_failures.NativeFailures.test_helper_exceptions_preserve_known_and_unknown_observations', 'Failure metrics prevented final trial aggregation'),
    ('audit_infers_effects_without_snapshot', 'audit.py',
     "        if state is None:\n            issue(bound + '/state', 'snapshot unavailable; effects cannot be inferred from the baseline')\n            continue", '        pass',
     'test_native_failures.NativeFailures.test_helper_exceptions_preserve_known_and_unknown_observations', '1 != 0'),
    ('raw_hash_uses_replacement_text', 'evals.py', "        observed['transcript_sha256'] = capture.streams['stdout']['sha256']",
     "        observed['transcript_sha256'] = hashlib.sha256(capture.text('stdout', errors='replace').encode()).hexdigest()",
     'test_native_failures.NativeFailures.test_invalid_utf8_is_retained_byte_for_byte', ' != '),
    ('partial_capture_claimed_complete', 'native_capture.py', "'complete': final", "'complete': True",
     'test_native_capture.Capture.test_every_split_key_boundary_is_filtered_before_persistence', 'Partial capture marked complete'),
    ('capture_error_skips_capped_kill', 'codex_usage.py', "            if child.poll() is None:", '            if False:',
     'test_native_capture.Capture.test_capture_exception_still_kills_and_reaps_capped_client', 'Capture failure left client running'),
    ('recovery_keeps_stale_usage', 'codex_usage.py',
     'return max(0, sum(counts.values()) - self.baseline, self.phase_tokens or 0)', 'return self.phase_tokens',
     'test_native_failures.NativeFailures.test_recovered_terminal_usage_supersedes_stale_known_count', '10 != 15'),
    ('recovery_drops_other_identities', 'codex_usage.py',
     'counts = {key: max(self.native.get(key, 0), self.terminal.get(key, 0))\n                  for key in self.native.keys() | self.terminal.keys()}', 'counts = {}',
     'test_native_capture.Capture.test_recovered_usage_keeps_distinct_identities_and_rejects_ambiguity', 'Other identity usage lost during recovery'),
    ('recovery_assigns_unknown_identity', 'codex_usage.py',
     '        if count is not None and (not isinstance(identity, str) or not identity):\n            return None', '        pass',
     'test_native_failures.NativeFailures.test_second_turn_malformed_identity_does_not_double_charge_usage', 'Unattributed cumulative usage was charged again'),
    ('audit_capture_pointer_unresolvable', 'audit.py', "issue(bound + '/capture/streams/' + stream,", "issue(bound + '/capture/' + stream,",
     'test_audit_evidence.AuditEvidence.test_incomplete_capture_citations_resolve_to_stream_metadata', 'Capture citation does not resolve'),
    ('nonfinite_metadata_accepted', 'evals.py', 'return type(value) is not float or math.isfinite(value)', 'return True',
     'test_native_failures.NativeFailures.test_nested_nonfinite_fields_do_not_escape_into_failure_evidence', 'False is not true'),
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
            qualified = test if '.' in test else 'test_profiles.Profiles.' + test
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
    print(f'Detected and restored {len(results)} sign-in/isolation faults')


if __name__ == '__main__':
    main()
