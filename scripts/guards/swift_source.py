"""Shared helpers for the repository guards.

`split_swift` separates Swift source into code and comments, so guards can match
code without tripping on comments or string literals, and match comments without
tripping on code. It is a small lexer, not a parser: it understands line and nested
block comments, escaped and raw strings, and nested string interpolation.
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

    `code` preserves every offset and line break. Comments and literal string
    text are blanked, while interpolation expressions remain code. If supplied,
    `strings` collects outer literals as (source offset, literal including quotes).
    """
    code = list(text)
    comments: list[tuple[int, str]] = []
    i, n, line = 0, len(text), 1

    def consume(end: int, *, mask: bool = False) -> None:
        nonlocal i, line
        chunk = text[i:end]
        if mask:
            code[i:end] = ["\n" if character == "\n" else " " for character in chunk]
        line += chunk.count("\n")
        i = end

    def scan_string(hashes: int, record: bool) -> None:
        start = i
        quote_start = i + hashes
        quote = '"""' if text.startswith('"""', quote_start) else '"'
        closer = quote + "#" * hashes
        escape = "\\" + "#" * hashes
        consume(quote_start + len(quote), mask=True)
        while i < n:
            if text.startswith(closer, i):
                consume(i + len(closer), mask=True)
                break
            if text.startswith(escape + "(", i):
                consume(i + len(escape) + 1, mask=True)
                scan_code(interpolation=True)
            elif text.startswith(escape, i):
                consume(min(n, i + len(escape) + 1), mask=True)
            elif quote == '"' and text[i] == "\n":
                break
            else:
                consume(i + 1, mask=True)
        if record and strings is not None:
            strings.append((start, text[start:i]))

    def regex_end(opening: int, hashes: int) -> int | None:
        closer = "/" + "#" * hashes
        end = opening + 1
        while end < n and (hashes or text[end] != "\n"):
            if text.startswith(closer, end):
                return end + len(closer)
            end += 2 if text[end] == "\\" else 1
        return None

    def scan_code(*, interpolation: bool = False) -> None:
        start = i
        parens = 0
        while i < n:
            c = text[i]
            if text.startswith("//", i):
                end = text.find("\n", i)
                end = n if end == -1 else end
                comments.append((line, text[i + 2:end]))
                consume(end, mask=True)
                continue
            if text.startswith("/*", i):
                depth, end = 1, i + 2
                while end < n and depth:
                    if text.startswith("/*", end):
                        depth, end = depth + 1, end + 2
                    elif text.startswith("*/", end):
                        depth, end = depth - 1, end + 2
                    else:
                        end += 1
                for offset, part in enumerate(text[i + 2:end - 2].split("\n")):
                    comments.append((line + offset, part))
                consume(end, mask=True)
                continue
            if c in '#"':
                quote_start = i
                while quote_start < n and text[quote_start] == "#":
                    quote_start += 1
                if quote_start < n and text[quote_start] == '"':
                    scan_string(quote_start - i, record=not interpolation)
                    continue
                if quote_start > i and quote_start < n and text[quote_start] == "/":
                    end = regex_end(quote_start, quote_start - i)
                    if end is not None:
                        consume(end, mask=True)
                        continue
            if interpolation and c == "/" and i + 1 < n and not text[i + 1].isspace():
                previous = i - 1
                while previous >= start and code[previous] in " \t":
                    previous -= 1
                # An expression-leading slash can open a regex. Leave division as code.
                if previous < start or code[previous] in "(=:[,":
                    end = regex_end(i, 0)
                    if end is not None:
                        consume(end, mask=True)
                        continue
            if interpolation:
                if c == ")" and parens == 0:
                    consume(i + 1, mask=True)
                    return
                parens += (c == "(") - (c == ")")
            consume(i + 1)

    scan_code()
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
