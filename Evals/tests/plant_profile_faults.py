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
     'test_missing_confirmation_or_marker_aborts_before_any_trial', 'False is not true'),
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
     '                applied = preview', SHARED, '1 != 2'),
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
     SHARED, '0 != 2'),
    ('unexpected_login_grant', 'profiles.py', "            if config.get('sandbox_workspace_write', {}).get('writable_roots'):",
     '            if False:', 'test_config_aliases_and_unexpected_grant_are_refused_without_reads', 'False is not true'),
    ('missing_logout_command', 'profiles.py', "        print('Log out of the temporary profile:", "        print('Temporary profile:",
     SHARED, '0 != 1'),
    ('retained_root_omitted_from_cleanup', 'profiles.py', '*map(str, self.retained)', '*[]', FAILURE, 'not found in'),
    ('cancelled_client_survives', 'evals.py', '    except BaseException:\n        try:\n            os.killpg(child.pid, signal.SIGKILL)\n        except ProcessLookupError:\n            pass\n        finally:\n            child.communicate()\n        raise',
     '    except BaseException:\n        raise', 'test_exception_terminates_client_before_caller_cleanup', 'Called 0 times'),
    ('conversation_reused_between_trials', 'evals.py', 'prompt, conversation], run_env',
     "prompt, ('reused-a' if profile and phase == 0 else conversation)], run_env",
     'test_handoff_sessions_are_distinct_within_each_shared_profile_trial', '3 != 4'),
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
            run = subprocess.run([sys.executable, '-B', '-m', 'unittest', 'test_profiles.Profiles.' + test],
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
