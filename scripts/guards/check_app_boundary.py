"""The native app reads only SiltaAppSupport and Apple frameworks."""
import re
import sys
from pathlib import Path
from swift_source import run, split_swift, swift_files

ALLOWED = {"SiltaAppSupport", "SwiftUI", "AppKit", "Foundation", "Observation", "Combine", "Synchronization", "Darwin", "Dispatch", "CoreFoundation"}
IMPORT = re.compile(r"\bimport\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_]\w*)")


def check(root: Path) -> list[str]:
    errors = []
    for path in swift_files(root, "App/SiltaApp"):
        code, _ = split_swift(path.read_text(encoding="utf-8"))
        for match in IMPORT.finditer(code):
            if match.group(1) not in ALLOWED:
                number = code.count("\n", 0, match.start()) + 1
                errors.append(f"{path.relative_to(root)}:{number}: app import {match.group(1)} bypasses SiltaAppSupport")
    return errors


if __name__ == "__main__":
    sys.exit(run("app-boundary", check))
