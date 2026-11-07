#!/usr/bin/env python3
"""Dispatch actual eval entry points to the repository fake client only."""
import json
import os
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
args = sys.argv[1:]
index = args.index('--model') + 1
assert args[index] in ('fixture-pass', 'fixture-fail'), 'Only explicit fixture models allowed'
recording = args[index].removeprefix('fixture-')
actor = os.environ['SILTA_ACTOR'].removeprefix('agent:codex:codex-')
for path in (root / 'scenarios').glob('*/scenario.yaml'):
    scenario = json.loads(path.read_text())
    prefix = scenario['id'] + '-'
    if actor.startswith(prefix):
        variant = actor.removeprefix(prefix).rsplit('-', 2)[0]
        assert variant in scenario['variants']
        args[index] = f"fake:{scenario['id']}:{variant}:{recording}:plain"
        os.execv(sys.executable, [sys.executable, '-B', str(root / 'tests/fake_codex.py'), *args])
raise AssertionError('Unknown fixture trial actor')
