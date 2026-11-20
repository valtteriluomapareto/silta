"""Decides CI's required `verify` check from the other jobs' results (D19).

Reads job results from the environment, as GitHub writes them:
    CHANGES   result of the `changes` job
    CODE      `changes` output: whether the Swift jobs were needed ("true"/"false")
    WEBSITE   `changes` output: whether the website build was needed
    SWIFT, EVALS, APP, SITE   results of the swift, evals, app and website jobs

A needed job must succeed, and a job that wasn't needed must be skipped. A skipped
job otherwise counts as passing, so `changes` failing or giving an unknown answer
fails the check rather than reading as "nothing to run".
"""

from __future__ import annotations

import os
import sys
from collections.abc import Mapping


def check(env: Mapping[str, str]) -> list[str]:
    if env.get("CHANGES") != "success":
        return [f"changes job: {env.get('CHANGES') or 'missing'}, expected success"]
    errors = []
    areas = {"CODE": ("SWIFT", "EVALS", "APP"), "WEBSITE": ("SITE",)}
    for area, jobs in areas.items():
        needed = env.get(area, "")
        if needed not in ("true", "false"):
            errors.append(f"{area.lower()}: unknown changes output {needed!r}")
            continue
        expected = "success" if needed == "true" else "skipped"
        for job in jobs:
            result = env.get(job) or "missing"
            if result != expected:
                errors.append(f"{job.lower()}: {result}, expected {expected}")
    return errors


def main() -> int:
    names = ("CHANGES", "CODE", "WEBSITE", "SWIFT", "EVALS", "APP", "SITE")
    print(", ".join(f"{name.lower()}: {os.environ.get(name, '')}" for name in names))
    errors = check(os.environ)
    for error in errors:
        print(f"check_verify_gate: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
