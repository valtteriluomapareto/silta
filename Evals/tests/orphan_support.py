"""Instrument only explicit fake native groups for bounded-cleanup regressions."""
import errno
import json
import os
from pathlib import Path
import signal
import sys
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import evals


def configure(journal, mode):
    journal = Path(journal)
    actual_launch, actual_kill = evals.subprocess.Popen, os.killpg
    native = []
    clock_offset = [0]
    actual_clock = time.monotonic
    if 'live-timeout' in mode:
        os.mkfifo(journal.with_suffix('.ready'))
        time.monotonic = lambda: actual_clock() + clock_offset[0]
    def launch(argv, *args, **kwargs):
        child = actual_launch(argv, *args, **kwargs)
        if '/harnesses/' in str(argv[0]):
            native.append(child)
            journal.with_suffix('.group').write_text(str(child.pid))
            with journal.with_suffix('.groups').open('a') as output:
                output.write(str(child.pid) + '\n')
            if 'live-timeout' in mode:
                communicate = child.communicate
                def timeout_once(*args, **kwargs):
                    if not clock_offset[0]:
                        with journal.with_suffix('.ready').open() as ready:
                            ready.readline()
                        clock_offset[0] = 1000
                        raise subprocess.TimeoutExpired(child.args, kwargs['timeout'])
                    return communicate(*args, **kwargs)
                child.communicate = timeout_once
        return child
    def kill(pgid, sig):
        if native and pgid == native[0].pid:
            if 'permission' in mode:
                raise PermissionError(errno.EPERM, 'Injected live group permission failure')
            with journal.with_suffix('.signals').open('a') as output:
                output.write(json.dumps({'pgid': pgid, 'main_exit': native[0].poll(), 'signal': sig}) + '\n')
        return actual_kill(pgid, sig)
    original_observe = evals.TokenBudget.observe
    def observe(budget, stream):
        oracle = journal.with_name(journal.stem + '.0.stdout')
        if ('parse' in mode or 'interrupt' in mode) and oracle.exists() and b'turn.completed' in oracle.read_bytes():
            native[0].wait(timeout=3)
            if 'interrupt' in mode:
                raise KeyboardInterrupt()
            raise ValueError('Injected parse failure after native parent exited')
        return original_observe(budget, stream)
    evals.subprocess.Popen, os.killpg = launch, kill
    evals.TokenBudget.observe = observe
