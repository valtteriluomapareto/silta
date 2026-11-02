"""Code comments describe the code, not plans or review rounds (AGENTS.md invariant 4).

Stable references such as `D12` or `spec §7` are allowed; plan phases, milestones
and review bookkeeping are not, because they go stale as soon as the plan ships.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from swift_source import run, split_swift, swift_files

PATTERNS = {
    "phase reference": re.compile(r"\bphase\s*\d", re.IGNORECASE),
    "milestone reference": re.compile(r"\bM[1-9]\b"),
    "slice reference": re.compile(r"\bslice\s*S?\d+", re.IGNORECASE),
    "review bookkeeping": re.compile(r"\breview\s+(item|finding|round|comment)s?\b", re.IGNORECASE),
    "plan reference": re.compile(r"\b(per|see|from) (the )?plan\b|\bplan\s*§", re.IGNORECASE),
}


def check(root: Path) -> list[str]:
    errors = []
    for path in swift_files(root, "Sources", "Tests"):
        _, comments = split_swift(path.read_text(encoding="utf-8"))
        for line, text in comments:
            for label, pattern in PATTERNS.items():
                if pattern.search(text):
                    rel = path.relative_to(root)
                    errors.append(f"{rel}:{line}: {label} in a comment: {text.strip()[:80]}")
    return errors


if __name__ == "__main__":
    sys.exit(run("check_no_plan_refs", check))
