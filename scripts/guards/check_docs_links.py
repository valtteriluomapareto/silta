"""Relative links in markdown resolve (AGENTS.md invariant 5).

External links (any URL scheme) and pure anchors are not checked. Links inside fenced
code blocks and inline code spans are ignored.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote

from swift_source import run

SKIP_DIRS = {".git", ".build", "node_modules", "artifacts", "worktrees"}
LINK = re.compile(r"!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
FENCE = re.compile(r"^\s*(```|~~~)")
INLINE_CODE = re.compile(r"`[^`]*`")
SCHEME = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")


def markdown_files(root: Path) -> list[Path]:
    return sorted(
        p for p in root.rglob("*.md") if not SKIP_DIRS.intersection(p.relative_to(root).parts)
    )


def check(root: Path) -> list[str]:
    errors = []
    for path in markdown_files(root):
        in_fence = False
        for number, line in enumerate(path.read_text(encoding="utf-8").split("\n"), start=1):
            if FENCE.match(line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            for match in LINK.finditer(INLINE_CODE.sub("", line)):
                target = match.group(1)
                if SCHEME.match(target) or target.startswith("#"):
                    continue
                file_part = unquote(target.split("#", 1)[0].split("?", 1)[0])
                if not file_part:
                    continue
                resolved = (path.parent / file_part).resolve()
                if not resolved.exists():
                    rel = path.relative_to(root)
                    errors.append(f"{rel}:{number}: broken link to {target}")
    return errors


if __name__ == "__main__":
    sys.exit(run("check_docs_links", check))
