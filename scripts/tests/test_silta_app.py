"""Acceptance checks for the Mac fixture driver."""
import importlib.util
import os
from pathlib import Path
import select
import tempfile
import threading
import unittest

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
            child = __import__("subprocess").Popen(["/usr/bin/true"])
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
