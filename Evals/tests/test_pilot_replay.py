"""Offline regrading of sanitized native pilot bytes, never a model invocation."""
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import evals


def replay(folder):
    evidence = json.loads((folder / 'evidence.json').read_text())
    recorded_logs = json.loads((folder / 'command-log.json').read_text())
    for number, phase in enumerate(evidence['phases']):
        observed_logs = [row for row in recorded_logs if row['actor'] == phase['actor']]
        if observed_logs != phase['logs']:
            raise AssertionError('Snapshot/native command-log disagreement')
        phase['logs'] = observed_logs
        phase.update(evals.parse_stream('codex', (folder / f'phase-{number}.jsonl').read_text()))
    return evidence


class PilotReplay(unittest.TestCase):
    def test_four_native_pilot_trials_grade_without_crashing(self):
        folders = list((ROOT / 'tests/pilot/400k').iterdir())
        self.assertEqual(len(folders), 4)
        for folder in folders:
            with self.subTest(trial=folder.name):
                evidence = replay(folder)
                result = evals.grade(evidence)
                # Cap-stopped streams still fail; successful native turns do not.
                if evidence['scenario'] == 'done-with-result':
                    self.assertTrue(result['checks']['stream_complete'])
                    self.assertTrue(result['checks']['result_sha'])
                    self.assertTrue(result['checks']['result_template'])
                elif evidence['scenario'] == 'start-cross-repo':
                    # Native completions/logs interleave: this is a real ordered
                    # trace mismatch, independently of the shell parser.
                    self.assertFalse(result['checks']['stream_complete'])
                else:
                    self.assertFalse(result['checks']['infrastructure'])
                self.assertFalse(result['passed'], 'Live pilot has no bound tool-audit review')
                if evidence['scenario'] == 'handoff-resume':
                    calls = evidence['phases'][0]['commands']
                    bad = next(c for c in calls if "acme'-eval" in c)
                    self.assertTrue(evals.parse_shell(bad).opaque)
                    # Exercise the helpers the infrastructure short circuit skips.
                    evals.forbidden(evidence)
                    evals.usage_errors(evidence['phases'])

    def test_capped_forbidden_count_and_list_are_the_same_observation(self):
        folder = next((ROOT / 'tests/pilot/cap50k').iterdir())
        evidence = replay(folder)
        self.assertTrue(evals.forbidden(evidence))
        result = evals.grade(evidence)
        self.assertEqual(result['violations'], evals.forbidden(evidence))
        self.assertEqual(result['metrics']['forbidden_attempts'], len(result['violations']))


if __name__ == '__main__':
    unittest.main()
