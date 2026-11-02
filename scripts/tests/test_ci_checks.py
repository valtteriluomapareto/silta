"""Self-tests for the CI checks in scripts/ci/ (D17).

Run: python3 -B -m unittest discover -s scripts/tests
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ci"))

import check_bug_fix_tests  # noqa: E402


class BugFixTestsTests(unittest.TestCase):
    def test_fix_with_a_test_passes(self) -> None:
        changed = ["Sources/SiltaCore/Tasks/Claim.swift", "Tests/SiltaCoreTests/Tasks/ClaimTests.swift"]
        self.assertEqual(check_bug_fix_tests.check(changed), [])

    def test_fix_with_a_scenario_passes(self) -> None:
        self.assertEqual(check_bug_fix_tests.check(["Sources/silta/Main.swift", "Tests/Scenarios/claim-race.yaml"]), [])

    def test_fix_without_a_test_fails(self) -> None:
        changed = ["Sources/SiltaCore/Tasks/Claim.swift", "docs/spec.md", "Sources/SiltaTestSupport/FakeClock.swift"]
        self.assertEqual(len(check_bug_fix_tests.check(changed)), 1)

    def test_empty_diff_fails(self) -> None:
        self.assertEqual(len(check_bug_fix_tests.check(["", "  "])), 1)


if __name__ == "__main__":
    unittest.main()
