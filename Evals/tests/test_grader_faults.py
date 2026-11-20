"""Prove selected offline grading regressions catch faults in private copies."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from fault_source import mutated_source

ROOT = Path(__file__).resolve().parents[1]
SHELL = 'test_shell_proof.ShellProof.'
OUTCOME = 'test_outcome_grading.OutcomeGrading.'
FAULTS = [
    ('plan_directory', "bool({'plan', 'plans'} & set(path.parts[:-1]))", 'False',
     SHELL + 'test_alternate_plan_destinations'),
    ('graphql_write', "if route == 'graphql':", 'if False:',
     SHELL + 'test_scoped_tracker_actions_and_graphql_mutations'),
    ('duplicate_receipt', 'if remaining[command]:', 'if command in remaining:',
     SHELL + 'test_completed_command_receipts_are_paired_once'),
    ('lost_grade', "failure.update(metrics=error.result['metrics'], violations=error.result['violations'])",
     'pass', OUTCOME + 'test_infrastructure_failure_keeps_the_completed_grade'),
    ('false_when_unknown', "'legacy_mentioned': None,\n                'silta_calls'",
     "'legacy_mentioned': False,\n                'silta_calls'",
     OUTCOME + 'test_unavailable_legacy_observation_is_unknown'),
]
RUN = 'import sys, unittest; sys.path.insert(0, sys.argv.pop(1)); unittest.main(module=None)'


class GraderFaults(unittest.TestCase):
    def test_focused_probes_fail_for_the_intended_reason(self):
        with tempfile.TemporaryDirectory(prefix='silta-grader-faults-') as scratch:
            tree = Path(scratch) / 'Evals'
            shutil.copytree(ROOT, tree, ignore=shutil.ignore_patterns('__pycache__'))
            source = tree / 'evals.py'
            original = source.read_text()
            for name, marker, replacement, test in FAULTS:
                with self.subTest(name=name):
                    command = [sys.executable, '-I', '-B', '-c', RUN, str(tree / 'tests'), test]
                    clean = subprocess.run(command, cwd=tree, capture_output=True, text=True, timeout=30)
                    self.assertEqual(clean.returncode, 0, clean.stdout + clean.stderr)
                    source.write_text(mutated_source(original, 'evals.py', name, marker, replacement))
                    try:
                        faulty = subprocess.run(
                            command, cwd=tree, capture_output=True, text=True, timeout=30)
                    finally:
                        source.write_text(original)
                    evidence = faulty.stdout + faulty.stderr
                    self.assertEqual(faulty.returncode, 1, evidence)
                    self.assertIn('FAIL: ' + test.rsplit('.', 1)[1], evidence)
                    self.assertIn('AssertionError', evidence)
