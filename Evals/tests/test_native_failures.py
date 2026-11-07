"""Native exceptions must leave exact output and consumable failure evidence."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

import test_profiles


class NativeFailures(unittest.TestCase):
    def setUp(self):
        self.fixture = test_profiles.Profiles()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def check(self, harness, mode, cap=None, fault=None, fault_after=1, scenario='plan-not-file'):
        output, report, entries, text, _ = self.fixture.run_live(harness, mode, cap=cap, fault=fault,
                                                               fault_after=fault_after, scenario=scenario)
        self.assertTrue(report['aborted'])
        self.assertEqual(report['attempted_trials'], 1, 'Failure metrics prevented final trial aggregation')
        self.assertEqual(report['completed_trials'], 0)
        models = [e for e in entries if e['event'] == 'model']
        self.assertEqual(len(models), fault_after)
        trial, = report['trials']
        directory = output / trial['id']
        for number, model in enumerate(models):
            root = Path(model['trial'])
            self.assertTrue(root.exists())
            self.assertIn(str(root), text)
            stdout, stderr = directory / f'phase-{number}.jsonl', directory / f'phase-{number}.stderr'
            self.assertTrue(stdout.exists(), 'Native stdout lost on thrown failure')
            self.assertTrue(stderr.exists(), 'Native stderr lost on thrown failure')
            self.assertEqual(stdout.read_bytes(), Path(model['stdout_oracle']).read_bytes(), 'Native stdout bytes lost or duplicated')
            self.assertEqual(stderr.read_bytes(), Path(model['stderr_oracle']).read_bytes(), 'Native stderr bytes lost or duplicated')
            self.assertIn(b'NATIVE_STDOUT_SENTINEL', stdout.read_bytes())
            self.assertIn(b'NATIVE_STDERR_SENTINEL', stderr.read_bytes())
        evidence = json.loads((output / trial['evidence']).read_text())
        self.assertEqual(len(evidence['phases']), fault_after)
        for number, phase in enumerate(evidence['phases']):
            self.assertEqual(phase['transcript_sha256'], hashlib.sha256((directory / f'phase-{number}.jsonl').read_bytes()).hexdigest())
        self.assertEqual(trial['metrics']['tokens'], None if harness == 'claude' and mode == 'schema-usage' else 15 * fault_after)
        if fault == 'logs':
            self.assertIsNone(trial['metrics']['silta_calls'], 'Unavailable calls were reported as zero')
        else:
            self.assertGreater(trial['metrics']['silta_calls'], 0, 'Known Silta calls lost')
        self.assertIn('aborted', (output / 'report.html').read_text())
        audit = subprocess.run([sys.executable, '-B', str(test_profiles.ROOT / 'audit.py'), str(output)],
                               env=self.fixture.env, text=True, capture_output=True)
        self.assertEqual(audit.returncode, 0, audit.stderr)
        self.assertIn('UNRESOLVED', audit.stdout)
        if mode.startswith('late-cancel'):
            with self.assertRaises(ProcessLookupError):
                os.kill(self.fixture.native_pid, 0)
        return report, evidence

    def test_usage_parser_exceptions_keep_exact_native_output(self):
        for cap in (None, 100):
            with self.subTest(cap=cap):
                self.check('codex', 'usage-parser' + ('-capped' if cap else ''), cap=cap)

    def test_late_interruptions_keep_exact_native_output(self):
        for harness, cap in (('claude', None), ('codex', None), ('codex', 100)):
            with self.subTest(harness=harness, cap=cap):
                self.check(harness, 'late-cancel' + ('-capped' if cap else ''), cap=cap)

    def test_malformed_native_schemas_still_finish_aborted_reports(self):
        for harness in ('claude', 'codex'):
            for field in ('command', 'message', 'thread', 'tool', 'usage', 'cost', 'cost-bool', 'cost-nan'):
                with self.subTest(harness=harness, field=field):
                    self.check(harness, 'schema-' + field)

    def test_helper_exceptions_preserve_known_and_unknown_observations(self):
        for helper in ('parse_stream', 'logs', 'snapshot', 'metrics', 'capture'):
            with self.subTest(helper=helper):
                report, evidence = self.check('codex', 'helper-' + helper, fault=helper)
                if helper == 'snapshot':
                    self.assertIsNone(evidence['phases'][-1]['state'])

    def test_second_turn_exception_keeps_earlier_turns(self):
        self.check('codex', 'helper-second-turn', fault='snapshot', fault_after=2, scenario='handoff-resume')

    def test_invalid_utf8_is_retained_byte_for_byte(self):
        for cap in (None, 100):
            with self.subTest(cap=cap):
                self.check('codex', 'bad-utf8' + ('-capped' if cap else ''), cap=cap)

    def test_nested_nonfinite_fields_do_not_escape_into_failure_evidence(self):
        for harness in ('claude', 'codex'):
            for field in ('thread-nan', 'usage-nan', 'opaque-nan'):
                with self.subTest(harness=harness, field=field):
                    report, evidence = self.check(harness, 'schema-' + field)
                    def invalid(value):
                        self.fail('Nonfinite value escaped into parsed evidence: ' + value)
                    json.loads(json.dumps(report), parse_constant=invalid)
                    json.loads(json.dumps(evidence), parse_constant=invalid)


if __name__ == '__main__':
    unittest.main()
