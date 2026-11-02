"""Self-tests for the repository guards (D17).

Every guard must pass a clean tree and fail a planted violation. A guard that
silently stops matching would otherwise pass CI forever.

Run: python3 -B -m unittest discover -s scripts/tests
"""

from __future__ import annotations

import re
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

GUARDS_DIR = Path(__file__).resolve().parents[1] / "guards"
sys.path.insert(0, str(GUARDS_DIR))

import check_core_boundary  # noqa: E402
import check_core_determinism  # noqa: E402
import check_docs_links  # noqa: E402
import check_no_plan_refs  # noqa: E402
import check_plans_board  # noqa: E402
import check_test_waits  # noqa: E402
from swift_source import split_swift  # noqa: E402


class Tree:
    """A disposable repository skeleton."""

    def __init__(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def write(self, rel: str, content: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(content), encoding="utf-8")

    def close(self) -> None:
        self._tmp.cleanup()


class GuardTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tree = Tree()

    def tearDown(self) -> None:
        self.tree.close()


class SplitSwiftTests(unittest.TestCase):
    def test_separates_comments_and_strings_from_code(self) -> None:
        code, comments = split_swift('let a = "Date()" // UUID()\n/* import SwiftUI */ let b = 1\n')
        self.assertNotIn("Date()", code)
        self.assertNotIn("UUID()", code)
        self.assertNotIn("SwiftUI", code)
        self.assertIn("let b = 1", code)
        self.assertEqual([c[0] for c in comments], [1, 2])

    def test_keeps_line_numbers_across_multiline_strings(self) -> None:
        code, _ = split_swift('let s = """\nDate()\n"""\nlet t = Date()\n')
        self.assertEqual(code.count("\n"), 4)
        self.assertEqual(code.split("\n")[3].strip(), "let t = Date()")

    def test_raw_strings_and_escapes(self) -> None:
        code, _ = split_swift('let r = #"a "quoted" UUID()"#\nlet e = "\\"UUID()"\nlet x = UUID()\n')
        self.assertEqual(code.count("UUID()"), 1)


class CoreBoundaryTests(GuardTestCase):
    def test_clean_core_passes(self) -> None:
        self.tree.write("Sources/SiltaCore/Task.swift", "import Foundation\n// import SwiftUI is banned\n")
        self.assertEqual(check_core_boundary.check(self.tree.root), [])

    def test_ui_import_fails(self) -> None:
        self.tree.write("Sources/SiltaCore/View.swift", "import Foundation\nimport SwiftUI\n")
        self.assertEqual(len(check_core_boundary.check(self.tree.root)), 1)

    def test_attributed_and_scoped_imports_fail(self) -> None:
        self.tree.write(
            "Sources/SiltaCore/A.swift",
            "@preconcurrency import AppKit\nimport struct ArgumentParser.Flag\n",
        )
        self.assertEqual(len(check_core_boundary.check(self.tree.root)), 2)

    def test_cli_target_may_import_argument_parser(self) -> None:
        self.tree.write("Sources/silta/Main.swift", "import ArgumentParser\n")
        self.assertEqual(check_core_boundary.check(self.tree.root), [])


class CoreDeterminismTests(GuardTestCase):
    def test_injected_clock_passes(self) -> None:
        self.tree.write("Sources/SiltaCore/A.swift", 'let t = clock.now()\nlet s = "Date()"\n')
        self.assertEqual(check_core_determinism.check(self.tree.root), [])

    def test_wall_clock_and_random_ids_fail(self) -> None:
        self.tree.write(
            "Sources/SiltaCore/A.swift",
            "let t = Date()\nlet u = Date.now\nlet i = UUID()\n",
        )
        self.assertEqual(len(check_core_determinism.check(self.tree.root)), 3)

    def test_marker_allows_the_system_seam(self) -> None:
        self.tree.write(
            "Sources/SiltaCore/SystemClock.swift",
            "func now() -> Date { Date() } // guard:allow-nondeterminism system clock\n",
        )
        self.assertEqual(check_core_determinism.check(self.tree.root), [])


class TestWaitsTests(GuardTestCase):
    def test_fake_clock_passes(self) -> None:
        self.tree.write("Tests/SiltaCoreTests/A.swift", "clock.advance(by: .seconds(5))\n// Task.sleep is banned\n")
        self.assertEqual(check_test_waits.check(self.tree.root), [])

    def test_wall_clock_waits_fail(self) -> None:
        self.tree.write(
            "Tests/SiltaCoreTests/A.swift",
            "try await Task.sleep(for: .seconds(1))\nsleep(1)\nThread.sleep(forTimeInterval: 1)\n"
            "DispatchQueue.main.asyncAfter(deadline: .now()) {}\n",
        )
        self.assertEqual(len(check_test_waits.check(self.tree.root)), 4)

    def test_marker_allows_a_justified_wait(self) -> None:
        self.tree.write("Tests/Stress/A.swift", "usleep(100) // guard:allow-wait real process race\n")
        self.assertEqual(check_test_waits.check(self.tree.root), [])


class NoPlanRefsTests(GuardTestCase):
    def test_stable_references_pass(self) -> None:
        self.tree.write("Sources/SiltaCore/A.swift", "// Claims are compare-and-set (D9, spec §8).\nlet m1 = 1\n")
        self.assertEqual(check_no_plan_refs.check(self.tree.root), [])

    def test_plan_bookkeeping_fails(self) -> None:
        self.tree.write(
            "Sources/SiltaCore/A.swift",
            "// TODO phase 2\n// Done in M2\n// fixes review item 4\n// see the plan for details\n// slice S7\n",
        )
        self.assertEqual(len(check_no_plan_refs.check(self.tree.root)), 5)


class DocsLinksTests(GuardTestCase):
    def test_resolving_links_pass(self) -> None:
        self.tree.write("docs/a.md", "[b](b.md) [web](https://example.com) [anchor](#x) `[c](missing.md)`\n")
        self.tree.write("docs/b.md", "[up](../README.md#top)\n")
        self.tree.write("README.md", "```\n[ignored](nowhere.md)\n```\n")
        self.assertEqual(check_docs_links.check(self.tree.root), [])

    def test_broken_link_fails(self) -> None:
        self.tree.write("docs/a.md", "See [missing](missing.md).\n")
        self.assertEqual(len(check_docs_links.check(self.tree.root)), 1)


class PlansBoardTests(GuardTestCase):
    BOARD = "<!-- plans-board:start -->\n| [`plans/a.md`](plans/a.md) | active |\n<!-- plans-board:end -->\n"

    def test_board_matching_folder_passes(self) -> None:
        self.tree.write("docs/README.md", self.BOARD)
        self.tree.write("docs/plans/a.md", "# A\n")
        self.tree.write("docs/plans/README.md", "rules\n")
        self.tree.write("docs/plans/_template.md", "template\n")
        self.assertEqual(check_plans_board.check(self.tree.root), [])

    def test_unregistered_plan_fails(self) -> None:
        self.tree.write("docs/README.md", self.BOARD)
        self.tree.write("docs/plans/a.md", "# A\n")
        self.tree.write("docs/plans/b.md", "# B\n")
        self.assertEqual(len(check_plans_board.check(self.tree.root)), 1)

    def test_row_without_file_fails(self) -> None:
        self.tree.write("docs/README.md", self.BOARD)
        self.assertEqual(len(check_plans_board.check(self.tree.root)), 1)

    def test_missing_markers_fail(self) -> None:
        self.tree.write("docs/README.md", "no board here\n")
        self.assertEqual(len(check_plans_board.check(self.tree.root)), 1)


class RunnerTests(unittest.TestCase):
    def test_runner_invokes_every_guard(self) -> None:
        runner = (GUARDS_DIR.parent / "run-guards.sh").read_text(encoding="utf-8")
        listed = set(re.findall(r"guards/(check_\w+\.py)", runner))
        on_disk = {p.name for p in GUARDS_DIR.glob("check_*.py")}
        self.assertEqual(listed, on_disk)


if __name__ == "__main__":
    unittest.main()
