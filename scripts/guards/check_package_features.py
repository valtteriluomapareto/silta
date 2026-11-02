"""Package.swift enables the Swift 7 upcoming features on every target and uses no
experimental features without a decision (D29).

Passes when there is no Package.swift yet. Otherwise:
- every feature in REQUIRED appears as `.enableUpcomingFeature("…")`
- Swift 6 language mode is set
- every target declaration passes `swiftSettings:`
- `enableExperimentalFeature` only with `guard:allow-experimental D<n>` on the same line
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from swift_source import run, split_swift

REQUIRED = (
    "ExistentialAny",
    "InternalImportsByDefault",
    "MemberImportVisibility",
    "InferIsolatedConformances",
    "NonisolatedNonsendingByDefault",
    "ImmutableWeakCaptures",
)
UPCOMING = re.compile(r"\.enableUpcomingFeature\(")
EXPERIMENTAL = re.compile(r"\.enableExperimentalFeature\(")
MARKER = re.compile(r"guard:allow-experimental\s+D\d+")
LANGUAGE_MODE = re.compile(r"swiftLanguageModes?\s*:\s*\[?\s*\.v6|\.swiftLanguageMode\(\s*\.v6\s*\)")
TARGET = re.compile(r"\.(?:target|executableTarget|testTarget)\(")


def call_span(code: str, open_paren: int) -> int:
    """Index just past the parenthesis that closes the one at `open_paren`."""
    depth = 0
    for i in range(open_paren, len(code)):
        if code[i] == "(":
            depth += 1
        elif code[i] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
    return len(code)


def check(root: Path) -> list[str]:
    path = root / "Package.swift"
    if not path.exists():
        return []
    raw = path.read_text(encoding="utf-8")
    code, _ = split_swift(raw)
    raw_lines = raw.split("\n")
    errors = []

    enabled = set()
    for match in UPCOMING.finditer(code):
        # Match the literal in the raw text: in `code` the string is blanked to spaces.
        literal = re.match(r'\s*"([^"]*)"', raw[match.end():])
        if literal:
            enabled.add(literal.group(1))
    for name in REQUIRED:
        if name not in enabled:
            errors.append(f'Package.swift: missing .enableUpcomingFeature("{name}")')

    if not LANGUAGE_MODE.search(code):
        errors.append("Package.swift: Swift 6 language mode (.v6) is not set")

    declaration_end = -1
    for match in TARGET.finditer(code):
        if match.start() < declaration_end:
            continue  # a `.target(name:)` dependency inside another target's declaration
        end = call_span(code, match.end() - 1)
        declaration_end = end
        if "swiftSettings" not in code[match.start():end]:
            line = code.count("\n", 0, match.start()) + 1
            errors.append(f"Package.swift:{line}: target without swiftSettings (it would miss the upcoming features)")

    for match in EXPERIMENTAL.finditer(code):
        line = code.count("\n", 0, match.start()) + 1
        if not MARKER.search(raw_lines[line - 1]):
            errors.append(f"Package.swift:{line}: experimental feature without `guard:allow-experimental D<n>`")
    return errors


if __name__ == "__main__":
    sys.exit(run("check_package_features", check))
