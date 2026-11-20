"""The website's links into this repository resolve, and its asset copies match.

`website/src/consts.ts` links to files on `main` with `blob('path#anchor')`. Each
path must exist, and an anchor must name a heading of that markdown file. A README
change can break these without touching `website/`, so this runs with every guard.

Files in `website/public/` that share a name with one in `docs/assets/` are copies
and must be identical (website/README.md, Screenshots and images).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote

from check_docs_links import anchors
from swift_source import run

CONSTS = Path("website/src/consts.ts")
PUBLIC = Path("website/public")
ASSETS = Path("docs/assets")
BLOB = re.compile(r"""\bblob\(\s*(['"`])([^'"`]+)\1\s*\)""")


def check(root: Path) -> list[str]:
    errors = []
    consts = root / CONSTS
    if consts.is_file():
        for number, line in enumerate(consts.read_text(encoding="utf-8").splitlines(), 1):
            for match in BLOB.finditer(line):
                target = match.group(2)
                location, _, fragment = target.partition("#")
                resolved = root / unquote(location)
                valid = resolved.exists()
                if valid and fragment and resolved.suffix.lower() == ".md":
                    valid = unquote(fragment) in anchors(resolved)
                if not valid:
                    errors.append(f"{CONSTS}:{number}: broken link to {target}")
    public = root / PUBLIC
    if public.is_dir():
        for copy in sorted(public.iterdir()):
            original = root / ASSETS / copy.name
            if copy.is_file() and original.is_file() and copy.read_bytes() != original.read_bytes():
                errors.append(f"{PUBLIC / copy.name}: differs from {ASSETS / copy.name}")
    return errors


if __name__ == "__main__":
    sys.exit(run("check_website_links", check))
