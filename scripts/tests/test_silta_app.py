"""Acceptance checks for the Mac fixture driver."""
import importlib.util
import os
from pathlib import Path
import select
import subprocess
import sys
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

    def test_action_waits_for_both_settlement_and_the_response_link(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            request = root / "req-1.json"
            response = root / "res-1.json"
            state_url = root / "state.json"
            initial = {"run": "owned", "seq": 0, "settledSeq": 0}
            expected = {"version": 1, "run": "owned", "seq": 1, "outcome": "accepted",
                        "copied": "AC-9"}
            driver.atomic_json(state_url, initial)
            waiting = threading.Event()
            saw_settled_without_response = threading.Event()

            def fake_app():
                if waiting.wait(4):
                    driver.atomic_json(state_url, dict(initial, seq=1, settledSeq=1))
                    if saw_settled_without_response.wait(4):
                        driver.atomic_json(response, expected, exclusive=True)

            def wait(conditions, timeout, ready):
                def check(state):
                    result = ready(state)
                    if state["settledSeq"] == 1 and not result:
                        saw_settled_without_response.set()
                    return result

                waiting.set()
                return driver.wait_for(root, os.getpid(), run.read, conditions, timeout, check)

            run = SimpleNamespace(root=root, read=lambda: driver.read_json(state_url),
                                  verify=lambda: None, wait=wait)
            app = threading.Thread(target=fake_app)
            app.start()
            try:
                fields = {"action": "copy.ref"}
                self.assertEqual(driver.action(run, fields, 4), expected)
                self.assertEqual(driver.read_json(request), {**fields, "version": 1,
                                                             "run": "owned", "seq": 1})
                self.assertTrue(saw_settled_without_response.is_set())
            finally:
                waiting.set()
                saw_settled_without_response.set()
                app.join(5)



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

class FixtureCLI(unittest.TestCase):
    def setUp(self):
        scratch = self.enterContext(tempfile.TemporaryDirectory())
        self.root = Path(scratch)
        self.run = Mock(root=self.root / "run")
        self.run.read.return_value = {"fixtureNow": "2030-06-01T02:03:04.000Z"}
        self.data = self.run.root / "data"
        self.data.mkdir(parents=True)
        self.database = self.data / "silta.db"
        self.database.touch()
        self.cli = self.root / ".build/debug/silta"
        self.cli.parent.mkdir(parents=True)
        self.audit = self.run.root / "cli.json"
        self.enterContext(patch.object(driver, "ROOT", self.root))

    def stub(self, stdout, status=0):
        self.cli.write_text(
            f"#!{sys.executable}\n"
            "import json, os, pathlib, sys\n"
            "pathlib.Path('cli.json').write_text(json.dumps("
            "{'args': sys.argv[1:], 'env': dict(os.environ), 'cwd': os.getcwd()}))\n"
            f"print({stdout!r})\n"
            f"sys.exit({status})\n"
        )
        self.cli.chmod(0o700)

    def test_fixture_cli_uses_scrubbed_environment_and_exact_args(self):
        self.stub("AC-24")
        with patch.dict(os.environ, {"HOME": "/ignore-parent-home", "SILTA_HOME": "/ignore-silta-home",
                                     "SILTA_NOW": "ignore-parent-clock", "SILTA_TOKEN": "unused"}):
            self.assertEqual(driver.write_fixture_proposal(self.run, "--example title"), "AC-24")
        call = driver.read_json(self.audit)
        self.assertEqual(call["args"], ["--ws", "acme", "task", "add", "--quiet", "--",
                                        "--example title"])
        self.assertEqual(Path(call["cwd"]).resolve(), self.run.root.resolve())
        self.assertEqual(call["env"]["HOME"], str(self.run.root))
        self.assertEqual(call["env"]["SILTA_HOME"], str(self.data))
        self.assertEqual(call["env"]["SILTA_ACTOR"], "agent:codex:control")
        self.assertEqual(call["env"]["SILTA_NOW"], "2030-06-01T02:03:04.000Z")
        self.assertNotIn("SILTA_TOKEN", call["env"])

    def test_linked_fixture_store_refuses_before_invoking_cli(self):
        self.stub("AC-24")
        external = self.root / "external"
        self.data.rename(external)
        self.data.symlink_to(external, target_is_directory=True)
        with self.assertRaisesRegex(driver.DriverError, "isolated directory"):
            driver.write_fixture_proposal(self.run, "Acme test")
        self.data.unlink()
        self.data.mkdir()
        os.link(external / "silta.db", self.database)
        with self.assertRaisesRegex(driver.DriverError, "isolated directory"):
            driver.write_fixture_proposal(self.run, "Acme test")
        self.assertFalse(self.audit.exists())

    def test_fixture_cli_refuses_failed_exit_and_unparsable_ref(self):
        for stdout, status in (("AC-24", 1), ("AC-0", 0), ("AC-24\nother", 0)):
            with self.subTest(stdout=stdout, status=status):
                self.stub(stdout, status)
                with self.assertRaisesRegex(driver.DriverError, "did not return a task reference"):
                    driver.write_fixture_proposal(self.run, "Acme test")
                self.assertTrue(self.audit.exists())
                self.audit.unlink()


class FixtureWriteRecovery(unittest.TestCase):
    def test_intent_survives_interruption_and_never_replays(self):
        with tempfile.TemporaryDirectory() as root:
            record = Path(root) / "write.json"
            calls = []

            def interrupted(title):
                calls.append(title)
                raise OSError("interrupted after commit")

            with self.assertRaisesRegex(driver.DriverError, "ambiguous"):
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

    def test_new_write_does_not_create_intent_with_no_mailbox_or_pending_request(self):
        for state in ({"run": "owned", "seq": None, "settledSeq": None},
                      {"run": "owned", "seq": 1, "settledSeq": 0},
                      {"run": "owned", "seq": 0, "settledSeq": 0}):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch)
                cli = root / ".build/debug/silta"
                cli.parent.mkdir(parents=True)
                cli.touch()
                if state["seq"] == 0:
                    driver.atomic_json(root / "req-1.json", {"action": "nav"})
                run = Mock(root=root)
                run.read.return_value = state
                with patch.object(driver, "ROOT", root), \
                        patch.object(driver, "write_fixture_proposal") as write:
                    with self.assertRaisesRegex(driver.DriverError, "mailbox|outstanding"):
                        driver.fixture_write(run, "new", "Acme review", 1)
                    write.assert_not_called()
                self.assertFalse((root / "write-new.json").exists())

    def test_published_action_failure_identifies_the_recoverable_sequence(self):
        for error in (subprocess.TimeoutExpired("identity", 5), OSError("read failed"),
                      KeyboardInterrupt()):
            with self.subTest(error=type(error)), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch)
                run = Mock(root=root)
                run.read.return_value = {"run": "owned", "seq": 0, "settledSeq": 0}
                run.wait.side_effect = error
                fields = {"action": "inspector.toggle"}
                with self.assertRaisesRegex(driver.DriverError, "--seq 1"):
                    driver.action(run, fields, 1)
                original = (root / "req-1.json").read_bytes()
                run.wait.side_effect = None
                driver.atomic_json(root / "res-1.json", {"version": 1, "run": "owned", "seq": 1,
                                                         "outcome": "accepted"})
                self.assertEqual(driver.action(run, fields, 1, sequence=1)["outcome"], "accepted")
                self.assertEqual((root / "req-1.json").read_bytes(), original)
                self.assertFalse((root / "req-2.json").exists())

    def test_written_receipt_retries_only_refresh_after_failure(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            cli = root / ".build/debug/silta"
            cli.parent.mkdir(parents=True)
            cli.touch()
            run = Mock(root=root)
            run.read.return_value = {"run": "owned", "seq": 0, "settledSeq": 0}
            with patch.object(driver, "ROOT", root), \
                    patch.object(driver, "write_fixture_proposal", return_value="AC-24") as write, \
                    patch.object(driver, "action", side_effect=[driver.DriverError("refresh wait"),
                                                                 {"outcome": "accepted"}]) as send:
                with self.assertRaisesRegex(driver.DriverError, "Created AC-24. Refresh is uncertain"):
                    driver.fixture_write(run, "new", "Acme recovery", 1)
                self.assertEqual(driver.fixture_write(run, "new", "Acme recovery", 1)["ref"], "AC-24")
                write.assert_called_once_with(run, "Acme recovery")
                self.assertEqual(send.call_count, 2)
