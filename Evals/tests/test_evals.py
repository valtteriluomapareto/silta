"""Offline acceptance: only the repository stub may be launched as a harness."""
import copy
import importlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
BINARY = ROOT.parent / '.build/debug/silta'
STUB = Path(__file__).with_name('stub_harness.py')
SCENARIOS = ['start-cross-repo', 'plan-not-file', 'handoff-resume',
             'done-with-result', 'proposals-ask', 'ask-short']


class Acceptance(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='silta-evals-test-')
        cls.output = Path(cls.temp.name) / 'passing'
        cls.command = [str(ROOT / 'run.sh'), '--silta', str(BINARY),
                       '--stub', str(STUB), '--output', str(cls.output)]
        if not (ROOT / 'run.sh').exists():
            raise AssertionError('Missing eval matrix runner: six real-CLI replay scenarios cannot run')
        result = subprocess.run(cls.command, capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(f'offline runner failed: {result.stdout}\n{result.stderr}')
        cls.report = json.loads((cls.output / 'report.json').read_text())
        cls.evals = importlib.import_module('evals')

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_both_adapters_all_scenarios_three_repeats(self):
        self.assertEqual(self.report['provenance'], 'stub')
        groups = self.report['groups']
        self.assertEqual(len(groups), 12)
        for group in groups:
            self.assertEqual(group['repeats'], 3)
            self.assertEqual(group['pass_rate'], 1)
            self.assertTrue(group['all_repeats_pass'])
        self.assertEqual({g['scenario'] for g in groups}, set(SCENARIOS))

    def test_failing_recording_per_scenario(self):
        output = Path(self.temp.name) / 'failing'
        result = subprocess.run(self.command[:-1] + [str(output), '--repeats', '1',
                                '--recording', 'fail'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        report = json.loads((output / 'report.json').read_text())
        self.assertEqual(len(report['groups']), 12)
        self.assertTrue(all(g['pass_rate'] == 0 for g in report['groups']))

    def test_grader_guarantees(self):
        # Each row is a separate negative evidence test and source-fault target.
        inventory = json.loads((ROOT / 'tests/guarantees.json').read_text())
        for guarantee, case in inventory.items():
            with self.subTest(guarantee=guarantee):
                trial = next(t for t in self.report['trials']
                             if t['scenario'] == case['scenario']
                             and t['variant'] == case['variant'])
                evidence = json.loads((self.output / trial['evidence']).read_text())
                self.assertTrue(self.evals.grade(evidence)['checks'][guarantee])
                self.evals.invalidate(evidence, guarantee)
                graded = self.evals.grade(evidence)
                self.assertFalse(graded['checks'][guarantee], guarantee)
                self.assertFalse(graded['passed'])

    def test_claims_do_not_override_database(self):
        trial = next(t for t in self.report['trials'] if t['scenario'] == 'done-with-result')
        evidence = json.loads((self.output / trial['evidence']).read_text())
        evidence['phases'][-1]['messages'].append('Everything passed; task done with SHA.')
        evidence['phases'][-1]['state']['tasks'][0]['result_md'] = None
        self.assertFalse(self.evals.grade(evidence)['passed'])

    def test_metric_denominators_and_html_escaping(self):
        for trial in self.report['trials']:
            self.assertGreater(trial['metrics']['silta_calls'], 0)
            self.assertEqual(trial['metrics']['usage_errors'], 0)
            self.assertEqual(trial['metrics']['forbidden_attempts'], 0)
        report = copy.deepcopy(self.report)
        report['groups'][0]['model'] = '<script>alert(1)</script>'
        html = self.evals.render_html(report)
        self.assertNotIn('<script>', html)
        self.assertIn('&lt;script&gt;', html)

    def test_native_stream_failures_and_unknown_tool(self):
        for harness in ['claude', 'codex']:
            for stream in ['', '{broken}\n', '{}\n']:
                with self.subTest(harness=harness, stream=stream):
                    self.assertFalse(self.evals.parse_stream(harness, stream)['complete'])
        unknown = {'type': 'assistant', 'message': {'content': [
            {'type': 'tool_use', 'name': 'UnknownRead', 'input': {}}]}}
        terminal = {'type': 'result', 'is_error': False}
        parsed = self.evals.parse_stream('claude', '\n'.join(map(json.dumps, [unknown, terminal])))
        self.assertTrue(parsed['opaque'])

    def test_timeout_kills_process_group_without_wall_clock_wait(self):
        from unittest.mock import Mock, patch
        child = Mock(pid=123, returncode=-9)
        child.communicate.side_effect = [subprocess.TimeoutExpired('stub', 1), ('', '')]
        with patch.object(self.evals.subprocess, 'Popen', return_value=child), \
                patch.object(self.evals.os, 'killpg') as kill:
            result = self.evals.execute(['/stub'], {}, ROOT, 1)
        kill.assert_called_once()
        self.assertEqual(result['exit'], 'timeout')

    def test_unreviewed_live_never_passes(self):
        trial = self.report['trials'][0]
        evidence = json.loads((self.output / trial['evidence']).read_text())
        evidence['provenance'] = 'live'
        evidence['review'] = None
        self.assertFalse(self.evals.grade(evidence)['passed'])


if __name__ == '__main__':
    unittest.main()
