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


def run(*args: str, cache: Path | None = None, hit: bool = False) -> subprocess.CompletedProcess[str]:
    env = {key: value for key, value in os.environ.items() if not key.startswith("SILTA_PRIOR_WRITER")}
    if cache is not None:
        env["SILTA_PRIOR_WRITER_CACHE"] = str(cache)
    if hit:
        env["SILTA_PRIOR_WRITER_CACHE_HIT"] = "true"
    return subprocess.run(["bash", str(SCRIPT), *args], env=env, text=True, capture_output=True,
                          stdin=subprocess.DEVNULL, timeout=60)


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

    def test_hit_with_a_tampered_writer_fails(self) -> None:
        name, commit = writers()[0]
        self.store(commit, b"fake")
        (self.cache / commit / "silta").write_bytes(b"tampered")
        result = run(str(self.root / "out"), name, cache=self.cache, hit=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match its stamp", result.stderr)

    def test_bad_usage_and_unknown_writer_exit_64(self) -> None:
        for args in [(), ("--all",), ("--list", "extra"), (str(self.root / "out"), "v0")]:
            with self.subTest(args=args):
                result = run(*args)
                self.assertEqual(result.returncode, 64, result.stderr)
        self.assertTrue(re.search(r"use one of: prior ", run(str(self.root / "out"), "v0").stderr))


if __name__ == "__main__":
    unittest.main()
