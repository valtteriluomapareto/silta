"""SiltaCore must not import UI or CLI frameworks, or log directly through os/OSLog
(AGENTS.md invariant 1; D11, D27)."""

from __future__ import annotations

import re
import sys
from pathlib import Path

from swift_source import run, split_swift, swift_files

CORE_DIR = "Sources/SiltaCore"
FORBIDDEN = ("AppKit", "SwiftUI", "UIKit", "Cocoa", "ArgumentParser", "os", "OSLog")
IMPORT = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+"
    r"(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
    r"(" + "|".join(FORBIDDEN) + r")\b",
    re.MULTILINE,
)


def check(root: Path) -> list[str]:
    errors = []
    for path in swift_files(root, CORE_DIR):
        code, _ = split_swift(path.read_text(encoding="utf-8"))
        for match in IMPORT.finditer(code):
            line = code.count("\n", 0, match.start()) + 1
            rel = path.relative_to(root)
            errors.append(f"{rel}:{line}: SiltaCore imports {match.group(1)}")
    return errors


if __name__ == "__main__":
    sys.exit(run("check_core_boundary", check))
