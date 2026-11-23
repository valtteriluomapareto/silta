"""Self-tests for scripts/build-prior-writer.sh: the writer list and the CI cache paths.

These use fake cached binaries, so nothing is built. Run:
python3 -B -m unittest discover -s scripts/tests
"""

from __future__ import annotations

import hashlib
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "build-prior-writer.sh"


WORKFLOW = SCRIPT.parents[1] / ".github" / "workflows" / "ci.yml"


def run(*args: str, cache: Path | None = None, hit: bool = False, path: str | None = None,
        cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    env = {key: value for key, value in os.environ.items() if not key.startswith("SILTA_PRIOR_WRITER")}
    if cache is not None:
        env["SILTA_PRIOR_WRITER_CACHE"] = str(cache)
    if hit:
        env["SILTA_PRIOR_WRITER_CACHE_HIT"] = "true"
    if path is not None:
        env["PATH"] = path
    return subprocess.run(["bash", str(SCRIPT), *args], env=env, text=True, capture_output=True,
                          stdin=subprocess.DEVNULL, timeout=120, cwd=cwd)


def writers() -> list[tuple[str, str]]:
    result = run("--list")
    assert result.returncode == 0, result.stderr
    return [tuple(line.split()) for line in result.stdout.splitlines()]  # type: ignore[misc]


class PriorWriterTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory(prefix="prior-writers-test-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.cache = self.root / "cache"
        version = subprocess.run(["swift", "--version"], text=True, capture_output=True).stdout
        self.toolchain = version.splitlines()[0] if version else ""
        self.assertTrue(self.toolchain, "swift --version printed nothing")

    def store(self, commit: str, body: bytes) -> None:
        entry = self.cache / commit
        entry.mkdir(parents=True)
        (entry / "silta").write_bytes(body)
        sha = hashlib.sha256(body).hexdigest()
        (entry / "stamp").write_text(f"commit={commit}\nswift={self.toolchain}\nsha256={sha}\n")

    def test_list_names_each_writer_once_with_a_full_commit(self) -> None:
        listed = writers()
        names = [name for name, _ in listed]
        self.assertIn("prior", names)
        self.assertEqual(len(names), len(set(names)))
        for name, commit in listed:
            # verify.sh upper-cases the name into SILTA_<WRITER>_BINARY.
            self.assertRegex(name, r"^[a-z0-9]+$")
            self.assertRegex(commit, r"^[0-9a-f]{40}$")

    def test_all_reuses_every_cached_writer_on_a_hit(self) -> None:
        listed = writers()
        for name, commit in listed:
            self.store(commit, f"fake {name}".encode())
        out = self.root / "out"
        result = run("--all", str(out), cache=self.cache, hit=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name, _ in listed:
            self.assertEqual((out / name / "silta").read_bytes(), f"fake {name}".encode())
        self.assertEqual(result.stderr.count("reused cached"), len(listed))

    def test_hit_missing_a_writer_fails_before_building_and_stops(self) -> None:
        listed = writers()
        for name, commit in listed[1:]:
            self.store(commit, f"fake {name}".encode())
        missing, commit = listed[0]
        out = self.root / "out"
        result = run("--all", str(out), cache=self.cache, hit=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr, rf"::error::.*writer {missing} \({commit}\) is missing")
        self.assertFalse((out / missing / "source").exists(), "it started building")
        self.assertFalse((out / listed[1][0]).exists(), "--all went on after a failed writer")

    def test_a_plain_miss_builds_instead_of_failing(self) -> None:
        # A stub swift that reports a version but fails any build: reaching the build is
        # the behaviour under test, so nothing is compiled.
        stub = self.root / "bin"
        stub.mkdir()
        (stub / "swift").write_text('#!/bin/sh\nif [ "$1" = --version ]; then echo "Stub Swift 0"; exit 0; fi\n'
                                    'echo stub-swift-build >&2\nexit 3\n')
        (stub / "swift").chmod(0o755)
        name, _ = writers()[0]
        out = self.root / "out"
        for hit_value in ["", "false"]:
            with self.subTest(hit=hit_value):
                env_hit = {"SILTA_PRIOR_WRITER_CACHE_HIT": hit_value} if hit_value else {}
                env = {key: value for key, value in os.environ.items() if not key.startswith("SILTA_PRIOR_WRITER")}
                env.update(env_hit, SILTA_PRIOR_WRITER_CACHE=str(self.cache), PATH=f"{stub}:{os.environ['PATH']}")
                result = subprocess.run(["bash", str(SCRIPT), str(out / hit_value), name], env=env,
                                        text=True, capture_output=True, stdin=subprocess.DEVNULL, timeout=120)
                self.assertEqual(result.returncode, 3, result.stderr)
                self.assertIn("stub-swift-build", result.stderr)
                self.assertNotIn("::error::", result.stderr)
                self.assertNotIn("::warning::", result.stderr)

    def test_runs_from_another_directory(self) -> None:
        for name, commit in writers():
            self.store(commit, f"fake {name}".encode())
        result = run("--all", str(self.root / "out"), cache=self.cache, hit=True, cwd=SCRIPT.parent)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_ci_builds_every_writer_and_passes_the_cache_hit(self) -> None:
        workflow = WORKFLOW.read_text()
        # The swift job hands its restore step's exact-hit flag to the script...
        self.assertRegex(workflow, r"id: restore-writers\n\s+uses: actions/cache@")
        self.assertIn("SILTA_PRIOR_WRITER_CACHE_HIT: ${{ steps.restore-writers.outputs.cache-hit }}", workflow)
        # ...and warm-caches builds the script's whole list, never a hand-written subset.
        self.assertIn("bash scripts/build-prior-writer.sh --all ", workflow)
        self.assertNotRegex(workflow, r"build-prior-writer\.sh \"[^\"]*\" \w+")
        verify = (SCRIPT.parent / "verify.sh").read_text()
        self.assertIn('build-prior-writer.sh --all "$SILTA_HOME/writers"', verify)

    def test_hit_with_a_tampered_writer_fails(self) -> None:
        name, commit = writers()[0]
        self.store(commit, b"fake")
        (self.cache / commit / "silta").write_bytes(b"tampered")
        result = run(str(self.root / "out"), name, cache=self.cache, hit=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match its stamp", result.stderr)

    def test_bad_usage_and_unknown_writer_exit_64(self) -> None:
        for args in [(), ("--all",), ("--all", ""), ("--list", "extra"), (str(self.root / "out"), "v0")]:
            with self.subTest(args=args):
                result = run(*args)
                self.assertEqual(result.returncode, 64, result.stderr)
        self.assertTrue(re.search(r"use one of: prior ", run(str(self.root / "out"), "v0").stderr))


if __name__ == "__main__":
    unittest.main()
