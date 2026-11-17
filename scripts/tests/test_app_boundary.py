import sys
import subprocess
from pathlib import Path
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "guards"))
import check_app_boundary


class AppBoundaryTests(unittest.TestCase):
    def check(self, source, location="App/SiltaApp/Probe.swift"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / location
            path.parent.mkdir(parents=True)
            path.write_text(source)
            return check_app_boundary.check(root)

    def test_support_and_apple(self):
        self.assertEqual(self.check("import SwiftUI\nimport AppKit\nimport SiltaAppSupport"), [])

    def test_forbidden_dependencies(self):
        for module in ["SiltaCore", "GRDB", "ArgumentParser", "SiltaTestSupport"]:
            self.assertTrue(self.check("import " + module), module)

    def test_scoped_import_and_comments(self):
        self.assertTrue(self.check("import struct SiltaCore.Task"))
        self.assertTrue(self.check("import\nSiltaCore"))
        self.assertTrue(self.check("import struct\nSiltaCore.Task"))
        self.assertEqual(self.check('// import SiltaCore\nlet text = "import GRDB"'), [])

    def test_tests_are_separate(self):
        self.assertEqual(self.check("import Testing", "App/SiltaAppTests/Probe.swift"), [])

    def test_cli_exit_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "App/SiltaApp/Probe.swift"
            path.parent.mkdir(parents=True)
            for source, expected in [("import SwiftUI", 0), ("import SiltaCore", 1)]:
                path.write_text(source)
                result = subprocess.run(
                    [sys.executable, "-B", check_app_boundary.__file__, "--root", str(root)],
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)
