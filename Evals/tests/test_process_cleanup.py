"""Only recorded fake groups may be terminated by these bounded-drain proofs."""
import errno
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch

import test_profiles
from codex_usage import TokenBudget
import codex_usage


class ProcessCleanup(unittest.TestCase):
    def setUp(self):
        self.fixture = test_profiles.Profiles()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def run_orphan(self, mode, cap):
        root = self.fixture.root
        driver = root / ('driver-' + mode + '.py')
        result_file = root / ('result-' + mode + '.json')
        driver.write_text('import sys,json,os\nfrom pathlib import Path\n'
            + 'sys.path.insert(0,' + repr(str(test_profiles.ROOT / 'tests')) + ')\n'
            + 'from test_profiles import Profiles\nf=Profiles()\nf.root=Path(' + repr(str(root)) + ')\nf.env=dict(os.environ)\n'
            + 'result=f.run_live("codex",' + repr(mode) + ',cap=' + repr(cap) + ')\n'
            + 'Path(' + repr(str(result_file)) + ').write_text(json.dumps([str(result[0]),*result[1:]]))\n')
        child = subprocess.Popen([sys.executable, '-B', str(driver)], env=self.fixture.env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        journal = root / ('codex-' + mode + '.jsonl')
        guarded = False
        try:
            try:
                out, err = child.communicate(timeout=12)
            except subprocess.TimeoutExpired:
                guarded = True
                group = journal.with_suffix('.group')
                if group.exists():
                    try:
                        os.killpg(int(group.read_text()), signal.SIGKILL)
                    except (ProcessLookupError, PermissionError):
                        pass
                os.killpg(child.pid, signal.SIGKILL)
                out, err = child.communicate(timeout=3)
            self.assertFalse(guarded, 'Native descendant blocked capture/report past the test guard')
            self.assertEqual(child.returncode, 0, (out + err).decode(errors='replace'))
            output, report, entries, transcript, _ = json.loads(result_file.read_text())
            output = Path(output)
            self.assertTrue(report['aborted'])
            self.assertEqual(report['attempted_trials'], 1)
            self.assertEqual(report['completed_trials'], 0)
            model, = [e for e in entries if e['event'] == 'model']
            self.assertTrue(Path(model['trial']).exists(), 'Failed native root was deleted')
            self.assertIn(model['trial'], transcript)
            trial, = report['trials']
            directory = output / trial['id']
            evidence = json.loads((output / trial['evidence']).read_text())
            phase, = evidence['phases']
            for stream, suffix in (('stdout', 'jsonl'), ('stderr', 'stderr')):
                raw = (directory / ('phase-0.' + suffix)).read_bytes()
                self.assertEqual(raw, Path(model[stream + '_oracle']).read_bytes(), 'Available native bytes lost or duplicated')
                self.assertEqual(phase['capture']['streams'][stream]['sha256'], hashlib.sha256(raw).hexdigest())
            self.assertIn('aborted', (output / 'report.html').read_text())
            self.assertEqual(trial['metrics']['tokens'], 15)
            cleanup = json.loads((directory / 'cleanup.json').read_text())
            if 'escaped' in mode or 'permission' in mode or 'natural' in mode:
                self.assertTrue(phase['capture']['cleanup']['drain_cut_short'], 'Drain cutoff was not recorded')
                self.assertTrue(cleanup['deferred'], 'Profile mutated while writers remained unconfirmed')
                self.assertTrue((Path(model['profile']) / 'AGENTS.md').exists())
                self.assertIn('verify', transcript.lower())
                self.assertNotIn('After logout, clean up:', transcript)
                for stream in ('stdout', 'stderr'):
                    self.assertFalse(phase['capture']['streams'][stream]['complete'])
            else:
                signals = [json.loads(line) for line in journal.with_suffix('.signals').read_text().splitlines()]
                self.assertTrue(any(e['main_exit'] == 0 for e in signals), 'Exited native group was not signalled')
                self.assertTrue(cleanup['uninstalled'])
            if 'permission' in mode:
                self.assertEqual(phase['exit'], 'token-limit', 'Cleanup error masked the original cap')
                self.assertEqual(phase['capture']['cleanup']['group_status'], 'unconfirmed')
                self.assertIn('PermissionError', json.dumps(phase))
            else:
                self.assertEqual(phase['process_exit'], 0)
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.communicate(timeout=3)
            if journal.exists():
                for entry in map(json.loads, journal.read_text().splitlines()):
                    if entry['event'] == 'descendant':
                        try:
                            os.kill(entry['pid'], signal.SIGKILL)
                        except (ProcessLookupError, PermissionError):
                            pass
                group = journal.with_suffix('.group')
                if group.exists():
                    try:
                        os.killpg(int(group.read_text()), signal.SIGKILL)
                    except (ProcessLookupError, PermissionError):
                        pass
            location = root / ('codex-' + mode) / 'profile-location.txt'
            if location.exists():
                shutil.rmtree(Path(location.read_text().strip()), ignore_errors=True)

    def test_exited_parent_parse_failure_terminates_pipe_holding_group(self):
        self.run_orphan('orphan-parse', 100)

    def test_uncapped_exited_parent_has_bounded_pipe_capture(self):
        self.run_orphan('orphan-natural-uncapped', None)

    def test_capped_exited_parent_has_bounded_pipe_capture(self):
        self.run_orphan('orphan-natural-capped', 100)

    def test_escaped_writer_cuts_drain_short_and_defers_profile_cleanup(self):
        self.run_orphan('orphan-parse-escaped', 100)

    def test_live_group_permission_failure_keeps_cap_and_defers_cleanup(self):
        self.run_orphan('orphan-live-permission', 10)

    def test_exited_parent_live_group_permission_failure_is_not_ignored(self):
        self.run_orphan('orphan-exited-permission', 10)

    def test_exited_group_eperm_race_preserves_token_limit(self):
        child = Mock(pid=1234, returncode=0, stdout=io.BytesIO(), stderr=io.BytesIO())
        child.communicate.return_value = (b'', b'')
        child.poll.return_value = 0
        budget = TokenBudget(self.fixture.root, 10)
        def observed(_):
            budget.phase_tokens = 15
            return 15
        with patch.object(codex_usage.subprocess, 'Popen', return_value=child), patch.object(budget, 'observe', side_effect=observed), patch.object(codex_usage.selectors, 'DefaultSelector') as selector:
            selector.return_value.__enter__.return_value.get_map.side_effect = [True, False]
            selector.return_value.__enter__.return_value.select.return_value = []
            with patch.object(codex_usage.os, 'killpg', side_effect=[PermissionError(errno.EPERM, 'exited'), ProcessLookupError(errno.ESRCH, 'reaped')]) as kill:
                result = budget.execute(['explicit-fake'], {}, self.fixture.root, 10)
        self.assertEqual(result['exit'], 'token-limit')
        self.assertEqual(result['tokens'], 15)
        self.assertTrue(child.poll.called, 'Main process was not reaped before group signalling')
        self.assertEqual(kill.call_count, 2)
