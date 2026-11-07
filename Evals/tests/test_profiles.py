"""Shared sign-in must not share trial state; only explicit fake clients run."""
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import evals
from profile_history import HISTORY_FILES, UNCLASSIFIED_MEMORY


class Profiles(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='silta-profile-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        for name in ('real/.codex', 'real/.claude', 'data', 'tmp', 'guard'):
            (self.root / name).mkdir(parents=True)
        for name in ('real/.codex/config.toml', 'real/.claude/settings.json', 'real/.claude.json'):
            (self.root / name).write_text('REAL_PROFILE_SENTINEL')
        (self.root / 'guard/sitecustomize.py').write_text(
            'import sys, os\n'
            'def guard(event, args):\n'
            '    if event in ("open", "shutil.copyfile") and args and isinstance(args[0], (str, bytes)):\n'
            '        path = os.fsdecode(args[0])\n'
            '        alias = os.path.basename(path) in ("config.toml", ".claude.json", "settings.json") and (os.path.islink(path) or os.path.exists(path) and os.stat(path).st_nlink != 1)\n'
            '        if alias or os.path.basename(path) in ("auth.json", ".credentials.json") or path in os.environ["FORBIDDEN_CONFIG"].split(os.pathsep):\n'
            '            raise AssertionError("FORBIDDEN_PROFILE_READ_COPY: " + path)\n'
            'sys.addaudithook(guard)\n')
        with (self.root / 'guard/sitecustomize.py').open('a') as guard:
            guard.write('if "FORCED_TIMEOUT_READY" in os.environ:\n'
                        '    import subprocess\n'
                        '    original = subprocess.Popen.communicate\n'
                        '    def communicate(child, *args, **kwargs):\n'
                        '        if "/harnesses/" in str(child.args[0]) and not getattr(child, "timed_out", False):\n'
                        '            with open(os.environ["FORCED_TIMEOUT_READY"]) as ready: ready.readline()\n'
                        '            child.timed_out = True\n'
                        '            raise subprocess.TimeoutExpired(child.args, kwargs["timeout"])\n'
                        '        return original(child, *args, **kwargs)\n'
                        '    subprocess.Popen.communicate = communicate\n')
        self.env = dict(os.environ, HOME=str(self.root / 'real'), SILTA_HOME=str(self.root / 'data'),
                        TMPDIR=str(self.root / 'tmp'), PYTHONPATH=str(self.root / 'guard'), PYTHONDONTWRITEBYTECODE='1',
                        FORBIDDEN_CONFIG=os.pathsep.join(str(self.root / p) for p in ('real/.codex/config.toml', 'real/.claude/settings.json', 'real/.claude.json')))

    def run_live(self, harness, mode='normal', answer='signed-in', authenticate=True, scenario='plan-not-file', repeats=2, cap=None, operator=None, fault=None, fault_after=1):
        output = self.root / (harness + '-' + mode)
        journal = self.root / (harness + '-' + mode + '.jsonl')
        if mode == 'cancel' or mode.startswith('late-cancel'):
            os.mkfifo(journal.with_suffix('.signal'))
        env = dict(self.env)
        if mode == 'timeout':
            ready = journal.with_suffix('.ready')
            os.mkfifo(ready)
            env['FORCED_TIMEOUT_READY'] = str(ready)
        client = self.root / ('fake-' + harness + '-' + mode)
        client.write_text('#!/bin/sh\nexec ' + shlex.join([sys.executable, '-B', str(ROOT / 'tests/fake_profile_client.py'),
                          str(journal), harness, mode]) + ' "$@"\n')
        client.chmod(0o755)
        argv = [sys.executable, '-B', str(ROOT / 'evals.py'), '--silta', str(ROOT.parent / '.build/debug/silta'),
                '--live', '--harness', harness, '--client', str(client), '--model', 'fixture-profile',
                '--scenario', scenario, '--repeats', str(repeats), '--output', str(output)]
        if cap is not None:
            argv += ['--max-trial-tokens', str(cap)]
        if operator is not None:
            argv += ['--operator', operator]
        if fault:
            entry = self.root / 'instrumented-main.py'
            entry.write_text('import sys, json\nfrom pathlib import Path\n'
                + 'sys.path.insert(0, ' + repr(str(ROOT)) + ')\nimport evals\n'
                + 'journal = Path(' + repr(str(journal)) + ')\n'
                + 'def ready():\n    return journal.exists() and sum(json.loads(line)["event"] == "model" for line in journal.read_text().splitlines()) >= ' + str(fault_after) + '\n'
                + ('original = evals.' + fault + '\ndef fail(*args, **kwargs):\n'
                   '    if ready(): raise RuntimeError("INJECTED_' + fault.upper() + '_FAILURE")\n'
                   '    return original(*args, **kwargs)\nevals.' + fault + ' = fail\n' if fault != 'capture' else
                   'original = Path.write_bytes\nfailed = False\n'
                   'def fail(path, value):\n    global failed\n'
                   '    oracle = journal.with_name(journal.stem + ".0.stdout")\n'
                   '    if path.name == "phase-0.jsonl" and ready() and oracle.exists() and b"turn.completed" in oracle.read_bytes() and not failed:\n'
                   '        failed = True\n        raise OSError("INJECTED_CAPTURE_FAILURE")\n'
                   '    return original(path, value)\nPath.write_bytes = fail\n')
                + 'raise SystemExit(evals.main())\n')
            argv[2] = str(entry)
        child = subprocess.Popen(argv, env=env, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.addCleanup(lambda: child.kill() if child.poll() is None else None)
        text, commands, next_command = [], [], False
        for line in child.stdout:
            text.append(line)
            if next_command:
                next_command = False
                command = shlex.split(line.strip())
                self.assertEqual(Path(command[0]).name, 'profile-launcher.sh')
                commands.append(command)
                if authenticate:
                    login = subprocess.run(command, cwd=self.root / 'real', env=self.env, text=True, capture_output=True, timeout=15)
                    self.assertEqual(login.returncode, 0, login.stdout + login.stderr)
                    data = json.loads(login.stdout)
                    profile_root = Path(data['profile']).parent.parent
                    self.assertTrue(profile_root.name.startswith('silta-eval-'))
                    self.addCleanup(shutil.rmtree, profile_root, True)
                if answer is not None:
                    child.stdin.write(answer + '\n')
                    child.stdin.flush()
                if answer is None or mode == 'operator-eof':
                    child.stdin.close()
                if mode == 'cancel' or mode.startswith('late-cancel'):
                    with journal.with_suffix('.signal').open() as signal_file:
                        native_pid = int(signal_file.readline())
                    self.native_pid = native_pid
                    def stop_owned_fake():
                        try:
                            os.kill(native_pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    self.addCleanup(stop_owned_fake)
                    child.send_signal(signal.SIGINT)
            if 'Sign in ' in line and 'terminal' in line:
                next_command = True
        child.wait(timeout=10)
        child.stdin.close()
        child.stdout.close()
        transcript = ''.join(text)
        if (output / 'profile-location.txt').exists():
            self.addCleanup(shutil.rmtree, Path((output / 'profile-location.txt').read_text().strip()), True)
        self.assertEqual(child.returncode, 1, transcript)
        self.assertTrue((output / 'report.json').exists(), transcript)
        report = json.loads((output / 'report.json').read_text())
        observations = [json.loads(line) for line in journal.read_text().splitlines()] if journal.exists() else []
        return output, report, observations, transcript, commands

    def test_one_signin_and_fresh_data_hooks_config_grants_per_trial(self):
        for harness in ('claude', 'codex'):
            with self.subTest(harness=harness):
                output, report, entries, text, commands = self.run_live(harness, repeats=3)
                self.assertEqual(len(commands), 1, 'Sign-in must be run-scoped')
                self.assertEqual(len(report['trials']), 3)
                self.assertFalse(report['aborted'])
                self.assertEqual(report['completed_trials'], 3)
                models = [e for e in entries if e['event'] == 'model']
                self.assertEqual(len(models), 3)
                self.assertEqual(len({m['profile'] for m in models}), 1)
                self.assertEqual(len({m['auth_inode'] for m in models}), 1)
                self.assertEqual(len({m['data'] for m in models}), 3)
                self.assertEqual(len({m['actor'] for m in models}), 3)
                auth = Path(models[0]['profile']) / ('auth.json' if harness == 'codex' else '.credentials.json')
                self.assertEqual(auth.stat().st_ino, models[0]['auth_inode'])
                self.assertEqual(auth.stat().st_mode & 0o777, 0)
                profile = Path(models[0]['profile'])
                for name in ('AGENTS.md', 'CLAUDE.md', 'skills/silta/SKILL.md'):
                    self.assertFalse((profile / name).exists(), 'Owned piece remains: ' + name)
                if harness == 'codex':
                    self.assertEqual((profile / 'config.toml').read_text(), 'cli_auth_credentials_store = "file"\n')
                else:
                    self.assertFalse((profile / 'settings.json').exists(), 'Installed hooks remain')
                for model in models:
                    self.assertEqual(model['auth_mode'], 0)
                    self.assertFalse(model['real_config'])
                    keys = ('old_data_exists', 'old_hook_exists', 'old_runtime_exists', 'old_session_exists', 'old_config')
                    self.assertEqual({key: model[key] for key in keys}, dict.fromkeys(keys, False),
                                     'Previous trial data, hooks, history or config survives')
                    if harness == 'codex':
                        self.assertEqual(model['grants'], [model['data']])
                self.assertFalse(any(Path(m['trial']).exists() for m in models), 'Trial data root was retained')
                for trial in report['trials']:
                    self.assertTrue(trial['checks']['stream_complete'], trial)
                    receipt = json.loads((output / trial['id'] / 'cleanup.json').read_text())
                    self.assertEqual(receipt['remaining_changes'], [])
                    self.assertTrue(receipt['uninstalled'])
                self.assertEqual(text.count('Log out '), 1)
                self.assertEqual(text.count('After logout, clean up:'), 1)
                if harness == 'claude':
                    hooks = [e for e in entries if e['event'] in ('SessionStart', 'Stop')]
                    self.assertEqual(len(hooks), 6)
                    for hook in hooks:
                        self.assertEqual(hook['exit'], 0)
                        if hook['event'] == 'SessionStart':
                            self.assertIn('acme', hook['output'])
                            self.assertIn(hook['actor'].split(':')[-1], hook['exported'])
                login = next(e for e in entries if e['event'] == 'login')
                self.assertEqual(Path(login['cwd']).name, 'acme-login')
                self.assertNotEqual(Path(login['cwd']), self.root / 'real')

    def test_cancellation_reaps_native_before_retaining_failed_trial(self):
        _, report, entries, text, _ = self.run_live('codex', 'cancel')
        self.assertTrue(report['aborted'])
        models = [e for e in entries if e['event'] == 'model']
        self.assertEqual(len(models), 1)
        self.assertEqual(len(report['trials']), 1)
        with self.assertRaises(ProcessLookupError):
            os.kill(self.native_pid, 0)
        self.assertIn(models[0]['trial'], text)
        self.assertTrue(Path(models[0]['trial']).exists())
        self.addCleanup(shutil.rmtree, Path(models[0]['trial']), True)

    def test_runtime_symlink_is_unlinked_without_following_external_decoy(self):
        _, report, entries, _, _ = self.run_live('claude', 'runtime-link')
        self.assertFalse(report['aborted'])
        self.assertEqual(len([e for e in entries if e['event'] == 'model']), 2)
        self.assertEqual((self.root / 'real/.claude/settings.json').read_text(), 'REAL_PROFILE_SENTINEL')

    def test_handoff_sessions_are_distinct_within_each_shared_profile_trial(self):
        output, report, _, _, _ = self.run_live('codex', scenario='handoff-resume')
        identities = []
        for trial in report['trials']:
            evidence = json.loads((output / trial['evidence']).read_text())
            phases = evidence['phases']
            self.assertEqual(len(phases), 2)
            self.assertNotEqual(phases[0]['actor'], phases[1]['actor'])
            self.assertNotEqual(phases[0]['conversation'], phases[1]['conversation'])
            identities.extend(p['conversation'] for p in phases)
        self.assertEqual(len(set(identities)), 4)

    def assert_aborted_trial(self, output, report, entries, text, exit_code, known_tokens=15):
        self.assertTrue(report['aborted'], 'Returned failure reused the shared profile')
        self.assertEqual(report['planned_trials'], 2)
        self.assertEqual(report['attempted_trials'], 1)
        self.assertEqual(report['completed_trials'], 0)
        models = [e for e in entries if e['event'] == 'model']
        self.assertEqual(len(models), 1, 'Another native process launched after failure')
        root = Path(models[0]['trial'])
        self.addCleanup(shutil.rmtree, root, True)
        self.assertTrue((root / 'data/silta.db').exists(), 'Failed runtime was deleted')
        self.assertIn(str(root), text)
        trial, = report['trials']
        self.assertFalse(trial['checks']['infrastructure'])
        self.assertEqual(trial['metrics']['tokens'], known_tokens)
        evidence = json.loads((output / trial['evidence']).read_text())
        phase, = evidence['phases']
        self.assertEqual(phase['exit'], exit_code)
        self.assertEqual(phase['tokens'], known_tokens)
        self.assertTrue((output / trial['id'] / 'phase-0.jsonl').is_file())
        self.assertTrue((output / trial['id'] / 'silta.db').is_file())
        self.assertTrue((output / trial['id'] / 'cleanup.json').is_file())

    def test_returned_token_limit_aborts_and_retains_failed_trial(self):
        output, report, entries, text, _ = self.run_live('codex', cap=1)
        self.assert_aborted_trial(output, report, entries, text, 'token-limit')

    def test_returned_timeout_aborts_and_retains_failed_trial(self):
        for harness in ('claude', 'codex'):
            with self.subTest(harness=harness):
                output, report, entries, text, _ = self.run_live(harness, 'timeout')
                self.assert_aborted_trial(output, report, entries, text, 'timeout')

    def test_missing_usage_aborts_and_retains_failed_trial(self):
        output, report, entries, text, _ = self.run_live('codex', 'missing-usage', cap=100)
        self.assert_aborted_trial(output, report, entries, text, 'usage-unavailable', known_tokens=None)

    def test_native_transport_failures_abort_before_next_phase(self):
        for harness in ('claude', 'codex'):
            for mode in ('nonzero', 'stream-error', 'malformed'):
                with self.subTest(harness=harness, mode=mode):
                    output, report, entries, text, _ = self.run_live(harness, mode, scenario='handoff-resume')
                    self.assert_aborted_trial(output, report, entries, text, 7 if mode == 'nonzero' else 0)

    def test_all_supported_history_and_memory_is_unreadable_to_later_trials(self):
        for harness in ('claude', 'codex'):
            with self.subTest(harness=harness):
                _, report, entries, _, _ = self.run_live(harness)
                self.assertFalse(report['aborted'])
                models = [e for e in entries if e['event'] == 'model']
                self.assertEqual(len(models), 2)
                seeded = [e for e in entries if e['event'] == 'history-seeded']
                self.assertEqual(len(seeded), 2)
                for event in seeded:
                    self.assertEqual(set(event['files']), set(HISTORY_FILES[harness]))
                self.assertEqual(models[1]['old_answer_files'], [], 'Earlier answers readable in native state')
                for name in HISTORY_FILES[harness]:
                    self.assertFalse((Path(models[1]['profile']) / name).exists(), 'History survives final cleanup: ' + name)

    def test_unclassified_memory_aborts_instead_of_reusing_profile(self):
        for harness in ('claude', 'codex'):
            with self.subTest(harness=harness):
                output, report, entries, text, _ = self.run_live(harness, 'unclassified-memory')
                self.assert_aborted_trial(output, report, entries, text, 0)
                model = next(e for e in entries if e['event'] == 'model')
                path = Path(model['profile']) / UNCLASSIFIED_MEMORY[harness]
                self.assertIn('PREVIOUS_TRIAL_ANSWER:', path.read_text())

    def test_token_cap_does_not_include_previous_trial_native_sessions(self):
        output, report, _, _, _ = self.run_live('codex', cap=20)
        self.assertFalse(report['aborted'])
        self.assertEqual(report['tokens'], 30)
        for trial in report['trials']:
            evidence = json.loads((output / trial['evidence']).read_text())
            self.assertEqual(evidence['phases'][0]['exit'], 0)
            self.assertEqual(trial['metrics']['tokens'], 15)

    def test_claude_scratch_is_trial_local_and_login_scratch_is_profile_local(self):
        _, report, entries, _, _ = self.run_live('claude')
        self.assertFalse(report['aborted'])
        login = next(e for e in entries if e['event'] == 'login')
        self.assertEqual(login['scratch'], str(Path(login['profile']).parent.parent / 'tmp'))
        models = [e for e in entries if e['event'] == 'model']
        self.assertEqual(len(models), 2)
        for model in models:
            self.assertEqual(model['scratch'], str(Path(model['trial']) / 'tmp'))
            self.assertFalse((Path(model['trial']) / 'tmp/trial-scratch').exists())

    def test_missing_confirmation_or_marker_aborts_before_any_trial(self):
        for mode, answer in [('declined', 'no'), ('no-marker', 'signed-in')]:
            output, report, entries, text, commands = self.run_live('codex', mode, answer, authenticate=False)
            self.assertTrue(report['aborted'])
            self.assertEqual(report['trials'], [], 'Trial launched without login confirmation')
            self.assertFalse(any(e['event'] == 'model' for e in entries))
            self.assertEqual(len(commands), 1)
            self.assertEqual(text.count('Log out '), 1)
            self.assertEqual(text.count('After logout, clean up:'), 1)
            profile = Path((output / 'profile-location.txt').read_text().strip())
            self.addCleanup(shutil.rmtree, profile, True)

    def test_cleanup_conflict_and_unknown_state_abort_future_trials(self):
        for harness, mode in [('codex', 'corrupt'), ('claude', 'corrupt'), ('codex', 'unknown')]:
            output, report, entries, text, _ = self.run_live(harness, mode)
            self.assertTrue(report['aborted'], text)
            models = [e for e in entries if e['event'] == 'model']
            self.assertEqual(len(models), 1, 'Cleanup failure must suppress later clients')
            self.assertEqual(report['planned_trials'], 2)
            self.assertEqual(report['attempted_trials'], 1)
            self.assertEqual(report['completed_trials'], 0)
            self.assertEqual(len(report['trials']), 1)
            self.assertTrue(Path(models[0]['trial']).exists())
            self.addCleanup(shutil.rmtree, Path(models[0]['trial']), True)
            self.assertIn(models[0]['trial'], text)
            self.assertFalse(report['trials'][0]['checks']['infrastructure'])
            trial = report['trials'][0]
            self.assertGreater(trial['metrics']['silta_calls'], 0, 'Known calls were discarded')
            self.assertEqual(trial['metrics']['tokens'], 15)
            evidence = json.loads((output / trial['evidence']).read_text())
            self.assertEqual(len(evidence['phases']), 1)
            audit = subprocess.run([sys.executable, '-B', str(ROOT / 'audit.py'), str(output)],
                                   env=self.env, capture_output=True, text=True)
            self.assertEqual(audit.returncode, 0, audit.stderr)
            self.assertIn('PHASE phase-0', audit.stdout)
            self.assertIn('FINAL tasks', audit.stdout)
            if mode == 'unknown':
                self.assertTrue((Path(models[0]['profile']) / 'unknown-opaque').exists())

    def test_review_preserves_aborted_zero_trial_report_and_exit(self):
        output, report, _, _, _ = self.run_live('codex', answer=None, authenticate=False)
        self.assertTrue(report['aborted'])
        self.assertEqual(report['attempted_trials'], 0)
        verdicts = self.root / 'empty-verdicts.json'
        verdicts.write_text('{}')
        run = subprocess.run([sys.executable, '-B', str(ROOT / 'review.py'), str(output), str(verdicts)],
                             env=self.env, capture_output=True, text=True)
        self.assertEqual(run.returncode, 1, 'Review converted an aborted run to success')
        updated = json.loads((output / 'report.json').read_text())
        for key in ('aborted', 'planned_trials', 'attempted_trials', 'completed_trials'):
            self.assertEqual(updated[key], report[key])
        self.assertIn('aborted', (output / 'report.html').read_text())

    def test_operator_eof_retains_attempt_phase_evidence_and_known_usage(self):
        output, report, entries, text, _ = self.run_live('codex', 'operator-eof', scenario='proposals-ask', repeats=1)
        self.assertTrue(report['aborted'])
        self.assertEqual(report['attempted_trials'], 5, 'Operator EOF dropped an attempted trial')
        trial = report['trials'][-1]
        self.assertEqual(trial['variant'], 'present-add')
        self.assertFalse(trial['checks']['infrastructure'])
        self.assertEqual(trial['metrics'].get('tokens'), 15, 'Completed phase usage lost')
        evidence = json.loads((output / trial['evidence']).read_text())
        self.assertEqual(len(evidence['phases']), 1)
        self.assertTrue(evidence['phases'][0]['complete'])
        model = [e for e in entries if e['event'] == 'model'][-1]
        self.addCleanup(shutil.rmtree, Path(model['trial']), True)
        self.assertTrue(Path(model['trial']).exists())
        self.assertIn(model['trial'], text)

    def test_present_continuation_keeps_conversation_auth_and_task_state(self):
        output, report, entries, _, commands = self.run_live('codex', scenario='proposals-ask', repeats=1, operator='scripted')
        self.assertEqual(len(commands), 1)
        present = [trial for trial in report['trials'] if trial['variant'].startswith('present-')]
        for trial in present:
            evidence = json.loads((output / trial['evidence']).read_text())
            first, second = evidence['phases']
            self.assertEqual(first['conversation'], second['conversation'])
            self.assertTrue(first['complete'] and second['complete'])
            self.assertEqual(first['actor'], second['actor'])
            self.assertLessEqual({task['id'] for task in first['state']['tasks']},
                                 {task['id'] for task in second['state']['tasks']})
            models = [e for e in entries if e['event'] == 'model' and e['actor'] == first['actor']]
            self.assertEqual(len(models), 2)
            self.assertEqual(models[0]['auth_inode'], models[1]['auth_inode'])
            self.assertEqual(models[0]['data'], models[1]['data'])
            for model in models:
                self.assertEqual(model['grants'], [model['data']])
            self.assertTrue((output / trial['id'] / 'cleanup.json').exists())
        self.assertEqual(len(present), 4)
        self.assertFalse(report['aborted'])

    def test_config_aliases_and_unexpected_grant_are_refused_without_reads(self):
        for mode in ('symlink-auth', 'hardlink-auth', 'unexpected-grant'):
            _, report, entries, text, _ = self.run_live('codex', mode)
            self.assertTrue(report['aborted'], text)
            self.assertEqual(report['trials'], [])
            self.assertFalse(any(e['event'] == 'model' for e in entries))
            self.assertNotIn('FORBIDDEN_PROFILE_READ_COPY', text, 'Alias opened before validation')

    def test_exception_terminates_client_before_caller_cleanup(self):
        child = unittest.mock.Mock(pid=1234)
        child.communicate.side_effect = [KeyboardInterrupt(), ('', '')]
        with patch.object(evals.subprocess, 'Popen', return_value=child), patch.object(evals.os, 'killpg') as kill:
            with self.assertRaises(KeyboardInterrupt):
                evals.execute(['fake-only'], {}, self.root, 10)
            kill.assert_called_once()
            self.assertEqual(child.communicate.call_count, 2)

    def test_credential_guard_rejects_reads_copies_and_config_aliases_before_io(self):
        auth = self.root / 'auth.json'
        auth.touch()
        auth.chmod(0)
        link = self.root / 'config.toml'
        link.symlink_to(auth)
        hardlink = self.root / 'settings.json'
        os.link(auth, hardlink)
        for path in (auth, link, hardlink, self.root / 'real/.codex/config.toml'):
            for operation in ('read', 'copy'):
                script = ('from pathlib import Path; import shutil,sys; '
                          + ('Path(sys.argv[1]).read_bytes()' if operation == 'read' else
                             'shutil.copyfile(sys.argv[1], sys.argv[2])'))
                run = subprocess.run([sys.executable, '-B', '-c', script, str(path), str(self.root / 'copy')],
                                     env=self.env, text=True, capture_output=True)
                self.assertNotEqual(run.returncode, 0)
                self.assertIn('FORBIDDEN_PROFILE_READ_COPY', run.stderr)
                self.assertNotIn('PermissionError', run.stderr)

    def test_receipt_directory_failure_retains_trial_for_final_cleanup(self):
        output = self.root / 'profile-output'
        output.mkdir()
        profile = evals.RunProfile('codex', ROOT / 'tests/fake_profile_client.py', output,
                                   evals.isolated_env, evals.execute)
        self.addCleanup(shutil.rmtree, profile.root, True)
        trial = self.root / 'trial'
        trial.mkdir()
        blocked = self.root / 'blocked'
        blocked.write_text('Owned output-directory conflict')
        with self.assertRaises(OSError):
            profile.finish_trial(trial, blocked / 'receipt')
        self.assertEqual(profile.retained, [trial])
        console = io.StringIO()
        with patch('sys.stdout', console):
            profile.instructions()
        self.assertIn(str(trial), console.getvalue())

    def test_unknown_temporary_home_entry_names_exact_owned_path(self):
        output = self.root / 'profile-output'
        output.mkdir()
        profile = evals.RunProfile('codex', ROOT / 'tests/fake_profile_client.py', output,
                                   evals.isolated_env, evals.execute)
        self.addCleanup(shutil.rmtree, profile.root, True)
        unknown = profile.home / 'unknown-state'
        unknown.touch()
        with self.assertRaises(RuntimeError) as caught:
            profile.reset()
        self.assertIn(str(unknown), str(caught.exception))
        self.assertTrue(unknown.exists())


if __name__ == '__main__':
    unittest.main()
