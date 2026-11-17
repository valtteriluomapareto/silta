"""Acceptance for app dependency pins and fail-closed test evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "guards"))
import check_app_pins
spec = importlib.util.spec_from_file_location("app_results", Path(__file__).resolve().parents[1] / "check-app-test-results.py")
results = importlib.util.module_from_spec(spec)
spec.loader.exec_module(results)


class AppPinsTests(unittest.TestCase):
    def pins(self, app):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            value = {"pins": [{"identity": "yams", "state": {"version": "6.2.2", "revision": "abc"}}], "version": 3}
            (root / "Package.resolved").write_text(json.dumps(value))
            path = root / "App/SiltaApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(app if app is not None else value))
            return check_app_pins.check(root)

    def test_matching_pins(self):
        self.assertEqual(self.pins(None), [])

    @unittest.expectedFailure
    def test_missing_pin_refuses(self):
        self.assertTrue(self.pins({"pins": [], "version": 3}))

    @unittest.expectedFailure
    def test_mismatched_pin_refuses(self):
        self.assertTrue(self.pins({"pins": [{"identity": "yams", "state": {"version": "6.2.3", "revision": "def"}}], "version": 3}))


class AppResultTests(unittest.TestCase):
    def valid(self):
        return ({"result": "Passed", "totalTestCount": 1, "passedTests": 1,
                 "failedTests": 0, "skippedTests": 0, "expectedFailures": 0},
                {"testNodes": [{"nodeType": "Test Suite", "name": "AppStartupTests", "result": "Passed",
                  "children": [{"nodeType": "Test Case", "name": "startup()", "result": "Passed"}]}]})

    def test_success(self):
        self.assertEqual(results.check(*self.valid(), ["AppStartupTests"]), [])

    @unittest.expectedFailure
    def test_zero_tests(self):
        summary, tests = self.valid()
        summary.update(totalTestCount=0, passedTests=0)
        self.assertTrue(results.check(summary, tests, ["AppStartupTests"]))

    @unittest.expectedFailure
    def test_failure_skip_and_expected_failure(self):
        for field in ("failedTests", "skippedTests", "expectedFailures"):
            summary, tests = self.valid()
            summary[field] = 1
            self.assertTrue(results.check(summary, tests, ["AppStartupTests"]), field)

    @unittest.expectedFailure
    def test_missing_suite(self):
        self.assertTrue(results.check(*self.valid(), ["MissingTests"]))

    @unittest.expectedFailure
    def test_malformed_and_unsupported(self):
        for summary, tests in (({}, {}), ([], []), ({"result": "unknown"}, {"testNodes": []})):
            self.assertTrue(results.check(summary, tests, ["AppStartupTests"]))
