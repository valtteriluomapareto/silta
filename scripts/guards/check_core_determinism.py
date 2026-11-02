"""Core code takes time and ids from injected seams (AGENTS.md invariant 2, D13).

A deliberate exception (the system clock or id generator itself) carries the marker
`guard:allow-nondeterminism` on the same line.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from swift_source import run, split_swift, swift_files

CORE_DIR = "Sources/SiltaCore"
MARKER = "guard:allow-nondeterminism"
PATTERNS = {
    "Date()": re.compile(r"\bDate\(\s*\)"),
    "Date.now": re.compile(r"\bDate\.now\b"),
    "Date(timeIntervalSinceNow:)": re.compile(r"\bDate\(\s*timeIntervalSinceNow:"),
    "UUID()": re.compile(r"\bUUID\(\s*\)"),
}


def check(root: Path) -> list[str]:
    errors = []
    for path in swift_files(root, CORE_DIR):
        raw = path.read_text(encoding="utf-8")
        raw_lines = raw.split("\n")
        code, _ = split_swift(raw)
        for number, code_line in enumerate(code.split("\n"), start=1):
            if MARKER in raw_lines[number - 1]:
                continue
            for label, pattern in PATTERNS.items():
                if pattern.search(code_line):
                    rel = path.relative_to(root)
                    errors.append(f"{rel}:{number}: {label} in core; inject Clock/IDGenerator instead")
    return errors


if __name__ == "__main__":
    sys.exit(run("check_core_determinism", check))
