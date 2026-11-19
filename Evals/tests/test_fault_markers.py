"""Compile every mutation from the three offline proofs without writing source."""
from pathlib import Path
import unittest

from fault_source import mutated_source
from plant_faults import faults
from plant_open_faults import FAULTS as OPEN
from plant_profile_faults import FAULTS as PROFILE

ROOT = Path(__file__).resolve().parents[1]


class FaultMarkers(unittest.TestCase):
    def test_every_mutation_matches_once_and_compiles(self):
        names = set()
        for name, file, marker, replacement, *_ in (*faults(), *OPEN, *PROFILE):
            with self.subTest(name=name):
                self.assertNotIn(name, names)
                names.add(name)
                original = (ROOT / file).read_text()
                self.assertNotEqual(mutated_source(original, file, name, marker, replacement),
                                    original)

    def test_missing_duplicate_and_broken_mutations_are_refused(self):
        for source in ('number = 0', 'value = 0\nvalue = 0'):
            with self.assertRaises(ValueError):
                mutated_source(source, 'fixture.py', 'ambiguous', 'value', 'number')
        with self.assertRaises(SyntaxError):
            mutated_source('value = 0', 'fixture.py', 'broken', '0', ')')
