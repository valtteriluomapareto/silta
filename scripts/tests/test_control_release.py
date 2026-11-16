"""Acceptance checks for whole-file development source isolation."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "guards"))
import check_control_release


class ControlReleaseTests(unittest.TestCase):
    def check_source(self, source, relative="Sources/SiltaAppSupport/Control/Fixture.swift"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / relative
            path.parent.mkdir(parents=True)
            path.write_text(source)
            return check_control_release.check(root)

    def test_wrapped_source_and_nested_debug(self):
        self.assertEqual(self.check_source("// fixture\n#if DEBUG\n#if os(macOS)\nlet fixture = 1\n#endif\n#endif\n"), [])

    def test_unwrapped_source_is_rejected(self):
        self.assertTrue(self.check_source("let fixture = 1\n"))

    def test_early_end_is_rejected(self):
        self.assertTrue(self.check_source("#if DEBUG\nlet fixture = 1\n#endif\nlet leak = 2\n"))

    def test_release_else_is_rejected(self):
        self.assertTrue(self.check_source("#if DEBUG\nlet fixture = 1\n#else\nlet leak = 2\n#endif\n"))

    def test_comment_is_not_a_directive(self):
        self.assertTrue(self.check_source("// #if DEBUG\nlet fixture = 1\n// #endif\n"))

    def test_app_core_and_script_sources_are_covered(self):
        for relative in ("App/SiltaApp/Control/Launch.swift", "Sources/SiltaCore/Control/Seed.swift", "scripts/Control/Shot.swift", "Tests/SiltaAppSupportTests/Control/Fixture.swift"):
            with self.subTest(relative=relative):
                self.assertTrue(self.check_source("let leak = 1\n", relative))

    def test_release_elseif_is_rejected(self):
        self.assertTrue(self.check_source("#if DEBUG\nlet fixture = 1\n#elseif os(macOS)\nlet leak = 2\n#endif\n"))

    def test_empty_control_file_is_rejected(self):
        self.assertTrue(self.check_source(""))

    def test_source_outside_control_is_unchanged(self):
        self.assertEqual(self.check_source("let value = 1\n", "App/SiltaApp/Main.swift"), [])

    def test_empty_tree_is_valid(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(check_control_release.check(Path(directory)), [])
