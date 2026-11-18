"""Drive the macOS Debug app against a private synthetic fixture."""
import argparse
from contextlib import closing
from functools import lru_cache
import json
import math
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
    "pid": None, "windowNumber": None,
}
READY = [("idle", True), ("refresh.phase", "ready")]


class DriverError(Exception):
    pass


def atomic_json(path, value):
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                     delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(value, stream)
            stream.close()
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
        self.pid = self.record["process"]["pid"]
        self.verify()

    def verify(self):
        saved = self.record["process"]
        if not isinstance(saved, dict) or saved.get("executable") != str(APP.resolve()) or identity(self.pid) != saved:
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
    try:
        process = identity(child.pid) if child.poll() is None else None
        if process is None:
            raise DriverError("Fixture exited during startup.")
        run = Run(root, {"process": process})
        state = run.wait(READY, args.timeout)
        run.record["run"] = state["run"]
        atomic_json(root / "driver.json", run.record)
        print(root)
    except (DriverError, OSError, KeyError, TypeError, ValueError) as error:
        # The unreaped child PID remains reserved until poll/wait collects it.
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=2)
        raise DriverError(f"{error}\nStartup log: {root / 'app.log'}") from error


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
                      and s["windowNumber"] > 0)
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
    args = parser.parse_args(argv)
    try:
        if args.command == "launch":
            launch(args)
            return 0
        if sys.platform != "darwin":
            raise DriverError("The Silta fixture driver requires macOS.")
        run = Run(args.run)
        if args.command == "shot":
            shot(run, args.output, args.timeout)
        elif args.command == "stop":
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
