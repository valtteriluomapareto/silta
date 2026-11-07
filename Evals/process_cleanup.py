"""Fixed process-group termination and deadline-bound pipe draining."""
import os
import signal
import subprocess
import time

DRAIN_SECONDS = 2.0


def stop_group(child):
    child.poll()
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        return 'absent'
    except PermissionError:
        # A newly exited, unreaped leader can make killpg return EPERM.
        if child.poll() is None:
            raise
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            return 'absent'
    return 'signalled'


def finish(child, reason, capture=None, buffers=None, initial=(b'', b''), deadline=None, cutoff=False):
    deadline = time.monotonic() + DRAIN_SECONDS if deadline is None else deadline
    outcome = {'pgid': child.pid, 'reason': reason, 'group_status': 'not-requested',
               'drain_cut_short': cutoff, 'main_reaped': False}
    out, err = initial
    drained = False
    try:
        try:
            outcome['group_status'] = stop_group(child)
        except OSError as error:
            outcome.update(group_status='unconfirmed', group_error={'type': type(error).__name__, 'message': str(error)})
        try:
            try:
                out, err = child.communicate(timeout=max(0, deadline - time.monotonic()))
            except KeyboardInterrupt as error:
                outcome.update(reason=reason or 'interrupted', drain_error={'type': type(error).__name__, 'message': str(error)})
                out, err = child.communicate(timeout=max(0, deadline - time.monotonic()))
            drained = True
        except subprocess.TimeoutExpired as error:
            out = error.output if error.output is not None else out
            err = error.stderr if error.stderr is not None else err
            outcome['drain_cut_short'] = True
        except OSError as error:
            outcome.update(drain_cut_short=True, drain_error={'type': type(error).__name__, 'message': str(error)})
        if child.returncode is None:
            try:
                child.wait(timeout=max(0, deadline - time.monotonic()))
            except (subprocess.TimeoutExpired, OSError) as error:
                outcome['reap_error'] = {'type': type(error).__name__, 'message': str(error)}
    finally:
        outcome['main_reaped'] = child.returncode is not None
        if not drained:
            outcome['drain_cut_short'] = True
        for stream in (child.stdout, child.stderr, child.stdin):
            if stream is not None:
                try:
                    stream.close()
                except OSError as error:
                    outcome.update(drain_cut_short=True, drain_error={'type': type(error).__name__, 'message': str(error)})
        if buffers is not None:
            buffers['stdout'].extend(out or b'')
            buffers['stderr'].extend(err or b'')
            out, err = bytes(buffers['stdout']), bytes(buffers['stderr'])
        if capture:
            capture.cleanup = outcome
            try:
                capture.save(out, err, final=not outcome['drain_cut_short'], process_exit=child.returncode)
            except OSError:
                # Retry persistence after stopping writers, and keep the failure visible.
                capture.save(out, err, final=not outcome['drain_cut_short'], process_exit=child.returncode)
                raise
    return out, err, outcome
