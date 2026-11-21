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
        rf"|\b(?:{types})\s*\??\s*(?:=|\{{\s*(?:return\b)?)"
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


TYPED_EXPRESSION = re.compile(
    r"\b(Date|NSDate|UUID|NSUUID)\s*\??\s*(?:=(?!=)|\{\s*(?:return\b)?)\s*"
)
EXPRESSION_TOKENS = re.compile(r"\?\?|[][(){};,\n]")
FALLBACK_INIT = re.compile(r"\s*\.\s*init\s*\(\s*(\)|timeIntervalSinceNow:)")


def fallback_constructors(code: str):
    """Recognize an empty system initializer in the outer typed expression."""
    for context in TYPED_EXPRESSION.finditer(code):
        depth = 0
        for token in EXPRESSION_TOKENS.finditer(code, context.end()):
            operator = token[0]
            if operator in "([":
                depth += 1
            elif operator in ")]" and depth:
                depth -= 1
            elif not depth:
                if operator != "??":
                    break
                fallback = FALLBACK_INIT.match(code, token.end())
                if not fallback:
                    continue
                date = context[1] in ("Date", "NSDate")
                if date or fallback[1] == ")":
                    name = "Date" if date else "UUID"
                    signature = "()" if fallback[1] == ")" else "(timeIntervalSinceNow:)"
                    yield context.start(), name + signature
                break


def check(root: Path) -> list[str]:
    errors = []
    for path in swift_files(root, CORE_DIR):
        raw = path.read_text(encoding="utf-8")
        raw_lines = raw.split("\n")
        code, _ = split_swift(raw)
        rel = path.relative_to(root)
        findings = {(code.count("\n", 0, match.start()) + 1, label)
                    for label, pattern in PATTERNS.items() for match in pattern.finditer(code)}
        findings.update((code.count("\n", 0, start) + 1, label)
                        for start, label in fallback_constructors(code))
        for number, label in sorted(findings):
            if MARKER not in raw_lines[number - 1]:
                errors.append(f"{rel}:{number}: {label} in core; inject Clock/IDGenerator instead")
    return errors


if __name__ == "__main__":
    sys.exit(run("check_core_determinism", check))
