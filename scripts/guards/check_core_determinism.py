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
def constructor(types: str, parameters: str) -> re.Pattern[str]:
    """Match explicit or contextually typed construction of a system value."""
    return re.compile(
        rf"\b(?:{types})\s*(?:\.\s*init\s*)?\(\s*{parameters}"
        rf"|\b(?:{types})\s*\??\s*(?:=(?:[^\n;{{}}]+?\?\?)?|\{{\s*(?:return\b)?)"
        rf"\s*\.\s*init\s*\(\s*{parameters}"
    )


PATTERNS = {
    "Date()": constructor("Date|NSDate", r"\)"),
    "Date.now": re.compile(
        r"\bDate\s*\.\s*now\b|(?:[:={,(?\[]|\breturn\b)\s*\.\s*now\b(?!\s*\()"
    ),
    "Date(timeIntervalSinceNow:)": constructor("Date|NSDate", r"timeIntervalSinceNow:"),
    "UUID()": constructor("UUID|NSUUID", r"\)"),
}


def check(root: Path) -> list[str]:
    errors = []
    for path in swift_files(root, CORE_DIR):
        raw = path.read_text(encoding="utf-8")
        raw_lines = raw.split("\n")
        code, _ = split_swift(raw)
        rel = path.relative_to(root)
        findings = {(code.count("\n", 0, match.start()) + 1, label)
                    for label, pattern in PATTERNS.items() for match in pattern.finditer(code)}
        for number, label in sorted(findings):
            if MARKER not in raw_lines[number - 1]:
                errors.append(f"{rel}:{number}: {label} in core; inject Clock/IDGenerator instead")
    return errors


if __name__ == "__main__":
    sys.exit(run("check_core_determinism", check))
