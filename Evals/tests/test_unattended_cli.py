"""Real CLI/matrix paths with explicit fake client, fake key and input tripwire."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
KEY = 'fake-si63-cli-not-a-credential'


class UnattendedCLI(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='silta-cli-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        for name in ('home', 'data', 'tmp', 'tripwire'):
            (self.root / name).mkdir()
        self.reads = self.root / 'input-reads'
        (self.root / 'tripwire/sitecustomize.py').write_text(
            'import builtins, os\n'
            'def forbidden(*args, **kwargs):\n'
            '    with open(os.environ["INPUT_READS"], "a") as output: output.write("input\\n")\n'
            '    raise AssertionError("UNATTENDED_INPUT_REQUEST")\n'
            'builtins.input = forbidden\n')
        self.env = dict(os.environ, HOME=str(self.root / 'home'), SILTA_HOME=str(self.root / 'data'),
                        TMPDIR=str(self.root / 'tmp'), FIREWORKS_API_KEY=KEY,
                        PYTHONPATH=str(self.root / 'tripwire'), PYTHONDONTWRITEBYTECODE='1', INPUT_READS=str(self.reads))

    def run_cli(self, script, flags, output='result'):
        directory = self.root / output
        command = [sys.executable, '-B', str(ROOT / script), '--silta', str(ROOT.parent / '.build/debug/silta'),
                   '--client', str(ROOT / 'tests/fake_cli.py'), '--output', str(directory), *flags]
        run = subprocess.run(command, env=self.env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90)
        self.assertFalse(self.reads.exists(), 'Unattended CLI requested input: ' + run.stderr)
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        report_path = directory / ('fixture-pass/report.json' if script == 'open_matrix.py' else 'report.json')
        self.assertTrue(report_path.exists(), run.stdout + run.stderr)
        report = json.loads(report_path.read_text())
        for trial in report['trials']:
            self.assertEqual(trial['provider'], 'fireworks')
            self.assertEqual(trial['operator'], 'scripted')
        self.assertNotIn(KEY, run.stdout + run.stderr)
        return directory, report

    def test_actual_matrix_core_pilot_has_no_input_and_exact_coverage(self):
        directory, report = self.run_cli('open_matrix.py', ['--models', 'fixture-pass', '--core', '--max-trial-tokens', '1000'])
        self.assertEqual({t['scenario'] for t in report['trials']},
                         {'start-cross-repo', 'plan-not-file', 'handoff-resume', 'done-with-result'})
        self.assertEqual(len(report['trials']), 4)
        for trial in report['trials']:
            self.assertNotIn('infrastructure', trial['checks'])
            self.assertTrue(trial['checks']['stream_complete'])
            self.assertEqual([key for key, value in trial['checks'].items() if not value], ['evidence_review'])
        self.assertEqual(json.loads((directory / 'matrix.json').read_text())['models'][0]['exit'], 1)

    def policy(self, model, cap, output):
        return self.run_cli('evals.py', ['--live', '--harness', 'codex', '--provider', 'fireworks', '--operator', 'scripted',
                            '--model', model, '--scenario', 'proposals-ask', '--repeats', '1', '--max-trial-tokens', str(cap)], output)

    def test_actual_cli_scripted_grant_and_empty_denial(self):
        for recording in ('pass', 'fail'):
            directory, report = self.policy('fixture-' + recording, 1000, recording)
            present = [t for t in report['trials'] if t['variant'].startswith('present-')]
            self.assertEqual({t['variant'] for t in present}, {'present-add', 'present-parent', 'present-import', 'present-split'})
            for trial in report['trials']:
                self.assertNotIn('infrastructure', trial['checks'])
            for trial in present:
                evidence = json.loads((directory / trial['evidence']).read_text())
                self.assertEqual(evidence['approval']['source'], 'scripted-operator')
                self.assertEqual(bool(evidence['approval']['words']), recording == 'pass')
                self.assertEqual(trial['checks']['approval_provenance'], recording == 'pass')
                self.assertEqual(len(evidence['phases']), 2)

    def test_actual_cli_low_cap_stops_before_present_second_phase(self):
        directory, report = self.policy('fixture-pass', 10, 'capped')
        self.assertEqual(len(report['trials']), 10)
        for trial in report['trials']:
            self.assertFalse(trial['checks']['infrastructure'], 'CLI cap forwarding was lost')
            evidence = json.loads((directory / trial['evidence']).read_text())
            self.assertEqual(evidence['phases'][0]['exit'], 'token-limit')
            self.assertEqual(len(evidence['phases']), 1)
            self.assertIsNone(evidence['approval'])

    def test_input_tripwire_records_a_read_even_when_exception_is_caught(self):
        probe = subprocess.run([sys.executable, '-B', '-c', 'try: input()\nexcept AssertionError: pass'],
                               env=self.env, capture_output=True, text=True)
        self.assertEqual(probe.returncode, 0)
        self.assertEqual(self.reads.read_text(), 'input\n')


if __name__ == '__main__':
    unittest.main()
