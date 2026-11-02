"""`try?` in shipped code needs a reason on the same line (D22).

Silently discarding an error is sometimes right (best-effort cleanup), but the reader
must see why. Write the reason as a trailing comment:
    try? fileManager.removeItem(at: scratch) // best-effort cleanup
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from swift_source import run, split_swift, swift_files

TRY_OPTIONAL = re.compile(r"\btry\?")


def check(root: Path) -> list[str]:
    errors = []
    for path in swift_files(root, "Sources"):
        code, comments = split_swift(path.read_text(encoding="utf-8"))
        commented = {line for line, text in comments if text.strip()}
        for number, line in enumerate(code.split("\n"), start=1):
            if TRY_OPTIONAL.search(line) and number not in commented:
                rel = path.relative_to(root)
                errors.append(f"{rel}:{number}: try? without a reason; add a trailing comment or handle the error")
    return errors


if __name__ == "__main__":
    sys.exit(run("check_try_optional", check))
