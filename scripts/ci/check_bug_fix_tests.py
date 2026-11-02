"""A pull request labelled `bug` must change at least one test (D16, test-first flow).

Reads the changed paths (one per line) from stdin, e.g.
    git diff --name-only BASE...HEAD | python3 -B scripts/ci/check_bug_fix_tests.py

This can't prove the test was written first; the PR's "Test-first evidence" field
and the Tester review cover that. It catches "fixed without any test".
"""

from __future__ import annotations

import sys

TEST_PREFIXES = ("Tests/",)


def check(changed: list[str]) -> list[str]:
    paths = [p.strip() for p in changed if p.strip()]
    if any(p.startswith(TEST_PREFIXES) for p in paths):
        return []
    return [
        "a PR labelled `bug` must add or change a test under Tests/ "
        "(see docs/coding-guidelines.md, Test-first flow)"
    ]


def main() -> int:
    errors = check(sys.stdin.read().splitlines())
    for error in errors:
        print(f"check_bug_fix_tests: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
