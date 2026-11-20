"""Relative links in markdown resolve (AGENTS.md invariant 6).

Checks fragments for local Markdown files. External links, fenced blocks and
inline code spans are ignored.
"""

from __future__ import annotations

import html
import re
import sys
from pathlib import Path
from urllib.parse import unquote

from swift_source import run

SKIP_DIRS = {".git", ".build", "node_modules", "artifacts", "worktrees"}
LINK = re.compile(r"!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
FENCE = re.compile(r"^\s*(`{3,}|~{3,})(.*)$")
INLINE_CODE = re.compile(r"`[^`]*`")
SCHEME = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")

HEADING = re.compile(r"^ {0,3}#{1,6}[ \t]+(.+?)(?:[ \t]+#+)?\s*$")
SETEXT = re.compile(r"^ {0,3}(?:=+|-+)\s*$")
EXPLICIT = re.compile(r'<a\s+(?:name|id)=["\']([^"\']+)["\']', re.IGNORECASE)


def markdown_files(root: Path) -> list[Path]:
    return sorted(
        p for p in root.rglob("*.md") if not SKIP_DIRS.intersection(p.relative_to(root).parts)
    )


def prose_lines(text: str) -> list[tuple[int, str]]:
    lines = []
    fence = ""
    for number, line in enumerate(text.splitlines(), 1):
        found = FENCE.match(line)
        if not fence and found:
            fence = found.group(1)
        elif fence:
            if found and found.group(1).startswith(fence) and not found.group(2).strip():
                fence = ""
        else:
            lines.append((number, line))
    return lines


def anchors(path: Path) -> set[str]:
    found: set[str] = set()
    previous_line, previous = 0, ""
    for number, line in prose_lines(path.read_text(encoding="utf-8")):
        found.update(EXPLICIT.findall(INLINE_CODE.sub("", line)))
        heading = HEADING.match(line)
        title = heading.group(1) if heading else ""
        if not heading and number == previous_line + 1 and SETEXT.fullmatch(line):
            title = previous.strip()
        previous_line = number
        previous = "" if heading or SETEXT.fullmatch(line) else line
        if not title:
            continue
        title = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", title)
        title = html.unescape(re.sub(r"<[^>]*>", "", title)).strip().lower()
        slug = "".join(
            "-" if char.isspace() else char
            for char in title
            if char.isalnum() or char in "_-" or char.isspace()
        )
        unique, suffix = slug, 0
        while unique in found:
            suffix += 1
            unique = f"{slug}-{suffix}"
        found.add(unique)
    return found


def check(root: Path) -> list[str]:
    errors = []
    known: dict[Path, set[str]] = {}
    for path in markdown_files(root):
        for number, line in prose_lines(path.read_text(encoding="utf-8")):
            for match in LINK.finditer(INLINE_CODE.sub("", line)):
                target = match.group(1)
                if SCHEME.match(target):
                    continue
                location, _, fragment = target.partition("#")
                file_part = unquote(location.split("?", 1)[0])
                resolved = (path.parent / file_part).resolve() if file_part else path.resolve()
                valid = resolved.exists()
                if valid and fragment and resolved.is_file() and resolved.suffix.lower() == ".md":
                    if resolved not in known:
                        known[resolved] = anchors(resolved)
                    valid = unquote(fragment) in known[resolved]
                if not valid:
                    rel = path.relative_to(root)
                    errors.append(f"{rel}:{number}: broken link to {target}")
    return errors


if __name__ == "__main__":
    sys.exit(run("check_docs_links", check))
