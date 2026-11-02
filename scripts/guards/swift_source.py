"""Shared helpers for the repository guards.

`split_swift` separates Swift source into code and comments, so guards can match
code without tripping on comments or string literals, and match comments without
tripping on code. It is a small lexer, not a parser: it understands line and nested
block comments, string literals (including multi-line and raw strings) and escapes.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def split_swift(
    text: str, strings: list[tuple[int, str]] | None = None
) -> tuple[str, list[tuple[int, str]]]:
    """Return (code, comments).

    `code` has the same length and line breaks as `text`, with comment and string
    contents replaced by spaces. `comments` is a list of (line number, comment text).
    If `strings` is given, each string literal is appended to it as (offset in `text`,
    literal including its quotes).
    """
    code: list[str] = []
    comments: list[tuple[int, str]] = []
    i, n, line = 0, len(text), 1

    def blank(chunk: str) -> str:
        return "".join("\n" if c == "\n" else " " for c in chunk)

    while i < n:
        c = text[i]
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end == -1 else end
            comments.append((line, text[i + 2 : end]))
            code.append(blank(text[i:end]))
            i = end
            continue
        if text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            chunk = text[i:j]
            for offset, part in enumerate(chunk[2:-2].split("\n")):
                comments.append((line + offset, part))
            code.append(blank(chunk))
            line += chunk.count("\n")
            i = j
            continue
        if c == '"' or (c == "#" and text.startswith('#"', i) or text.startswith('##"', i)):
            hashes = 0
            while i + hashes < n and text[i + hashes] == "#":
                hashes += 1
            start = i
            j = i + hashes
            multiline = text.startswith('"""', j)
            quote = '"""' if multiline else '"'
            j += len(quote)
            closer = quote + "#" * hashes
            while j < n:
                if hashes == 0 and text[j] == "\\":
                    j += 2
                    continue
                if not multiline and text[j] == "\n":
                    break
                if text.startswith(closer, j):
                    j += len(closer)
                    break
                j += 1
            chunk = text[start:j]
            if strings is not None:
                strings.append((start, chunk))
            code.append(blank(chunk))
            line += chunk.count("\n")
            i = j
            continue
        code.append(c)
        if c == "\n":
            line += 1
        i += 1
    return "".join(code), comments


def swift_files(root: Path, *subdirs: str) -> list[Path]:
    files: list[Path] = []
    for sub in subdirs:
        base = root / sub
        if base.is_dir():
            files.extend(sorted(p for p in base.rglob("*.swift") if ".build" not in p.parts))
    return files


def run(name: str, check) -> int:
    """Command-line entry point shared by every guard."""
    parser = argparse.ArgumentParser(description=name)
    parser.add_argument("--root", type=Path, default=REPO_ROOT)
    args = parser.parse_args()
    errors = check(args.root.resolve())
    for error in errors:
        print(f"{name}: {error}", file=sys.stderr)
    return 1 if errors else 0
