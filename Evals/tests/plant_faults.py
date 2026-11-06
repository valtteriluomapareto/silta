#!/usr/bin/env python3
"""One-shot grader proof. Use an already generated passing stub report; no models."""
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
source = root / 'evals.py'
original = source.read_text()
report = Path(sys.argv[1]).resolve()
results = []
try:
    for guarantee in json.loads((root / 'tests/guarantees.json').read_text()):
        lines = original.splitlines(keepends=True)
        index = next(i for i, line in enumerate(lines) if "checks['" + guarantee + "'] = " in line)
        indentation = lines[index][:len(lines[index]) - len(lines[index].lstrip())]
        lines[index] = indentation + "checks['" + guarantee + "'] = True\n"
        source.write_text(''.join(lines))
        run = subprocess.run([sys.executable, '-B', '-m', 'unittest',
                              'test_evals.Acceptance.test_grader_guarantees'],
                             cwd=root / 'tests', env=dict(os.environ, SI_EVAL_TEST_REPORT=str(report)),
                             text=True, capture_output=True)
        detected = run.returncode != 0 and f'AssertionError: True is not false : {guarantee}' in run.stderr
        results.append({'guarantee': guarantee, 'detected': detected, 'exit': run.returncode})
        if not detected:
            print(run.stdout + run.stderr)
            raise SystemExit('Fault escaped or failed before assertion: ' + guarantee)
        source.write_text(original)
finally:
    source.write_text(original)
    (report / 'planted-faults.json').write_text(json.dumps(results, indent=2) + '\n')
print(f'Detected and restored {len(results)} independent grader faults')
