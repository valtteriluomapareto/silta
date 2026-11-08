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

    def review_input(self):
        import hashlib
        return {'scenario':'ask-short', 'recording':'fail', 'variant':'standard',
                'provenance':'stub',
                'recording_sha256':hashlib.sha256((ROOT / 'tests/recordings/ask-short-fail.json').read_bytes()).hexdigest(),
                'stub_sha256':hashlib.sha256((ROOT / 'tests/stub_harness.py').read_bytes()).hexdigest()}

    def test_authored_reviews_cover_recordings_and_each_policy_variant(self):
        import hashlib
        catalog = json.loads((ROOT / 'tests/recorded_reviews.json').read_text())
        self.assertEqual(set(catalog['recordings']), {p.stem for p in (ROOT / 'tests/recordings').glob('*.json')})
        for scenario in evals.SCENARIOS:
            variants = json.loads((ROOT / 'scenarios' / scenario / 'scenario.yaml').read_text())['variants']
            for recording in ['pass', 'fail']:
                entry = catalog['recordings'][f'{scenario}-{recording}']
                self.assertEqual(set(entry['variants']), set(variants))
                self.assertEqual(entry['sha256'], hashlib.sha256((ROOT / 'tests/recordings' / f'{scenario}-{recording}.json').read_bytes()).hexdigest())
        for variant in ['short','standard','repo-rule','other-app','delete','irreversible','money','gate']:
            outcome = catalog['recordings']['ask-short-fail']['variants'][variant]
            self.assertNotIn('policy-semantics', outcome['checks'])
            self.assertTrue(outcome['reason'])

    def test_only_reviewed_foreign_imports_have_shell_trace_certification(self):
        catalog = json.loads((ROOT / 'tests/recorded_reviews.json').read_text())
        certified = {(name, variant) for name, entry in catalog['recordings'].items()
                     for variant, outcome in entry['variants'].items()
                     if 'shell-trace' in outcome['checks']}
        self.assertEqual(certified, {('proposals-ask-pass', 'present-import'),
                                     ('proposals-ask-pass', 'present-split')})

    def test_unknown_or_changed_recorded_inputs_are_uncertified(self):
        import copy
        evidence = self.review_input()
        for key,value in [('recording','unreviewed'), ('variant','unreviewed'),
                          ('recording_sha256','0'*64), ('stub_sha256','0'*64)]:
            with self.subTest(key=key):
                changed = copy.deepcopy(evidence)
                changed[key] = value
                review = evals.recorded_review(changed)
                self.assertEqual(review['checks'], [])
                self.assertTrue(review['reason'])

    def test_oracle_is_independent_and_cannot_be_bypassed_by_renaming_reviewer(self):
        from unittest.mock import patch
        evidence = self.review_input()
        with patch.object(evals,'grade',side_effect=AssertionError('Oracle must not inspect grader output')):
            review = evals.recorded_review(evidence)
        self.assertEqual(review['checks'], ['tool-audit'])
        self.assertNotIn('policy-semantics', review['checks'])
        for reviewer in ['recorded-stub-oracle','fixture-human-reviewer']:
            evidence['review'] = {'reviewer':reviewer, 'digest':evals.review_digest(evidence),
                                  'checks':['tool-audit','policy-semantics']}
            self.assertFalse(evals.reviewed(evidence))
        # Human semantic review remains a separate path, including valid paraphrases.
        import hashlib
        evidence['recording'] = 'pass'
        evidence['recording_sha256'] = hashlib.sha256((ROOT / 'tests/recordings/ask-short-pass.json').read_bytes()).hexdigest()
        evidence['provenance'] = 'live'
        evidence['review']['reviewer'] = 'fixture-human-reviewer'
        evidence['review']['digest'] = evals.review_digest(evidence)
        self.assertTrue(evals.reviewed(evidence))
