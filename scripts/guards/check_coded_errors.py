"""Errors that can reach the caller are CodedError (coding guidelines §2, D22, D30).

In SiltaCore and the CLI no type conforms to `Error` (or `LocalizedError`) directly:
it conforms to `CodedError`, which refines `Error`, so every error has a code, a
message and a next command. A deliberate exception carries `guard:allow-error` on the
same line.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from swift_source import run, split_swift, swift_files

DIRS = ("Sources/SiltaCore", "Sources/silta")
MARKER = "guard:allow-error"
DECLARATION = re.compile(r"\b(?:enum|struct|class|actor|extension|protocol)\s+([\w.]+)[^{:]*:([^{]*)\{")
PLAIN_ERROR = re.compile(r"(?<![\w.])(?:Swift\.)?(?:Localized)?Error\b")


def check(root: Path) -> list[str]:
    errors = []
    for path in swift_files(root, *DIRS):
        raw_lines = path.read_text(encoding="utf-8").split("\n")
        code, _ = split_swift("\n".join(raw_lines))
        for match in DECLARATION.finditer(code):
            if not PLAIN_ERROR.search(match.group(2)):
                continue
            line = code.count("\n", 0, match.start()) + 1
            if MARKER in raw_lines[line - 1]:
                continue
            rel = path.relative_to(root)
            errors.append(f"{rel}:{line}: {match.group(1)} conforms to Error; conform to CodedError instead")
    return errors


if __name__ == "__main__":
    sys.exit(run("check_coded_errors", check))
