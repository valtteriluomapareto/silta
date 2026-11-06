"""Regression coverage for authored synthetic policy reviews, never live models."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import evals


class RecordedReviews(unittest.TestCase):
    def test_failing_ask_controls_reject_missing_customer_question(self):
        with tempfile.TemporaryDirectory(prefix='silta-policy-review-') as directory:
            output = Path(directory)
            for harness in ['claude', 'codex']:
                for variant in ['standard', 'repo-rule']:
                    with self.subTest(harness=harness, variant=variant):
                        result = evals.run_trial(ROOT.parent / '.build/debug/silta', harness,
                                                'recorded-stub', 'ask-short', variant, 1,
                                                ROOT / 'tests/stub_harness.py', output,
                                                stub=True, recording='fail')
                        evidence = json.loads((output / result['evidence']).read_text())
                        self.assertTrue(result['checks']['stream_complete'])
                        self.assertTrue(result['checks']['policy_choice'])
                        self.assertEqual(evidence['phases'][0]['messages'], ['All policies were followed.'])
                        self.assertFalse(result['passed'], f'{harness}/{variant}')
                        self.assertFalse(result['checks']['evidence_review'])
