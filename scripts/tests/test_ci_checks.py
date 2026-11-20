"""Self-tests for the CI checks in scripts/ci/ (D17).

Run: python3 -B -m unittest discover -s scripts/tests
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ci"))

import check_bug_fix_tests  # noqa: E402
import check_verify_gate  # noqa: E402


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


class VerifyGateTests(unittest.TestCase):
    ALL_RAN = {"CHANGES": "success", "CODE": "true", "WEBSITE": "true",
               "SWIFT": "success", "EVALS": "success", "APP": "success", "SITE": "success"}

    def gate(self, **changes: str) -> list[str]:
        return check_verify_gate.check({**self.ALL_RAN, **changes})

    def test_needed_jobs_succeeding_pass(self) -> None:
        self.assertEqual(self.gate(), [])

    def test_website_only_change_passes_with_swift_jobs_skipped(self) -> None:
        self.assertEqual(self.gate(CODE="false", SWIFT="skipped", EVALS="skipped", APP="skipped"), [])

    def test_code_only_change_passes_with_website_skipped(self) -> None:
        self.assertEqual(self.gate(WEBSITE="false", SITE="skipped"), [])

    def test_needed_job_failing_or_cancelled_fails(self) -> None:
        self.assertEqual(len(self.gate(APP="failure")), 1)
        self.assertEqual(len(self.gate(SITE="cancelled")), 1)

    def test_needed_job_skipped_fails(self) -> None:
        self.assertEqual(len(self.gate(SWIFT="skipped")), 1)

    def test_job_that_ran_without_being_needed_fails(self) -> None:
        self.assertEqual(len(self.gate(WEBSITE="false")), 1)

    def test_failed_changes_job_fails(self) -> None:
        skipped = {job: "skipped" for job in ("SWIFT", "EVALS", "APP", "SITE")}
        self.assertEqual(len(self.gate(CHANGES="failure", CODE="", WEBSITE="", **skipped)), 1)

    def test_unknown_changes_output_fails_rather_than_skipping_everything(self) -> None:
        skipped = {job: "skipped" for job in ("SWIFT", "EVALS", "APP", "SITE")}
        self.assertEqual(len(self.gate(CODE="", WEBSITE="yes", **skipped)), 2)


if __name__ == "__main__":
    unittest.main()
