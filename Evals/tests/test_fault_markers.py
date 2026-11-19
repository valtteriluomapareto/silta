"""Static checks for offline mutation proofs. The working tree is read-only."""
import ast
import json
from pathlib import Path
import unittest

from plant_open_faults import FAULTS as OPEN
from plant_profile_faults import FAULTS as PROFILE

ROOT = Path(__file__).resolve().parents[1]


class FaultMarkers(unittest.TestCase):
    @unittest.expectedFailure  # #262
    def test_every_mutation_matches_once_and_compiles(self):
        source = (ROOT / 'evals.py').read_text()
        main_script = ast.parse((ROOT / 'tests/plant_faults.py').read_text())
        assignment = next(node for node in ast.walk(main_script) if isinstance(node, ast.Assign)
                          and any(isinstance(t, ast.Name) and t.id == 'replay_faults'
                                  for t in node.targets))
        replay = [(name, 'evals.py', marker, replacement, test, expected)
                  for name, marker, replacement, test, expected in ast.literal_eval(assignment.value)]
        errors = []
        for name, file, marker, replacement, *_ in (*replay, *OPEN, *PROFILE):
            original = (ROOT / file).read_text()
            if original.count(marker) != 1:
                errors.append((name, 'marker matches', original.count(marker)))
                continue
            try:
                self.assertNotEqual(marker, replacement, name)
                compile(original.replace(marker, replacement), file, 'exec')
            except SyntaxError as error:
                errors.append((name, error.msg))
        guarantees = json.loads((ROOT / 'tests/guarantees.json').read_text())
        for name in guarantees:
            lines = source.splitlines(keepends=True)
            prefix = "checks['" + name + "'] = "
            matches = [i for i, line in enumerate(lines) if prefix in line]
            if len(matches) != 1:
                errors.append((name, 'marker matches', len(matches)))
                continue
            index, = matches
            indent = lines[index][:-len(lines[index].lstrip())]
            lines[index] = indent + prefix + 'True\n'
            try:
                compile(''.join(lines), 'evals.py', 'exec')
            except SyntaxError as error:
                errors.append((name, error.msg))
        self.assertEqual(errors, [])
