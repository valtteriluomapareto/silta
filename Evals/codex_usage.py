"""Observe native Codex usage and stop a trial at its observed token budget."""
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time
import process_cleanup


def tokens(usage):
    if not isinstance(usage, dict):
        return None
    values = [usage.get('input_tokens'), usage.get('output_tokens')]
    # Cached input and reasoning output are subsets, not extra billable tokens.
    return sum(values) if all(type(n) is int and n >= 0 for n in values) else None


class TokenBudget:
    def __init__(self, codex_home, limit):
        self.home, self.limit = Path(codex_home), limit
        self.native, self.terminal = {}, {}
        self.spent = 0
        self.phase_tokens = None

    def start_phase(self):
        self.baseline = self.spent
        self.before = {key: max(self.native.get(key, 0), self.terminal.get(key, 0))
                       for key in self.native.keys() | self.terminal.keys()}
        self.thread, self.current_terminal = None, None
        self.phase_tokens = None

    def observe(self, stdout):
        for line in stdout.splitlines():
            try:
                event = json.loads(line)
                if event.get('type') == 'thread.started':
                    self.thread = event.get('thread_id')
                elif event.get('type') == 'turn.completed':
                    self.current_terminal = tokens(event.get('usage'))
            except (ValueError, AttributeError):
                continue
        for path in (self.home / 'sessions').rglob('*.jsonl'):
            identity = None
            for line in path.read_text(errors='replace').splitlines():
                try:
                    event = json.loads(line)
                    payload = event.get('payload', {})
                    if event.get('type') == 'session_meta':
                        identity = payload.get('id')
                    count = (tokens((payload.get('info') or {}).get('total_token_usage'))
                             if event.get('type') == 'event_msg' and payload.get('type') == 'token_count' else None)
                except (ValueError, TypeError, AttributeError):
                    continue
                if count is not None:
                    if not isinstance(identity, str) or not identity:
                        raise ValueError('Native token_count missing session_meta identity')
                    self.native[identity] = max(count, self.native.get(identity, 0))
        terminal = dict(self.terminal)
        if self.current_terminal is not None:
            if not isinstance(self.thread, str) or not self.thread:
                raise ValueError('Native terminal usage missing thread identity')
            terminal[self.thread] = max(terminal.get(self.thread, 0), self.current_terminal)
        identities = self.native.keys() | terminal.keys()
        total = sum(max(self.native.get(key, 0), terminal.get(key, 0)) for key in identities) if identities else None
        known = (self.current_terminal is not None or
                 self.thread in self.native and self.native[self.thread] > self.before.get(self.thread, 0))
        self.phase_tokens = max(0, total - self.baseline) if known and total is not None else None
        return total

    def finish_phase(self):
        if self.current_terminal is not None:
            self.terminal[self.thread] = max(self.terminal.get(self.thread, 0), self.current_terminal)
        if self.phase_tokens is not None:
            self.spent += self.phase_tokens

    def recover_phase(self, usage, identity):
        count = tokens(usage)
        if count is not None and (not isinstance(identity, str) or not identity):
            return None
        if count is None and self.phase_tokens is None:
            return None
        counts = {key: max(self.native.get(key, 0), self.terminal.get(key, 0))
                  for key in self.native.keys() | self.terminal.keys()}
        if count is not None:
            counts[identity] = max(counts.get(identity, 0), count)
        return max(0, sum(counts.values()) - self.baseline, self.phase_tokens or 0)

    def execute(self, argv, env, cwd, timeout, capture=None):
        self.start_phase()
        child = subprocess.Popen(argv, env=env, cwd=cwd, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 start_new_session=True)
        buffers = {'stdout': bytearray(), 'stderr': bytearray()}
        failure, aborted = None, None
        deadline, post_exit = time.monotonic() + timeout, None
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
                    if capture:
                        capture.save(buffers['stdout'], buffers['stderr'], final=False)
                    total = self.observe(buffers['stdout'].decode(errors='replace'))
                    now = time.monotonic()
                    if child.poll() is not None and post_exit is None:
                        post_exit = now + process_cleanup.DRAIN_SECONDS
                    if total is not None and total > self.limit:
                        failure = 'token-limit'
                    elif now >= deadline:
                        failure = 'timeout'
                    elif selector.get_map() and post_exit is not None and now >= post_exit:
                        failure = 'drain-timeout'
                    if failure:
                        break
            if not failure:
                try:
                    child.wait(timeout=max(0, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    failure = 'timeout'
        except BaseException as error:
            aborted = 'interrupted' if isinstance(error, KeyboardInterrupt) else 'exception'
            raise
        finally:
            process_cleanup.finish(child, failure or aborted or child.returncode, capture=capture, buffers=buffers,
                                   deadline=post_exit if failure == 'drain-timeout' else None,
                                   cutoff=failure == 'drain-timeout')
        total = self.observe(buffers['stdout'].decode(errors='replace'))
        if not failure and total is not None and total > self.limit:
            failure = 'token-limit'
        if self.phase_tokens is None and not failure:
            failure = 'usage-unavailable'
        if capture and failure:
            capture.cleanup['reason'] = failure
        self.finish_phase()
        return {'exit': failure or child.returncode, 'process_exit': child.returncode,
                'tokens': self.phase_tokens,
                **{k: bytes(v).decode(errors='replace') for k, v in buffers.items()}}
