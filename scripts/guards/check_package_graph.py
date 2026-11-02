"""Package.swift keeps the target graph inside its boundaries.

- Only test targets depend on SiltaTestSupport (D23).
- SiltaCore depends on nothing but CORE_DEPENDENCIES, so no UI or CLI framework can
  reach it through the graph (AGENTS.md invariant 1, D11). Adding one needs a decision.

Passes when there is no Package.swift yet.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from check_package_features import TARGET, call_span
from swift_source import run, split_swift

TEST_SUPPORT = "SiltaTestSupport"
CORE = "SiltaCore"
CORE_DEPENDENCIES = {"GRDB", "Yams"}
NAME = re.compile(r"\bname\s*:\s*$")
PACKAGE = re.compile(r"\bpackage\s*:\s*$")
DEPENDENCIES = re.compile(r"\bdependencies\s*:\s*\[")


def closing_bracket(code: str, open_bracket: int) -> int:
    depth = 0
    for i in range(open_bracket, len(code)):
        if code[i] == "[":
            depth += 1
        elif code[i] == "]":
            depth -= 1
            if depth == 0:
                return i
    return len(code)


def check(root: Path) -> list[str]:
    path = root / "Package.swift"
    if not path.exists():
        return []
    raw = path.read_text(encoding="utf-8")
    literals: list[tuple[int, str]] = []
    code, _ = split_swift(raw, literals)
    # Plain one-line literals only: target and product names never need more.
    values = [(offset, text[1:-1]) for offset, text in literals if re.fullmatch(r'"[^"\\]*"', text)]
    errors = []

    declaration_end = -1
    for match in TARGET.finditer(code):
        if match.start() < declaration_end:
            continue  # a `.target(name:)` dependency inside another target's declaration
        end = call_span(code, match.end() - 1)
        declaration_end = end
        line = code.count("\n", 0, match.start()) + 1
        inside = [(o, v) for o, v in values if match.start() < o < end]
        name = next((v for o, v in inside if NAME.search(code[match.start():o])), None)
        deps_match = DEPENDENCIES.search(code, match.start(), end)
        if name is None or deps_match is None:
            continue
        deps_end = closing_bracket(code, deps_match.end() - 1)
        deps = [
            v for o, v in inside
            if deps_match.end() <= o < deps_end and not PACKAGE.search(code[deps_match.end():o])
        ]
        is_test = match.group(0).startswith(".testTarget")
        if TEST_SUPPORT in deps and not is_test:
            errors.append(f"Package.swift:{line}: {name} depends on {TEST_SUPPORT}; only test targets may (D23)")
        if name == CORE:
            for dep in deps:
                if dep not in CORE_DEPENDENCIES:
                    allowed = ", ".join(sorted(CORE_DEPENDENCIES))
                    errors.append(
                        f"Package.swift:{line}: {CORE} depends on {dep}; its dependencies are limited "
                        f"to {allowed} (AGENTS.md invariant 1, D11)"
                    )
    return errors


if __name__ == "__main__":
    sys.exit(run("check_package_graph", check))
