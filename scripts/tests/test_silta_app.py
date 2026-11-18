"""Acceptance checks for the Mac fixture driver."""
import importlib.util
import os
from pathlib import Path
import select
import subprocess
import tempfile
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location(
    "silta_app", Path(__file__).resolve().parents[1] / "silta_app.py"
)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class Predicates(unittest.TestCase):
    def test_static_null_paths_and_dynamic_keys(self):
        state = {"selection": None, "counts": {"lanes": {"Done this week": 3}}}
        self.assertIsNone(driver.field(state, "selection.ref"))
        self.assertEqual(driver.field(state, "counts.lanes.Done this week"), 3)
        for path in ("selection.typo", "counts.lanes.Todo"):
            with self.assertRaisesRegex(driver.DriverError, "Unknown state path"):
                driver.field(state, path)

    def test_values_are_json_and_type_sensitive(self):
        predicates = driver.predicates(['idle=true', 'screen="mywork"'])
        self.assertEqual(driver.unmet({"idle": 1, "screen": "mywork"}, predicates),
                         ["idle: expected true, observed 1"])
        with self.assertRaises(driver.DriverError):
            driver.predicates(["screen=mywork"])


@unittest.skipUnless(hasattr(select, "kqueue"), "macOS file event API")
class Waits(unittest.TestCase):
    def test_atomic_rename_wakes_without_a_poll(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            state = root / "state.json"
            first_read = threading.Event()
            driver.atomic_json(state, {"idle": False})

            def write():
                if first_read.wait(3):
                    driver.atomic_json(state, {"idle": True})

            def read():
                value = driver.read_json(state)
                first_read.set()
                return value

            writer = threading.Thread(target=write)
            writer.start()
            try:
                self.assertEqual(driver.wait_for(root, os.getpid(), read, [("idle", True)], 3),
                                 {"idle": True})
            finally:
                writer.join()

    def test_timeout_names_all_unmet_values(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(driver.DriverError, r"(?s)idle: expected true.*screen: expected"):
                driver.wait_for(Path(root), os.getpid(), lambda: {"idle": False, "screen": "board"},
                                [("idle", True), ("screen", "docs")], 0)

    def test_process_that_already_exited_refuses(self):
        with tempfile.TemporaryDirectory() as root:
            child = subprocess.Popen(["/usr/bin/true"])
            child.wait()
            with self.assertRaisesRegex(driver.DriverError, "exited"):
                driver.wait_for(Path(root), child.pid, lambda: None, [], 0)


class OwnedRuns(unittest.TestCase):
    def test_symlink_or_nonprivate_directory_refuses(self):
        with tempfile.TemporaryDirectory(prefix="silta-app-") as root:
            root = Path(root).resolve()
            link = root / "link"
            link.symlink_to(root, target_is_directory=True)
            with self.assertRaises(driver.DriverError):
                driver.validate_run(link)
            root.chmod(0o755)
            with self.assertRaises(driver.DriverError):
                driver.validate_run(root)

    def test_capture_ignores_publication_number_but_detects_state_changes(self):
        before = {"revision": 11, "windowNumber": 7, "screen": "mywork"}
        self.assertTrue(driver.same_capture_state(before, dict(before, revision=12)))
        self.assertFalse(driver.same_capture_state(before, dict(before, screen="docs")))
        self.assertFalse(driver.same_capture_state(before, dict(before, windowNumber=8)))

    def test_copied_driver_record_cannot_stop_a_different_run(self):
        with tempfile.TemporaryDirectory(prefix="silta-app-") as original, \
                tempfile.TemporaryDirectory(prefix="silta-app-") as copied:
            record = {"run": "original", "process": {"pid": 10, "seconds": 1,
                       "microseconds": 2, "directory": original,
                       "executable": str(driver.APP.resolve())}}
            driver.atomic_json(Path(copied) / "driver.json", record)
            with patch.object(driver, "identity", return_value=record["process"]), \
                    patch.object(driver.os, "kill") as signal:
                self.assertEqual(driver.main(["stop", str(Path(copied).resolve())]), 1)
                signal.assert_not_called()

    def test_interrupted_identity_lookup_stops_the_spawned_child(self):
        for error in (subprocess.TimeoutExpired("identity", 5), KeyboardInterrupt()):
            with self.subTest(error=type(error)), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch)
                app = root / "SiltaApp"
                app.touch()
                child = Mock(pid=10, poll=Mock(return_value=None))
                with patch.object(driver, "APP", app), patch.object(driver, "native_tool"), \
                        patch.object(driver.tempfile, "mkdtemp", return_value=str(root)), \
                        patch.object(driver.subprocess, "Popen", return_value=child), \
                        patch.object(driver, "identity", side_effect=error):
                    with self.assertRaisesRegex(driver.DriverError, "Startup log"):
                        driver.launch(SimpleNamespace(route="mywork", dark=False, timeout=1))
                child.terminate.assert_called_once()
                child.wait.assert_called_once_with(timeout=2)

    def test_shot_publishes_png_and_correlated_state_only_after_postcheck(self):
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / "window.png"
            before = {"revision": 3, "windowNumber": 8, "screen": "mywork"}
            run = Mock(pid=9)
            run.wait.return_value = before

            def capture(arguments, **_):
                Path(arguments[-1]).write_bytes(b"\x89PNG\r\n\x1a\nimage")
                return SimpleNamespace(returncode=0)

            with patch.object(driver, "confirm_window") as confirm, \
                    patch.object(driver.subprocess, "run", side_effect=capture):
                run.read.return_value = dict(before, screen="docs")
                with self.assertRaisesRegex(driver.DriverError, "changed during capture"):
                    driver.shot(run, output, 1)
                self.assertFalse(output.exists())
                self.assertFalse(output.with_suffix(".png.json").exists())
                run.read.return_value = dict(before, revision=4)
                driver.shot(run, output, 1)
                self.assertEqual(confirm.call_count, 4)
            self.assertTrue(output.exists())
            self.assertEqual(driver.read_json(output.with_suffix(".png.json"))["revision"], 4)

class FixtureWriteRecovery(unittest.TestCase):
    def test_intent_survives_interruption_and_never_replays(self):
        with tempfile.TemporaryDirectory() as root:
            record = Path(root) / "write.json"
            calls = []

            def interrupted(title):
                calls.append(title)
                raise OSError("interrupted after commit")

            with self.assertRaises(OSError):
                driver.fixture_receipt(record, "Acme proposal", interrupted)
            with self.assertRaisesRegex(driver.DriverError, "ambiguous"):
                driver.fixture_receipt(record, "Acme proposal", interrupted)
            self.assertEqual(calls, ["Acme proposal"])

    def test_definite_success_reuses_ref_for_refresh_only(self):
        with tempfile.TemporaryDirectory() as root:
            record = Path(root) / "write.json"
            calls = []

            def write(title):
                calls.append(title)
                return "AC-24"

            self.assertEqual(driver.fixture_receipt(record, "Acme proposal", write), "AC-24")
            self.assertEqual(driver.fixture_receipt(record, "Acme proposal", write), "AC-24")
            with self.assertRaises(driver.DriverError):
                driver.fixture_receipt(record, "Different proposal", write)
            self.assertEqual(calls, ["Acme proposal"])
