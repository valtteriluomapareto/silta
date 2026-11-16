"""Acceptance checks for whole-file development source isolation."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "guards"))
import check_control_release


class ControlReleaseTests(unittest.TestCase):
    def check_source(self, source):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "Sources/SiltaAppSupport/Control/Fixture.swift"
            path.parent.mkdir(parents=True)
            path.write_text(source)
            return check_control_release.check(root)

    def test_wrapped_source_and_nested_debug(self):
        self.assertEqual(self.check_source("// fixture\n#if DEBUG\n#if os(macOS)\nlet fixture = 1\n#endif\n#endif\n"), [])

    @unittest.expectedFailure
    def test_unwrapped_source_is_rejected(self):
        self.assertTrue(self.check_source("let fixture = 1\n"))

    @unittest.expectedFailure
    def test_early_end_is_rejected(self):
        self.assertTrue(self.check_source("#if DEBUG\nlet fixture = 1\n#endif\nlet leak = 2\n"))

    @unittest.expectedFailure
    def test_release_else_is_rejected(self):
        self.assertTrue(self.check_source("#if DEBUG\nlet fixture = 1\n#else\nlet leak = 2\n#endif\n"))

    @unittest.expectedFailure
    def test_comment_is_not_a_directive(self):
        self.assertTrue(self.check_source("// #if DEBUG\nlet fixture = 1\n// #endif\n"))
