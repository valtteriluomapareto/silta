"""Tests never wait on the wall clock (AGENTS.md invariant 3).

Covers Tests/, App/SiltaAppTests and SiltaTestSupport, whose fakes and runners tests call.

Advance the fake clock instead. A justified exception carries the marker
`guard:allow-wait` on the same line.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from swift_source import run, split_swift, swift_files

MARKER = "guard:allow-wait"
PATTERNS = {
    "Task.sleep": re.compile(r"\bTask\s*(?:<[^>\n]+>)?\s*\.\s*sleep\b"),
    "POSIX sleep": re.compile(r"(?<![\w.])(?:(?:Darwin|Glibc)\s*\.\s*)?(?:u|nano)?sleep\s*\("),
    "Thread.sleep": re.compile(r"\bThread\.sleep\b"),
    "wall clock sleep": re.compile(r"\b(?:ContinuousClock|SuspendingClock)\s*\(\s*\)\s*\.\s*sleep\b"),
    "asyncAfter": re.compile(r"\.asyncAfter\("),
}


CLOCKS = {"ContinuousClock", "SuspendingClock"}
BINDING = re.compile(r"\b(?:let|var)\s+(\w+)\s*(?::\s*([\w.]+)\s*)?=\s*([\w.]+)\s*\(")
CLOCK_CALL = re.compile(r"\b(\w+)\s*\.\s*sleep\b")


def stored_waits(code: str):
    """Track named clock constructor bindings and later sleep calls in source order."""
    bindings = iter(BINDING.finditer(code))
    binding = next(bindings, None)
    clocks: set[str] = set()
    for call in CLOCK_CALL.finditer(code):
        while binding is not None and binding.start() < call.start():
            name, annotation, constructor = binding.groups()
            if any(value and value.rsplit(".", 1)[-1] in CLOCKS
                   for value in (annotation, constructor)):
                clocks.add(name)
            else:
                clocks.discard(name)
            binding = next(bindings, None)
        if call.group(1) in clocks:
            yield call.start()


def check(root: Path) -> list[str]:
    errors = []
    for path in swift_files(root, "Tests", "Sources/SiltaTestSupport", "App/SiltaAppTests"):
        raw_lines = path.read_text(encoding="utf-8").split("\n")
        code, _ = split_swift("\n".join(raw_lines))
        findings = {(code.count("\n", 0, match.start()) + 1, label)
                    for label, pattern in PATTERNS.items() for match in pattern.finditer(code)}
        findings.update((code.count("\n", 0, offset) + 1, "wall clock sleep")
                        for offset in stored_waits(code))
        rel = path.relative_to(root)
        for number, label in sorted(findings):
            if MARKER not in raw_lines[number - 1]:
                errors.append(f"{rel}:{number}: {label} in a test; advance the fake clock instead")
    return errors


if __name__ == "__main__":
    sys.exit(run("check_test_waits", check))
