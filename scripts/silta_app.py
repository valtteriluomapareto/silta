"""Drive the macOS Debug app against a private synthetic fixture."""
import argparse
from contextlib import closing, contextmanager
from functools import lru_cache
import fcntl
import json
import math
import re
import os
from pathlib import Path
import select
import signal
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build/app"
APP = BUILD / "DerivedData/Build/Products/Debug/SiltaApp.app/Contents/MacOS/SiltaApp"
STATE = {
    "snapshotVersion": None, "run": None, "revision": None, "fixture": None,
    "appearance": None, "screen": None, "route": None, "inspectorOpen": None,
    "selection": {"kind": None, "ref": None, "view": None},
    "counts": {"lanes": {}, "sidebar": {"waiting": None, "claimed": None, "apps": {}}},
    "refresh": {"phase": None, "dataVersion": None}, "idle": None,
    "pid": None, "windowNumber": None, "seq": None, "settledSeq": None,
}
READY = [("idle", True), ("refresh.phase", "ready")]


class DriverError(Exception):
    pass


def atomic_json(path, value, *, exclusive=False):
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                     delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(value, stream, separators=(",", ":"), sort_keys=True, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
            stream.close()
            if exclusive:
                os.link(temporary, path)
            else:
                temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def read_json(path):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise DriverError(f"Expected a regular JSON file: {path.name}")
        data = stream.read(256 * 1024 + 1)
    if len(data) > 256 * 1024:
        raise DriverError(f"JSON file is too large: {path.name}")
    return json.loads(data)


def field(state, path):
    schema = STATE
    value = state
    for key in path.removeprefix(".").split("."):
        if not isinstance(schema, dict):
            raise DriverError(f"Unknown state path: {path}")
        if key not in schema and (not isinstance(value, dict) or key not in value):
            raise DriverError(f"Unknown state path: {path}")
        schema = schema.get(key)
        value = value.get(key) if isinstance(value, dict) else None
    return value


def invalid_constant(value):
    raise ValueError(value)


def predicates(expressions):
    result = []
    for expression in expressions:
        path, separator, literal = expression.partition("=")
        try:
            if not separator or not path:
                raise ValueError(expression)
            expected = json.loads(literal, parse_constant=invalid_constant)
        except ValueError as error:
            raise DriverError(f"Expected PATH=JSON: {expression}") from error
        result.append((path, expected))
    return result


def json_text(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def unmet(state, conditions):
    failures = []
    for path, expected in conditions:
        value = field(state, path)
        if json_text(value) != json_text(expected):
            failures.append(f"{path}: expected {json_text(expected)}, observed {json_text(value)}")
    return failures


def wait_for(directory, pid, read, conditions, timeout, ready=lambda _: True):
    deadline = time.monotonic() + timeout
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        with closing(select.kqueue()) as queue:
            try:
                queue.control([
                    select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                                  flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                  fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_RENAME
                                  | select.KQ_NOTE_DELETE),
                    select.kevent(pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD,
                                  fflags=select.KQ_NOTE_EXIT),
                ], 0)
            except ProcessLookupError as error:
                raise DriverError("Fixture process exited before the wait could start.") from error
            while True:
                state = read()
                misses = unmet(state, conditions) if state is not None else ["No state published"]
                if state is not None and not misses and ready(state):
                    return state
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    detail = "\n".join(misses) or "Requested window or action is not ready"
                    raise DriverError(f"Timed out waiting for fixture:\n{detail}")
                for event in queue.control(None, 2, remaining):
                    if event.filter == select.KQ_FILTER_PROC:
                        raise DriverError("Fixture process exited. Check its app.log.")
                    if event.fflags & (select.KQ_NOTE_RENAME | select.KQ_NOTE_DELETE):
                        raise DriverError("Fixture run directory was moved or removed.")
    finally:
        os.close(fd)


@lru_cache(maxsize=1)
def native_tool():
    source = ROOT / "scripts/Control/InspectRun.swift"
    output = BUILD / "inspect-control-run"
    if output.exists() and output.stat().st_mtime_ns >= source.stat().st_mtime_ns:
        return output
    BUILD.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=BUILD) as temporary:
        target = Path(temporary) / output.name
        subprocess.run(["/usr/bin/xcrun", "swiftc", "-D", "DEBUG", str(source), "-o", str(target)],
                       check=True, timeout=60)
        target.replace(output)
    return output


def identity(pid):
    if type(pid) is not int or pid < 1:
        raise DriverError("Invalid fixture process ID.")
    result = subprocess.run([native_tool(), "identity", str(pid)], capture_output=True, timeout=5)
    return json.loads(result.stdout) if result.returncode == 0 else None


def validate_run(path):
    path = Path(path).absolute()
    root = Path(tempfile.gettempdir()).resolve()
    info = path.lstat()
    if (path.parent != root or path.resolve() != path or not path.name.startswith("silta-app-")
            or not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700
            or info.st_uid != os.getuid()):
        raise DriverError("Use a private run directory printed by silta-app.sh launch.")
    return path


class Run:
    def __init__(self, root, record=None):
        self.root = validate_run(root)
        self.record = read_json(self.root / "driver.json") if record is None else record
        if record is None and (not isinstance(self.record, dict)
                               or not isinstance(self.record.get("run"), str)
                               or not self.record["run"]):
            raise DriverError("The fixture driver record has no run identity.")
        self.pid = self.record["process"]["pid"]
        self.verify()

    def verify(self):
        saved = self.record["process"]
        if (not isinstance(saved, dict) or saved.get("executable") != str(APP.resolve())
                or not isinstance(saved.get("directory"), str)
                or Path(saved["directory"]).resolve() != self.root or identity(self.pid) != saved):
            raise DriverError("Fixture process exited or changed identity. Launch a fresh run.")

    def read(self):
        self.verify()
        try:
            state = read_json(self.root / "state.json")
        except FileNotFoundError:
            return None
        if (not isinstance(state, dict) or state.get("snapshotVersion") != 1 or not isinstance(state.get("run"), str)
                or state.get("pid") != self.pid or state.get("fixture") != "v2"
                or self.record.get("run", state["run"]) != state["run"]):
            raise DriverError("State does not belong to the recorded fixture process.")
        return state

    def wait(self, conditions, timeout, ready=lambda _: True):
        return wait_for(self.root, self.pid, self.read, conditions, timeout, ready)


def launch(args):
    if not APP.is_file():
        raise DriverError("Build the Debug app with scripts/verify.sh app first.")
    native_tool()
    root = Path(tempfile.mkdtemp(prefix="silta-app-", dir=Path(tempfile.gettempdir()).resolve()))
    flags = ["-SiltaFixture", "v2", "-SiltaRunDirectory", str(root), "-SiltaRoute", args.route]
    if args.dark:
        flags.append("-SiltaDark")
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("SILTA_", "XCTest", "XCInject"))}
    environment["TZ"] = "UTC"
    with (root / "app.log").open("xb") as log:
        child = subprocess.Popen([APP, *flags], stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                 env=environment, start_new_session=True, cwd=root)
    handed_off = False
    try:
        process = identity(child.pid) if child.poll() is None else None
        if process is None:
            raise DriverError("Fixture exited during startup.")
        run = Run(root, {"process": process})
        state = run.wait(READY, args.timeout)
        run.record["run"] = state["run"]
        atomic_json(root / "driver.json", run.record)
        print(root, flush=True)
        handed_off = True
    except (DriverError, OSError, KeyError, TypeError, ValueError, subprocess.SubprocessError,
            KeyboardInterrupt) as error:
        detail = str(error) or "Interrupted fixture startup."
        raise DriverError(f"{detail}\nStartup log: {root / 'app.log'}") from error
    finally:
        # The unreaped child PID remains reserved until poll/wait collects it.
        if not handed_off and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=2)


def same_capture_state(before, after):
    return ({k: v for k, v in before.items() if k != "revision"}
            == {k: v for k, v in after.items() if k != "revision"})


def confirm_window(run, number):
    run.verify()
    result = subprocess.run([native_tool(), "window", str(run.pid), str(number)], timeout=5)
    if result.returncode:
        raise DriverError("Owned window is not capturable. Check Screen Recording and the active "
                          "window session, or run shot in an authorized Terminal.")


def shot(run, destination, timeout):
    output = Path(destination).absolute()
    if output.suffix.lower() != ".png":
        raise DriverError("Choose a .png output for shot.")
    sidecar = output.with_suffix(output.suffix + ".json")
    if os.path.lexists(output) or os.path.lexists(sidecar):
        raise DriverError("Choose an unused PNG path and sidecar path.")
    before = run.wait(READY, timeout, lambda s: type(s.get("windowNumber")) is int
                      and s["windowNumber"] > 0 and s.get("seq") == s.get("settledSeq"))
    number = before["windowNumber"]
    with tempfile.TemporaryDirectory(dir=output.parent) as directory:
        temporary = Path(directory) / "capture.png"
        confirm_window(run, number)
        result = subprocess.run(["/usr/sbin/screencapture", f"-l{number}", "-o", temporary],
                                capture_output=True, timeout=timeout)
        if result.returncode or not temporary.is_file():
            raise DriverError("screencapture could not capture the owned window. Try the command in "
                              "an authorized Terminal or use -SiltaSnapshot for offscreen evidence.")
        with temporary.open("rb") as stream:
            if stream.read(8) != b"\x89PNG\r\n\x1a\n" or temporary.stat().st_size <= 8:
                raise DriverError("screencapture did not produce a PNG.")
        confirm_window(run, number)
        after = run.read()
        if after is None or not same_capture_state(before, after):
            raise DriverError("Fixture state changed during capture. Wait for it to settle and retry.")
        receipt = temporary.with_suffix(".json")
        atomic_json(receipt, after)
        os.link(receipt, sidecar)
        try:
            os.link(temporary, output)
        except OSError:
            sidecar.unlink()
            raise
    print(output)


@contextmanager
def client_lock(run):
    with os.fdopen(os.open(run.root / "client.lock",
                          os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600), "rb+") as lock:
        if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
            raise DriverError("Fixture client lock is not a regular file.")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise DriverError("Another client is driving this run. Retry after it finishes.") from error
        yield


def unique_fields(pairs):
    result = dict(pairs)
    if len(result) != len(pairs):
        raise ValueError("duplicate JSON object key")
    return result


def action_fields(literal):
    value = json.loads(literal, object_pairs_hook=unique_fields, parse_constant=invalid_constant)
    if (not isinstance(value, dict) or not isinstance(value.get("action"), str)
            or {"version", "run", "seq"} & value.keys()
            or len(literal.encode()) > 15_000):
        raise DriverError("Use an action JSON object without version, run, or seq.")
    return value


def mailbox_state(run):
    state = run.read()
    if (not state or type(state.get("settledSeq")) is not int or type(state.get("seq")) is not int
            or not 0 <= state["settledSeq"] <= state["seq"] <= state["settledSeq"] + 1):
        raise DriverError("Run does not have a live action mailbox.")
    return state


def recovery_error(error, sequence):
    detail = str(error) or "Interrupted while reading the action result."
    return DriverError(f"{detail}\nAction {sequence} may have run. Repeat with --seq {sequence} "
                       "to read its result without replaying it.")


def action(run, fields, timeout, sequence=None):
    state = mailbox_state(run)
    recover = sequence is not None
    if sequence is None:
        sequence = state["settledSeq"] + 1
    request = run.root / f"req-{sequence}.json"
    envelope = {**fields, "version": 1, "run": state["run"], "seq": sequence}
    try:
        existing = read_json(request)
    except FileNotFoundError:
        existing = None
    except (OSError, ValueError, KeyboardInterrupt) as error:
        raise recovery_error(error, sequence) from error
    if existing is None:
        if recover or sequence <= state["seq"]:
            raise DriverError(f"No recorded action at sequence {sequence}.")
        run.verify()
    elif json_text(existing) != json_text(envelope):
        raise DriverError(f"Sequence {sequence} already has a different request. "
                          f"Read {request.name} and recover that action with --seq {sequence}.")
    try:
        if existing is None:
            atomic_json(request, envelope, exclusive=True)
        return await_result(run, sequence, state["run"], timeout)
    except (DriverError, OSError, ValueError, TypeError, AttributeError, KeyError,
            subprocess.SubprocessError, KeyboardInterrupt) as error:
        raise recovery_error(error, sequence) from error


def await_result(run, sequence, run_id, timeout):
    response = run.root / f"res-{sequence}.json"
    run.wait([], timeout, lambda current: current["settledSeq"] >= sequence and response.exists())
    result = read_json(response)
    if (result.get("version") != 1 or result.get("run") != run_id
            or result.get("seq") != sequence or result.get("outcome") not in ("accepted", "noop", "refused")):
        raise DriverError(f"Invalid result for action {sequence}.")
    return result


def fixture_receipt(path, title, write):
    try:
        receipt = read_json(path)
    except FileNotFoundError:
        atomic_json(path, {"title": title}, exclusive=True)
        try:
            reference = write(title)
            atomic_json(path, {"title": title, "ref": reference})
        except (DriverError, OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
            raise DriverError(f"Fixture write result is ambiguous ({path.name}). Inspect the "
                              f"run’s isolated store before choosing a new ID. {error}") from error
        return reference
    if receipt["title"] != title:
        raise DriverError("The fixture write ID belongs to a different title.")
    if not receipt.get("ref"):
        raise DriverError(f"Fixture write result is ambiguous ({path.name}). Inspect the run’s isolated store before choosing a new ID.")
    return receipt["ref"]


def write_fixture_proposal(run, title):
    cli = ROOT / ".build/debug/silta"
    if not cli.is_file():
        raise DriverError("Build the fixture CLI with scripts/verify.sh app.")
    run.verify()
    data = run.root / "data"
    if data.is_symlink() or not (data / "silta.db").is_file() or any(
        path.is_symlink() or (path.is_file() and path.stat().st_nlink != 1)
        for path in data.rglob("*")
    ):
        raise DriverError("Fixture store must be an isolated directory with ordinary files.")
    environment = {"PATH": "/usr/bin:/bin", "HOME": str(run.root), "USER": "acme",
                   "SILTA_HOME": str(data), "SILTA_ACTOR": "agent:codex:control",
                   "SILTA_NOW": "2026-11-16T12:00:00.000Z", "TZ": "UTC"}
    command = [cli, "--ws", "acme", "task", "add", "--quiet", "--", title]
    result = subprocess.run(command, env=environment, cwd=run.root, stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, timeout=15)
    reference = result.stdout.strip()
    if result.returncode or re.fullmatch(r"AC-[1-9][0-9]*", reference) is None:
        raise DriverError("Fixture CLI did not return a task reference. Inspect the isolated store before retrying.")
    return reference


def fixture_write(run, write_id, title, timeout):
    if re.fullmatch(r"[A-Za-z0-9_-]{1,64}", write_id) is None or not title.strip() or len(title.encode()) > 512 or "\0" in title:
        raise DriverError("Use a write ID of 1–64 letters, digits, underscores or hyphens and a short title.")
    if not (ROOT / ".build/debug/silta").is_file():
        raise DriverError("Build the fixture CLI with scripts/verify.sh app.")
    with client_lock(run):
        receipt = run.root / f"write-{write_id}.json"
        if not os.path.lexists(receipt):
            state = mailbox_state(run)
            next_sequence = state["settledSeq"] + 1
            pending = run.root / f"req-{next_sequence}.json"
            if state["seq"] >= next_sequence or os.path.lexists(pending):
                raise DriverError(f"Action {next_sequence} is outstanding. Read {pending.name} "
                                  f"and recover it with --seq {next_sequence} before writing.")
        reference = fixture_receipt(receipt, title, lambda value: write_fixture_proposal(run, value))
        try:
            result = action(run, {"action": "refresh"}, timeout)
        except (DriverError, OSError, subprocess.SubprocessError) as error:
            raise DriverError(f"Created {reference}. Refresh is uncertain: {error}") from error
    return {"ref": reference, "refresh": result}


def seconds(value):
    amount = float(value)
    if not math.isfinite(amount) or not 0 < amount <= 300:
        raise argparse.ArgumentTypeError("seconds must be greater than 0 and at most 300")
    return amount


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    opening = commands.add_parser("launch", help="start an isolated Debug fixture")
    opening.add_argument("--route", default="mywork")
    opening.add_argument("--dark", action="store_true")
    opening.add_argument("--timeout", type=seconds, default=20)
    for name in ("state", "wait", "shot", "stop"):
        sub = commands.add_parser(name)
        sub.add_argument("run", type=Path)
        if name == "state":
            sub.add_argument("path", nargs="?")
        if name == "wait":
            sub.add_argument("conditions", nargs="+", metavar="PATH=JSON")
        if name in ("wait", "shot"):
            sub.add_argument("--timeout", type=seconds, default=10)
        if name == "shot":
            sub.add_argument("output", type=Path)
    send = commands.add_parser("action", help="drive a running fixture through app handlers")
    send.add_argument("run", type=Path)
    send.add_argument("request")
    send.add_argument("--seq", type=int)
    send.add_argument("--timeout", type=seconds, default=10)
    write = commands.add_parser("fixture.write", help="propose a task in the fixture and refresh")
    write.add_argument("run", type=Path)
    write.add_argument("write_id")
    write.add_argument("title")
    write.add_argument("--timeout", type=seconds, default=10)
    args = parser.parse_args(argv)
    try:
        if args.command == "launch":
            launch(args)
            return 0
        if sys.platform != "darwin":
            raise DriverError("The Silta fixture driver requires macOS.")
        run = Run(args.run)
        if args.command == "action":
            if args.seq is not None and args.seq < 1:
                raise DriverError("Sequence must be a positive integer.")
            with client_lock(run):
                result = action(run, action_fields(args.request), args.timeout, args.seq)
            print(json_text(result))
            return int(result["outcome"] == "refused")
        if args.command == "fixture.write":
            result = fixture_write(run, args.write_id, args.title, args.timeout)
            print(json_text(result))
            return int(result["refresh"]["outcome"] == "refused")
        if args.command == "shot":
            shot(run, args.output, args.timeout)
        elif args.command == "stop":
            if run.read() is None:
                raise DriverError("Fixture has no matching published state.")
            run.verify()
            os.kill(run.pid, signal.SIGTERM)
        else:
            state = run.wait(predicates(args.conditions), args.timeout) if args.command == "wait" else run.read()
            if state is None:
                raise DriverError("Fixture has not published state.")
            print(json_text(field(state, args.path) if args.command == "state" and args.path else state))
    except (DriverError, OSError, KeyError, TypeError, ValueError, subprocess.SubprocessError) as error:
        print(f"silta-app: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
