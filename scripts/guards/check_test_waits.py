"""Tests never wait on the wall clock (AGENTS.md invariant 3).

Covers the test targets and SiltaTestSupport, whose fakes and runners tests call.

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
    "Task.sleep": re.compile(r"\bTask\.sleep\b"),
    "sleep()/usleep()": re.compile(r"(?<![\w.])u?sleep\("),
    "Thread.sleep": re.compile(r"\bThread\.sleep\b"),
    "asyncAfter": re.compile(r"\.asyncAfter\("),
}


def check(root: Path) -> list[str]:
    errors = []
    for path in swift_files(root, "Tests", "Sources/SiltaTestSupport"):
        raw_lines = path.read_text(encoding="utf-8").split("\n")
        code, _ = split_swift("\n".join(raw_lines))
        for number, code_line in enumerate(code.split("\n"), start=1):
            if MARKER in raw_lines[number - 1]:
                continue
            for label, pattern in PATTERNS.items():
                if pattern.search(code_line):
                    rel = path.relative_to(root)
                    errors.append(f"{rel}:{number}: {label} in a test; advance the fake clock instead")
    return errors


if __name__ == "__main__":
    sys.exit(run("check_test_waits", check))
