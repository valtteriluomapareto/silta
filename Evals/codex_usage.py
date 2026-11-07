"""Observe native Codex usage and stop a trial at its observed token budget."""
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time


def tokens(usage):
    if not isinstance(usage, dict):
        return None
    values = [usage.get('input_tokens'), usage.get('output_tokens')]
    # Cached input and reasoning output are subsets, not extra billable tokens.
    return sum(values) if all(type(n) is int and n >= 0 for n in values) else None


class TokenBudget:
    def __init__(self, codex_home, limit):
        self.home, self.limit = Path(codex_home), limit
        self.totals = {}
        self.spent = 0
        self.phase_tokens = None

    def start_phase(self):
        self.baseline = sum(self.totals.values())
        self.phase_tokens = None

    def observe(self, stdout):
        for path in (self.home / 'sessions').rglob('*.jsonl'):
            for line in path.read_text(errors='replace').splitlines():
                try:
                    event = json.loads(line)
                    payload = event.get('payload', {})
                    if event.get('type') == 'event_msg' and payload.get('type') == 'token_count':
                        total = tokens((payload.get('info') or {}).get('total_token_usage'))
                        if total is not None and total > self.totals.get(path, 0):
                            self.totals[path] = total
                except (ValueError, TypeError, AttributeError):
                    continue
        delta = sum(self.totals.values()) - self.baseline
        candidates = [delta] if delta > 0 else []
        for line in stdout.splitlines():
            try:
                event = json.loads(line)
                if event.get('type') == 'turn.completed':
                    count = tokens(event.get('usage'))
                    if count is not None:
                        candidates.append(count)
            except (ValueError, AttributeError):
                continue
        if candidates:
            self.phase_tokens = max([self.phase_tokens or 0, *candidates])
        return None if self.phase_tokens is None else self.spent + self.phase_tokens

    def finish_phase(self):
        if self.phase_tokens is not None:
            self.spent += self.phase_tokens

    def execute(self, argv, env, cwd, timeout):
        self.start_phase()
        child = subprocess.Popen(argv, env=env, cwd=cwd, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 start_new_session=True)
        buffers = {'stdout': bytearray(), 'stderr': bytearray()}
        failure = None
        deadline = time.monotonic() + timeout
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(child.stdout, selectors.EVENT_READ, 'stdout')
                selector.register(child.stderr, selectors.EVENT_READ, 'stderr')
                while selector.get_map():
                    for event, _ in selector.select(max(0, min(0.1, deadline - time.monotonic()))):
                        chunk = os.read(event.fileobj.fileno(), 65536)
                        if chunk:
                            buffers[event.data].extend(chunk)
                        else:
                            selector.unregister(event.fileobj)
                    total = self.observe(buffers['stdout'].decode(errors='replace'))
                    if not failure:
                        if total is not None and total > self.limit:
                            failure = 'token-limit'
                        elif time.monotonic() >= deadline:
                            failure = 'timeout'
                        if failure:
                            try:
                                os.killpg(child.pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
        finally:
            if child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            child.wait()
            child.stdout.close()
            child.stderr.close()
        total = self.observe(buffers['stdout'].decode(errors='replace'))
        if total is None and not failure:
            failure = 'usage-unavailable'
        self.finish_phase()
        return {'exit': failure or child.returncode, 'tokens': self.phase_tokens,
                **{k: bytes(v).decode(errors='replace') for k, v in buffers.items()}}
