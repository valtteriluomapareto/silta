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

import check_coded_errors  # noqa: E402
import check_core_boundary  # noqa: E402
import check_core_determinism  # noqa: E402
import check_core_hygiene  # noqa: E402
import check_docs_links  # noqa: E402
import check_no_plan_refs  # noqa: E402
import check_package_features  # noqa: E402
import check_package_graph  # noqa: E402
import check_plans_board  # noqa: E402
import check_test_waits  # noqa: E402
import check_try_optional  # noqa: E402
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


    def test_os_logging_import_fails(self) -> None:
        self.tree.write("Sources/SiltaCore/Log.swift", "import os\nimport OSLog\n")
        self.assertEqual(len(check_core_boundary.check(self.tree.root)), 2)

    def test_module_names_that_start_with_os_pass(self) -> None:
        self.tree.write("Sources/SiltaCore/A.swift", "import OSLogStore\nimport osmium\n")
        self.assertEqual(check_core_boundary.check(self.tree.root), [])


class CoreHygieneTests(GuardTestCase):
    def test_computed_statics_and_constants_pass(self) -> None:
        self.tree.write(
            "Sources/SiltaCore/A.swift",
            "let limit = 10\nenum E { static let x = 1\n  static var y: Int { 2 }\n}\n"
            "// print(\"hello\") in a comment\nlet s = \"print(x)\"\nlet f = log.print\n",
        )
        self.assertEqual(check_core_hygiene.check(self.tree.root), [])

    def test_global_mutable_state_fails(self) -> None:
        self.tree.write(
            "Sources/SiltaCore/A.swift",
            "var counter = 0\nprivate var cache: [String: Int] = [:]\n"
            "enum E { static var shared = E()\n  nonisolated(unsafe) static var x: Int = 1\n}\n",
        )
        self.assertEqual(len(check_core_hygiene.check(self.tree.root)), 4)

    def test_marker_allows_a_justified_global(self) -> None:
        self.tree.write("Sources/SiltaCore/A.swift", "static var hook = 0 // guard:allow-global test seam\n")
        self.assertEqual(check_core_hygiene.check(self.tree.root), [])

    def test_printing_in_core_fails(self) -> None:
        self.tree.write("Sources/SiltaCore/A.swift", "print(1)\ndebugPrint(2)\ndump(3)\nNSLog(\"x\")\n")
        self.assertEqual(len(check_core_hygiene.check(self.tree.root)), 4)

    def test_cli_may_print(self) -> None:
        self.tree.write("Sources/silta/Main.swift", "print(1)\nvar x = 0\n")
        self.assertEqual(check_core_hygiene.check(self.tree.root), [])


class CodedErrorsTests(GuardTestCase):
    def test_coded_errors_pass(self) -> None:
        self.tree.write(
            "Sources/SiltaCore/A.swift",
            "enum TaskError: CodedError {}\nstruct B: Equatable, CodedError {}\n"
            "protocol AreaError: CodedError {}\nenum C: AreaError {}\n// enum D: Error {}\n"
            "let s = \"enum E: Error {\"\nstruct ErrorBox: Sendable {}\nenum F: MyError {}\n",
        )
        self.assertEqual(check_coded_errors.check(self.tree.root), [])

    def test_plain_errors_fail(self) -> None:
        self.tree.write(
            "Sources/SiltaCore/A.swift",
            "private enum HomeError: Error { case bad }\nstruct B: Sendable, Swift.Error {}\n"
            "final class C: LocalizedError {}\nactor D: Error {}\nextension E: Error {}\n"
            "protocol AreaError: Error {}\n",
        )
        self.tree.write("Sources/silta/Main.swift", "enum CLIError: Error {}\n")
        self.assertEqual(len(check_coded_errors.check(self.tree.root)), 7)

    def test_marker_and_test_support_pass(self) -> None:
        self.tree.write("Sources/SiltaCore/A.swift", "public protocol CodedError: Error {}  // guard:allow-error root\n")
        self.tree.write("Sources/SiltaTestSupport/A.swift", "struct ScriptError: Error {}\n")
        self.assertEqual(check_coded_errors.check(self.tree.root), [])


class TryOptionalTests(GuardTestCase):
    def test_try_optional_with_reason_passes(self) -> None:
        self.tree.write("Sources/silta/A.swift", "try? fm.removeItem(at: tmp) // best-effort cleanup\nlet x = try f()\n")
        self.assertEqual(check_try_optional.check(self.tree.root), [])

    def test_bare_try_optional_fails(self) -> None:
        self.tree.write("Sources/SiltaCore/A.swift", "let v = try? load()\nlet w = try? load() //\n")
        self.assertEqual(len(check_try_optional.check(self.tree.root)), 2)

    def test_tests_may_use_try_optional(self) -> None:
        self.tree.write("Tests/SiltaCoreTests/A.swift", "let v = try? load()\n")
        self.assertEqual(check_try_optional.check(self.tree.root), [])


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

    def test_test_support_is_covered(self) -> None:
        self.tree.write("Sources/SiltaTestSupport/Runner.swift", "Thread.sleep(forTimeInterval: 1)\n")
        self.tree.write("Sources/silta/Main.swift", "Thread.sleep(forTimeInterval: 1)\n")
        self.assertEqual(len(check_test_waits.check(self.tree.root)), 1)


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


class PackageFeaturesTests(GuardTestCase):
    SETTINGS = (
        "let settings: [SwiftSetting] = [\n"
        + "".join(f'  .enableUpcomingFeature("{n}"),\n' for n in check_package_features.REQUIRED)
        + "]\n"
    )
    TARGETS = (
        "let package = Package(name: \"silta\", swiftLanguageModes: [.v6], targets: [\n"
        "  .target(name: \"SiltaCore\", swiftSettings: settings),\n"
        "  .executableTarget(name: \"silta\", dependencies: [.target(name: \"SiltaCore\")], swiftSettings: settings),\n"
        "  .testTarget(name: \"SiltaCoreTests\", swiftSettings: settings),\n"
        "])\n"
    )

    def test_no_package_yet_passes(self) -> None:
        self.assertEqual(check_package_features.check(self.tree.root), [])

    def test_complete_package_passes(self) -> None:
        self.tree.write("Package.swift", self.SETTINGS + self.TARGETS)
        self.assertEqual(check_package_features.check(self.tree.root), [])

    def test_missing_feature_fails(self) -> None:
        settings = self.SETTINGS.replace('  .enableUpcomingFeature("ExistentialAny"),\n', "")
        self.tree.write("Package.swift", settings + "// .enableUpcomingFeature(\"ExistentialAny\")\n" + self.TARGETS)
        self.assertEqual(len(check_package_features.check(self.tree.root)), 1)

    def test_target_without_settings_fails(self) -> None:
        targets = self.TARGETS.replace('.testTarget(name: \"SiltaCoreTests\", swiftSettings: settings)',
                                       '.testTarget(name: \"SiltaCoreTests\")')
        self.tree.write("Package.swift", self.SETTINGS + targets)
        self.assertEqual(len(check_package_features.check(self.tree.root)), 1)

    def test_missing_language_mode_fails(self) -> None:
        self.tree.write("Package.swift", self.SETTINGS + self.TARGETS.replace("swiftLanguageModes: [.v6], ", ""))
        self.assertEqual(len(check_package_features.check(self.tree.root)), 1)

    def test_experimental_feature_needs_a_decision(self) -> None:
        self.tree.write("Package.swift", self.SETTINGS + self.TARGETS
                        + 'let x: [SwiftSetting] = [.enableExperimentalFeature("Embedded")]\n')
        self.assertEqual(len(check_package_features.check(self.tree.root)), 1)
        self.tree.write("Package.swift", self.SETTINGS + self.TARGETS
                        + 'let x: [SwiftSetting] = [.enableExperimentalFeature("Embedded")]  // guard:allow-experimental D30\n')
        self.assertEqual(check_package_features.check(self.tree.root), [])


class PackageGraphTests(GuardTestCase):
    PACKAGE = (
        "let package = Package(\n"
        "  name: \"silta\",\n"
        "  products: [.executable(name: \"silta\", targets: [\"silta\"]), .library(name: \"SiltaCore\", targets: [\"SiltaCore\"])],\n"
        "  dependencies: [.package(url: \"https://example.com/GRDB.swift.git\", exact: \"7.0.0\")],\n"
        "  targets: [\n"
        "    .target(name: \"SiltaCore\", dependencies: [\n"
        "      .product(name: \"GRDB\", package: \"GRDB.swift\"),\n"
        "      .product(name: \"Yams\", package: \"Yams\"),\n"
        "    ], swiftSettings: s),\n"
        "    .executableTarget(name: \"silta\", dependencies: [\"SiltaCore\",\n"
        "      .product(name: \"ArgumentParser\", package: \"swift-argument-parser\")], swiftSettings: s),\n"
        "    .target(name: \"SiltaTestSupport\", dependencies: [\"SiltaCore\"], swiftSettings: s),\n"
        "    .testTarget(name: \"siltaTests\", dependencies: [\"SiltaCore\", \"SiltaTestSupport\"]),\n"
        "  ]\n"
        ")\n"
    )

    def test_no_package_yet_passes(self) -> None:
        self.assertEqual(check_package_graph.check(self.tree.root), [])

    def test_clean_graph_passes(self) -> None:
        self.tree.write("Package.swift", self.PACKAGE)
        self.assertEqual(check_package_graph.check(self.tree.root), [])

    def test_production_target_on_test_support_fails(self) -> None:
        self.tree.write("Package.swift", self.PACKAGE.replace('[\"SiltaCore\",\n', '[\"SiltaCore\", .target(name: \"SiltaTestSupport\"),\n'))
        self.assertEqual(len(check_package_graph.check(self.tree.root)), 1)

    def test_core_dependency_outside_the_allowlist_fails(self) -> None:
        cli = '.product(name: \"ArgumentParser\", package: \"swift-argument-parser\"),\n'
        self.tree.write("Package.swift", self.PACKAGE.replace('    ], swiftSettings: s),\n', "      " + cli + '    ], swiftSettings: s),\n', 1))
        self.assertEqual(len(check_package_graph.check(self.tree.root)), 1)

    def test_dependencies_in_a_variable_fail(self) -> None:
        self.tree.write("Package.swift", "let coreDeps: [Target.Dependency] = []\n" + self.PACKAGE.replace(
            '.target(name: \"SiltaCore\", dependencies: [\n', '.target(name: \"SiltaCore\", dependencies: coreDeps + [\n'))
        self.assertEqual(len(check_package_graph.check(self.tree.root)), 1)

    def test_dependencies_extended_after_the_literal_fail(self) -> None:
        self.tree.write("Package.swift", "let extra: [Target.Dependency] = []\n" + self.PACKAGE.replace(
            '    ], swiftSettings: s),\n', '    ] + extra, swiftSettings: s),\n', 1))
        self.assertEqual(len(check_package_graph.check(self.tree.root)), 1)

    def test_missing_core_target_fails(self) -> None:
        self.tree.write("Package.swift", self.PACKAGE.replace('name: \"SiltaCore\", dependencies: [\n', 'name: \"Core\", dependencies: [\n'))
        self.assertEqual(len(check_package_graph.check(self.tree.root)), 1)

    def test_product_exposing_test_support_fails(self) -> None:
        self.tree.write("Package.swift", self.PACKAGE.replace(
            '  dependencies: [.package(',
            '  products: [.library(name: \"Support\", targets: [\"SiltaTestSupport\"])],\n  dependencies: [.package('))
        self.assertEqual(len(check_package_graph.check(self.tree.root)), 1)

    def test_test_target_on_the_cli_fails(self) -> None:
        self.tree.write("Package.swift", self.PACKAGE.replace(
            '[\"SiltaCore\", \"SiltaTestSupport\"]', '[\"silta\", \"SiltaCore\", \"SiltaTestSupport\"]'))
        self.assertEqual(len(check_package_graph.check(self.tree.root)), 1)

    def test_commented_out_dependency_passes(self) -> None:
        self.tree.write("Package.swift", self.PACKAGE.replace(
            '      .product(name: \"Yams\", package: \"Yams\"),\n',
            '      .product(name: \"Yams\", package: \"Yams\"),\n      // \"SiltaTestSupport\", \"ArgumentParser\"\n',
        ))
        self.assertEqual(check_package_graph.check(self.tree.root), [])


class RunnerTests(unittest.TestCase):
    def test_runner_invokes_every_guard(self) -> None:
        runner = (GUARDS_DIR.parent / "run-guards.sh").read_text(encoding="utf-8")
        listed = set(re.findall(r"guards/(check_\w+\.py)", runner))
        on_disk = {p.name for p in GUARDS_DIR.glob("check_*.py")}
        self.assertEqual(listed, on_disk)


if __name__ == "__main__":
    unittest.main()
