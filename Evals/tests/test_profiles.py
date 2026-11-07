"""Shared sign-in must not share trial state; only explicit fake clients run."""
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import evals


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
            '        if os.path.basename(path) in ("auth.json", ".credentials.json") or path in os.environ["FORBIDDEN_CONFIG"].split(os.pathsep):\n'
            '            raise AssertionError("FORBIDDEN_PROFILE_READ_COPY: " + path)\n'
            'sys.addaudithook(guard)\n')
        self.env = dict(os.environ, HOME=str(self.root / 'real'), SILTA_HOME=str(self.root / 'data'),
                        TMPDIR=str(self.root / 'tmp'), PYTHONPATH=str(self.root / 'guard'), PYTHONDONTWRITEBYTECODE='1',
                        FORBIDDEN_CONFIG=os.pathsep.join(str(self.root / p) for p in ('real/.codex/config.toml', 'real/.claude/settings.json', 'real/.claude.json')))

    def run_live(self, harness, mode='normal', answer='signed-in', authenticate=True, scenario='plan-not-file', repeats=2):
        output = self.root / (harness + '-' + mode)
        journal = self.root / (harness + '-' + mode + '.jsonl')
        client = self.root / ('fake-' + harness + '-' + mode)
        client.write_text('#!/bin/sh\nexec ' + shlex.join([sys.executable, '-B', str(ROOT / 'tests/fake_profile_client.py'),
                          str(journal), harness, mode]) + ' "$@"\n')
        client.chmod(0o755)
        argv = [sys.executable, '-B', str(ROOT / 'evals.py'), '--silta', str(ROOT.parent / '.build/debug/silta'),
                '--live', '--harness', harness, '--client', str(client), '--model', 'fixture-profile',
                '--scenario', scenario, '--repeats', str(repeats), '--output', str(output)]
        child = subprocess.Popen(argv, env=self.env, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
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
                child.stdin.write(answer + '\n')
                child.stdin.flush()
            if 'Sign in ' in line and 'terminal' in line:
                next_command = True
        child.wait(timeout=10)
        child.stdin.close()
        child.stdout.close()
        transcript = ''.join(text)
        self.assertEqual(child.returncode, 1, transcript)
        self.assertTrue((output / 'report.json').exists(), transcript)
        report = json.loads((output / 'report.json').read_text())
        observations = [json.loads(line) for line in journal.read_text().splitlines()] if journal.exists() else []
        return output, report, observations, transcript, commands

    def test_one_signin_and_fresh_data_hooks_config_grants_per_trial(self):
        for harness in ('claude', 'codex'):
            with self.subTest(harness=harness):
                output, report, entries, text, commands = self.run_live(harness)
                self.assertEqual(len(commands), 1, 'Sign-in must be run-scoped')
                self.assertEqual(len(report['trials']), 2)
                self.assertFalse(report['aborted'])
                models = [e for e in entries if e['event'] == 'model']
                self.assertEqual(len(models), 2)
                self.assertEqual(len({m['profile'] for m in models}), 1)
                self.assertEqual(len({m['auth_inode'] for m in models}), 1)
                self.assertEqual(len({m['data'] for m in models}), 2)
                self.assertEqual(len({m['actor'] for m in models}), 2)
                for model in models:
                    self.assertEqual(model['auth_mode'], 0)
                    self.assertFalse(model['real_config'])
                    self.assertFalse(model['old_data_exists'], 'Previous trial Silta data survives')
                    self.assertFalse(model['old_hook_exists'], 'Previous hook log survives')
                    self.assertFalse(model['old_runtime_exists'], 'Previous profile history survives')
                    self.assertFalse(model['old_config'], 'Previous ordinary config survives')
                    self.assertFalse(Path(model['trial']).exists(), 'Trial data root was retained')
                    if harness == 'codex':
                        self.assertEqual(model['grants'], [model['data']])
                for trial in report['trials']:
                    self.assertTrue(trial['checks']['stream_complete'], trial)
                    receipt = json.loads((output / trial['id'] / 'cleanup.json').read_text())
                    self.assertEqual(receipt['remaining_changes'], [])
                    self.assertTrue(receipt['uninstalled'])
                self.assertEqual(text.count('Log out '), 1)
                self.assertEqual(text.count('After logout, clean up:'), 1)
                if harness == 'claude':
                    hooks = [e for e in entries if e['event'] in ('SessionStart', 'Stop')]
                    self.assertEqual(len(hooks), 4)
                    for hook in hooks:
                        self.assertEqual(hook['exit'], 0)
                        if hook['event'] == 'SessionStart':
                            self.assertIn('acme', hook['output'])
                            self.assertIn(hook['actor'].split(':')[-1], hook['exported'])
                login = next(e for e in entries if e['event'] == 'login')
                self.assertEqual(Path(login['cwd']).name, 'acme-login')
                self.assertNotEqual(Path(login['cwd']), self.root / 'real')

    def test_missing_confirmation_or_marker_aborts_before_any_trial(self):
        for mode, answer in [('declined', 'no'), ('no-marker', 'signed-in')]:
            output, report, entries, text, commands = self.run_live('codex', mode, answer, authenticate=False)
            self.assertTrue(report['aborted'])
            self.assertEqual(report['trials'], [])
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
            self.assertEqual(len(report['trials']), 1)
            self.assertTrue(Path(models[0]['trial']).exists())
            self.addCleanup(shutil.rmtree, Path(models[0]['trial']), True)
            self.assertIn(models[0]['trial'], text)
            self.assertFalse(report['trials'][0]['checks']['infrastructure'])

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


if __name__ == '__main__':
    unittest.main()
