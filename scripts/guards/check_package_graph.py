"""Package.swift keeps the target graph inside its boundaries.

- Only test targets depend on SiltaTestSupport, and no product exposes it (D23).
- SiltaCore depends on nothing but CORE_DEPENDENCIES, so no UI or CLI framework can
  reach it through the graph (AGENTS.md invariant 1, D11). Adding one needs a decision.
- No target depends on the `silta` executable: CLI tests run the built binary as a
  black box (coding guidelines §6).

It fails closed: SiltaCore and SiltaTestSupport must be found, and every
`dependencies:` must be a literal array it can read. Passes when there is no
Package.swift yet.
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
CLI = "silta"
DEPENDENCIES = re.compile(r"\bdependencies\s*:")
PRODUCT = re.compile(r"\.(?:library|executable)\(")


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
    found = set()

    for match in PRODUCT.finditer(code):
        end = call_span(code, match.end() - 1)
        if any(v == TEST_SUPPORT for o, v in values if match.start() < o < end):
            line = code.count("\n", 0, match.start()) + 1
            errors.append(f"Package.swift:{line}: a product exposes {TEST_SUPPORT}; it stays internal to tests (D23)")

    declaration_end = -1
    for match in TARGET.finditer(code):
        if match.start() < declaration_end:
            continue  # a `.target(name:)` dependency inside another target's declaration
        end = call_span(code, match.end() - 1)
        declaration_end = end
        line = code.count("\n", 0, match.start()) + 1
        inside = [(o, v) for o, v in values if match.start() < o < end]
        name = next((v for o, v in inside if NAME.search(code[match.start():o])), None)
        if name is None:
            errors.append(f"Package.swift:{line}: target name is not a string literal")
            continue
        found.add(name)
        deps_match = DEPENDENCIES.search(code, match.start(), end)
        if deps_match is None:
            continue
        if not code[deps_match.end():end].lstrip().startswith("["):
            errors.append(f"Package.swift:{line}: {name}'s dependencies must be a literal array so this guard can read them")
            continue
        deps_start = code.index("[", deps_match.end())
        deps_end = closing_bracket(code, deps_start)
        deps = [
            v for o, v in inside
            if deps_start < o < deps_end and not PACKAGE.search(code[deps_start:o])
        ]
        is_test = match.group(0).startswith(".testTarget")
        if TEST_SUPPORT in deps and not is_test:
            errors.append(f"Package.swift:{line}: {name} depends on {TEST_SUPPORT}; only test targets may (D23)")
        if CLI in deps:
            errors.append(f"Package.swift:{line}: {name} depends on the {CLI} executable; run the built binary instead")
        if name == CORE:
            for dep in deps:
                if dep not in CORE_DEPENDENCIES:
                    allowed = ", ".join(sorted(CORE_DEPENDENCIES))
                    errors.append(
                        f"Package.swift:{line}: {CORE} depends on {dep}; its dependencies are limited "
                        f"to {allowed} (AGENTS.md invariant 1, D11)"
                    )
    for required in (CORE, TEST_SUPPORT):
        if required not in found:
            errors.append(f"Package.swift: no {required} target found; this guard can't check the graph without it")
    return errors


if __name__ == "__main__":
    sys.exit(run("check_package_graph", check))
