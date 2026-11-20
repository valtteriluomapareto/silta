"""Offline negative control: every authored failing recording fails its own trial.

Kept apart from test_evals so the eval runner can replay it alongside the passing matrix.
"""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT.parent / '.build/debug/silta'
STUB = Path(__file__).with_name('stub_harness.py')
SCENARIOS = ['start-cross-repo', 'plan-not-file', 'handoff-resume',
             'done-with-result', 'proposals-ask', 'ask-short', 'doc-context', 'doc-context-no-doc']


def expected_refusals(scenario, variant):
    if scenario == 'proposals-ask':
        if variant.startswith('absent-'):
            return ('absent_idea', 'evidence_review')
        if variant.startswith('present-'):
            return ('proposal_rows', 'approval_provenance', 'evidence_review')
        if variant == 'own-parent':
            return ('own_parent', 'proposal_rows', 'evidence_review')
        return ('proposal_rows', 'evidence_review')
    if scenario == 'ask-short':
        return ('evidence_review',) if variant in ('standard', 'repo-rule') else ('policy_choice', 'evidence_review')
    return {
        'start-cross-repo': ('backend_context',),
        'plan-not-file': ('no_plan_files', 'plan_stored', 'no_forbidden'),
        'handoff-resume': ('handoff_written', 'resume_brief_first', 'resume_task'),
        'done-with-result': ('result_template', 'result_sha'),
        'doc-context': ('doc_context',),
        'doc-context-no-doc': ('doc_context',),
    }[scenario]


class FailingRecordings(unittest.TestCase):
    def test_failing_recording_per_scenario(self):
        with tempfile.TemporaryDirectory(prefix='silta-evals-failing-') as temp:
            output = Path(temp) / 'failing'
            result = subprocess.run([str(ROOT / 'run.sh'), '--silta', str(BINARY), '--stub', str(STUB),
                                     '--output', str(output), '--repeats', '1', '--recording', 'fail'],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stderr)
            report = json.loads((output / 'report.json').read_text())
        self.assertEqual(len(report['groups']), 16)
        self.assertTrue(all(g['pass_rate'] == 0 for g in report['groups']))
        expected = {(harness, scenario, variant) for harness in ['claude', 'codex']
                    for scenario in SCENARIOS
                    for variant in json.loads((ROOT / 'scenarios' / scenario / 'scenario.yaml').read_text())['variants']}
        self.assertEqual(len(report['trials']), len(expected))
        self.assertEqual({(t['harness'], t['scenario'], t['variant']) for t in report['trials']}, expected)
        for trial in report['trials']:
            with self.subTest(harness=trial['harness'], scenario=trial['scenario'], variant=trial['variant']):
                self.assertNotIn('infrastructure', trial['checks'])
                self.assertFalse(trial['passed'])
                for check in expected_refusals(trial['scenario'], trial['variant']):
                    self.assertIs(trial['checks'].get(check), False, check)


if __name__ == '__main__':
    unittest.main()
