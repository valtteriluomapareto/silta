"""Self-tests for scripts/run-eval-tests.py, the parallel eval test runner.

Run: python3 -B -m unittest discover -s scripts/tests
"""

from __future__ import annotations

import importlib.util
import io
import sys
import tempfile
import textwrap
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "run_eval_tests", Path(__file__).resolve().parents[1] / "run-eval-tests.py")
assert _spec and _spec.loader
run_eval_tests = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = run_eval_tests  # dataclasses look their module up by name
_spec.loader.exec_module(run_eval_tests)

PASSING = """
import unittest
class Passing(unittest.TestCase):
    def test_one(self): pass
    def test_two(self): pass
"""
FAILING = """
import unittest
class Failing(unittest.TestCase):
    def test_wrong(self): self.assertEqual(1, 2, "acme mismatch")
"""
EMPTY = """
import unittest
class Empty(unittest.TestCase):
    pass
"""
BROKEN_IMPORT = "import acme_module_that_does_not_exist\n"
SKIPPING = """
import unittest
class Skipping(unittest.TestCase):
    def test_one(self): pass
    @unittest.skip("acme not ready")
    def test_two(self): pass
"""
HANGING = """
import subprocess, sys, time, unittest
class Hanging(unittest.TestCase):
    def test_hangs(self):
        print("acme partial", flush=True)
        subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        time.sleep(60)
"""
HELPER = "ACME_VALUE = 7\n"
USES_HELPER = """
import unittest
import acme_helper
class UsesHelper(unittest.TestCase):
    def test_value(self): self.assertEqual(acme_helper.ACME_VALUE, 7)
"""


class RunEvalTestsTests(unittest.TestCase):
    def run_dir(self, modules: dict[str, str], jobs: int = 2, timeout: float = 60) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as temp:
            for name, body in modules.items():
                (Path(temp) / f"{name}.py").write_text(textwrap.dedent(body))
            out = io.StringIO()
            with redirect_stdout(out), redirect_stderr(out):
                code = run_eval_tests.run_all(Path(temp), jobs, timeout)
            return code, out.getvalue()

    def test_every_module_runs_and_counts_add_up(self) -> None:
        code, out = self.run_dir({"test_a": PASSING, "test_b": PASSING, "test_c": PASSING})
        self.assertEqual(code, 0, out)
        for name in ["test_a", "test_b", "test_c"]:
            self.assertIn(f"ok   {name}: 2 tests", out)
        self.assertIn("6 tests in 3 modules passed", out)

    def test_only_test_modules_run(self) -> None:
        code, out = self.run_dir({"test_a": PASSING, "helper": FAILING})
        self.assertEqual(code, 0, out)
        self.assertIn("1 modules", out)
        self.assertNotIn("helper", out)

    def test_failing_module_fails_the_run_and_shows_its_output(self) -> None:
        code, out = self.run_dir({"test_a": PASSING, "test_b": FAILING})
        self.assertEqual(code, 1)
        self.assertIn("FAIL test_b", out)
        self.assertIn("acme mismatch", out)
        self.assertIn("1 of 2 modules failed: test_b", out)

    def test_module_with_no_tests_fails(self) -> None:
        code, out = self.run_dir({"test_a": PASSING, "test_empty": EMPTY})
        self.assertEqual(code, 1)
        self.assertIn("FAIL test_empty: 0 tests", out)
        self.assertIn("ran no tests", out)

    def test_module_that_cannot_import_fails(self) -> None:
        code, out = self.run_dir({"test_broken": BROKEN_IMPORT})
        self.assertEqual(code, 1)
        self.assertIn("FAIL test_broken", out)
        self.assertIn("acme_module_that_does_not_exist", out)

    def test_directory_without_modules_fails(self) -> None:
        code, out = self.run_dir({"helper": PASSING})
        self.assertEqual(code, 1)
        self.assertIn("no test*.py modules", out)

    def test_module_that_skips_a_test_fails(self) -> None:
        code, out = self.run_dir({"test_skip": SKIPPING})
        self.assertEqual(code, 1)
        self.assertIn("FAIL test_skip: 2 tests", out)
        self.assertIn("skipped tests", out)

    def test_hung_module_is_killed_with_its_children_and_shows_partial_output(self) -> None:
        started = time.monotonic()
        code, out = self.run_dir({"test_a": PASSING, "test_hang": HANGING}, timeout=2)
        self.assertLess(time.monotonic() - started, 30)
        self.assertEqual(code, 1)
        self.assertIn("FAIL test_hang: 0 tests", out)
        self.assertIn("timed out after", out)
        self.assertIn("acme partial", out)
        self.assertIn("ok   test_a: 2 tests", out)

    def test_module_imports_a_sibling_helper(self) -> None:
        code, out = self.run_dir({"acme_helper": HELPER, "test_uses": USES_HELPER})
        self.assertEqual(code, 0, out)
        self.assertIn("ok   test_uses: 1 tests", out)

    def test_discover_pattern_modules_without_underscore_run(self) -> None:
        code, out = self.run_dir({"testacme": PASSING})
        self.assertEqual(code, 0, out)
        self.assertIn("ok   testacme: 2 tests", out)

    def test_one_job_runs_modules_one_at_a_time(self) -> None:
        code, out = self.run_dir({"test_a": PASSING, "test_b": PASSING}, jobs=1)
        self.assertEqual(code, 0, out)
        self.assertIn("2 modules, 1 at a time", out)


if __name__ == "__main__":
    unittest.main()
