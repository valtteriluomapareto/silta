"""SiltaCore has no global mutable state and no direct printing or logging
(AGENTS.md invariant 5; D21, D27).

- Stored `static var` / `class var` and top-level `var` are shared mutable state.
  Computed properties (`static var x: T { … }`) are fine. A deliberate exception
  carries `guard:allow-global` on the same line.
- Output goes through the output layer and logging through the `Log` seam, so
  `print`, `debugPrint`, `dump` and `NSLog` are not used in the core.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from swift_source import run, split_swift, swift_files

CORE_DIR = "Sources/SiltaCore"
MARKER = "guard:allow-global"
MODIFIERS = r"(?:(?:public|package|internal|fileprivate|private|nonisolated(?:\(unsafe\))?|@\w+)\s+)*"
STATIC_VAR = re.compile(r"\b(?:static|class)\s+" + MODIFIERS + r"var\b")
TOP_LEVEL_VAR = re.compile(r"^" + MODIFIERS + r"var\b")
OUTPUT = re.compile(r"(?<![\w.])(print|debugPrint|dump|NSLog)\s*\(")


def is_stored(code_line: str) -> bool:
    """A `var` declaration is stored unless it is a computed property (`{` with no `=`)."""
    return "=" in code_line or "{" not in code_line


def check(root: Path) -> list[str]:
    errors = []
    for path in swift_files(root, CORE_DIR):
        raw_lines = path.read_text(encoding="utf-8").split("\n")
        code, _ = split_swift("\n".join(raw_lines))
        rel = path.relative_to(root)
        for number, line in enumerate(code.split("\n"), start=1):
            raw = raw_lines[number - 1]
            if (STATIC_VAR.search(line) or TOP_LEVEL_VAR.match(line)) and is_stored(line):
                if MARKER not in raw:
                    errors.append(f"{rel}:{number}: global mutable state; pass it through SiltaEnvironment")
            match = OUTPUT.search(line)
            if match:
                errors.append(f"{rel}:{number}: {match.group(1)}() in core; use the Log seam or the output layer")
    return errors


if __name__ == "__main__":
    sys.exit(run("check_core_hygiene", check))
