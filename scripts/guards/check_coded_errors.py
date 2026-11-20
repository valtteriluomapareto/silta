"""Errors that can reach the caller are CodedError (coding guidelines §2, D22, D30).

In SiltaCore and the CLI no type inherits or conforms to a plain error type directly:
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
PLAIN_TYPES = {"Error", "LocalizedError", "RecoverableError", "CustomNSError", "NSError"}
ALIAS = re.compile(r"\btypealias\s+(\w+)\s*=\s*(?:(?:Swift|Foundation)\s*\.\s*)?(\w+)\b(?![\w.])")


def plain_error_types(sources: list[str]) -> re.Pattern[str]:
    types = PLAIN_TYPES.copy()
    aliases = {alias for code in sources for alias in ALIAS.findall(code)}
    while additions := {name for name, target in aliases if target in types} - types:
        types.update(additions)
    return re.compile(r"(?<![\w.])(?:(?:Swift|Foundation)\s*\.\s*)?(?:"
                      + "|".join(sorted(map(re.escape, types))) + r")\b")


def check(root: Path) -> list[str]:
    errors = []
    sources = []
    for path in swift_files(root, *DIRS):
        raw = path.read_text(encoding="utf-8")
        code, _ = split_swift(raw)
        sources.append((path, raw.split("\n"), code))
    plain = plain_error_types([code for _, _, code in sources])
    for path, raw_lines, code in sources:
        for match in DECLARATION.finditer(code):
            if not plain.search(match.group(2)):
                continue
            line = code.count("\n", 0, match.start()) + 1
            if MARKER in raw_lines[line - 1]:
                continue
            rel = path.relative_to(root)
            errors.append(f"{rel}:{line}: {match.group(1)} conforms to Error; conform to CodedError instead")
    return errors


if __name__ == "__main__":
    sys.exit(run("check_coded_errors", check))
