#!/usr/bin/env python3
"""Run the offline eval replay tests, one unittest process per test module, in parallel.

Each module under the tests directory runs alone in its own process and session, so modules
share no interpreter state and a hung module can be killed with everything it started. The
modules must not write to the shared source tree. Prints one line per module and the full
output of every module that fails. Exits 1 if any module fails, times out, skips a test or
runs no tests, or if there are no modules.

Usage: scripts/run-eval-tests.py [--jobs N] [tests-directory]
"""

from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path

DEFAULT_TESTS = Path(__file__).resolve().parents[1] / "Evals" / "tests"
# The slowest module takes about 7 minutes alone; this bounds a hang well inside the CI job.
MODULE_TIMEOUT_SECONDS = 20 * 60
RAN = re.compile(r"^Ran (\d+) tests? in ", re.MULTILINE)
SKIPPED = re.compile(r"\bskipped=\d+")


@dataclass
class ModuleResult:
    name: str
    exit_code: int | None  # None when the module timed out
    tests: int
    seconds: float
    output: str

    @property
    def problem(self) -> str | None:
        if self.exit_code is None:
            return f"timed out after {self.seconds:.0f}s"
        if self.exit_code != 0:
            return f"exit {self.exit_code}"
        if self.tests == 0:
            return "ran no tests"
        if SKIPPED.search(self.output):
            return "skipped tests"
        return None


def run_module(tests_dir: Path, name: str, timeout: float) -> ModuleResult:
    started = time.monotonic()
    # The same discover call as a whole-suite run, so sibling helper imports keep working.
    child = subprocess.Popen(
        [sys.executable, "-B", "-m", "unittest", "discover", "-s", str(tests_dir), "-p", f"{name}.py"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        start_new_session=True)
    try:
        output, _ = child.communicate(timeout=timeout)
        exit_code: int | None = child.returncode
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        exit_code = None
        try:
            output, _ = child.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            # A descendant in its own session still holds the pipe; report without output.
            child.stdout.close()  # type: ignore[union-attr]
            output = "(no output: a descendant outside the module's process group kept it open)\n"
    counts = RAN.findall(output)
    tests = int(counts[-1]) if counts else 0
    return ModuleResult(name, exit_code, tests, time.monotonic() - started, output)


def run_all(tests_dir: Path, jobs: int, timeout: float = MODULE_TIMEOUT_SECONDS) -> int:
    # unittest discover's default pattern, so no module runs in one form but not the other.
    names = sorted(path.stem for path in tests_dir.glob("test*.py"))
    if not names:
        print(f"eval tests: no test*.py modules in {tests_dir}", file=sys.stderr)
        return 1
    print(f"eval tests: {len(names)} modules, {jobs} at a time", flush=True)
    failed: list[ModuleResult] = []
    total = 0
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = [pool.submit(run_module, tests_dir, name, timeout) for name in names]
        for future in as_completed(futures):
            result = future.result()
            total += result.tests
            problem = result.problem
            status = "FAIL" if problem else "ok"
            detail = f" ({problem})" if problem else ""
            print(f"{status:4} {result.name}: {result.tests} tests in {result.seconds:.0f}s{detail}", flush=True)
            if problem:
                failed.append(result)
    failed.sort(key=lambda result: result.name)
    for result in failed:
        print(f"\n=== {result.name} output ===\n{result.output}", end="", flush=True)
    if failed:
        print(f"\neval tests: {len(failed)} of {len(names)} modules failed: "
              + ", ".join(result.name for result in failed), file=sys.stderr)
        return 1
    print(f"eval tests: {total} tests in {len(names)} modules passed")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 2,
                        help="modules to run at once; default is the CPU count")
    parser.add_argument("tests_dir", nargs="?", type=Path, default=DEFAULT_TESTS)
    args = parser.parse_args(argv)
    if args.jobs < 1:
        parser.error("--jobs must be at least 1")
    return run_all(args.tests_dir, args.jobs)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
