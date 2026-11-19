#!/usr/bin/env python3
"""One-shot grader proof. Use an already generated passing stub report; no models."""
import ast
import json
import os
from pathlib import Path
import subprocess
import sys

from fault_source import mutated_source

ROOT = Path(__file__).resolve().parents[1]
REPLAY_FAULTS = [
('handoff_reuses_conversation', "if scenario != 'handoff-resume':", 'if True:',
     'test_review_replays.ReviewReplays.test_handoff_b_starts_a_fresh_native_conversation',
     "'stub-conversation-0' == 'stub-conversation-0'"),
    ('nonzero_child_exit_overwritten', "observed.update(exit=result['exit'],",
     'observed.update(exit=0,', 'test_review_replays.ReviewReplays.test_nonzero_child_exit_survives_successful_terminal',
     'AssertionError: 0 != 7'),
    ('blanket_synthetic_review', "'checks': checks, 'reason': reason",
     "'checks': ['tool-audit', 'policy-semantics'], 'reason': reason",
     'test_recorded_reviews.RecordedReviews.test_failing_ask_controls_reject_missing_customer_question',
     'AssertionError: True is not false : claude/standard'),
]


def faults():
    """Describe the existing guarantee and replay probes as source replacements."""
    source = (ROOT / 'evals.py').read_text()
    lines = source.splitlines(keepends=True)
    grade = next(node for node in ast.parse(source).body
                 if isinstance(node, ast.FunctionDef) and node.name == 'grade')
    assignments = [node for node in ast.walk(grade) if isinstance(node, ast.Assign)
                   and len(node.targets) == 1 and isinstance(node.targets[0], ast.Subscript)
                   and isinstance(node.targets[0].value, ast.Name) and node.targets[0].value.id == 'checks'
                   and isinstance(node.targets[0].slice, ast.Constant)]
    for name in json.loads((ROOT / 'tests/guarantees.json').read_text()):
        matches = [node for node in assignments if node.targets[0].slice.value == name]
        if len(matches) != 1:
            raise ValueError(f'Expected one grader assignment for {name}; found {len(matches)}')
        node, = matches
        marker = ''.join(lines[node.lineno - 1:node.end_lineno])
        replacement = ' ' * node.col_offset + f'checks[{name!r}] = True\n'
        yield (name, 'evals.py', marker, replacement, 'test_evals.Acceptance.test_grader_guarantees',
               f'AssertionError: True is not false : {name}')
    for name, marker, replacement, test, expected in REPLAY_FAULTS:
        yield name, 'evals.py', marker, replacement, test, expected


def main():
    report = Path(sys.argv[1]).resolve()
    results = []
    for name, file, marker, replacement, test, expected in faults():
        source = ROOT / file
        original = source.read_text()
        try:
            source.write_text(mutated_source(original, file, name, marker, replacement))
            run = subprocess.run([sys.executable, '-B', '-m', 'unittest', test], cwd=ROOT / 'tests',
                                 env=dict(os.environ, SI_EVAL_TEST_REPORT=str(report)),
                                 text=True, capture_output=True)
            detected = run.returncode != 0 and expected in run.stderr
            results.append({'guarantee': name, 'detected': detected, 'exit': run.returncode})
            if not detected:
                print(run.stdout + run.stderr)
                raise SystemExit('Fault escaped or failed before assertion: ' + name)
        finally:
            source.write_text(original)
            (report / 'planted-faults.json').write_text(json.dumps(results, indent=2) + '\n')
    print(f'Detected and restored {len(results)} independent grader/replay faults')


if __name__ == '__main__':
    main()
