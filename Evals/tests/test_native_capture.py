"""Exact stream capture, split-key filtering and exception-time pipe draining."""
import hashlib
import os
import signal
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import evals
from codex_usage import TokenBudget
from native_capture import NativeCapture

KEY = 'fake-capture-key-never-written'


class Capture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='silta-capture-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_every_split_key_boundary_is_filtered_before_persistence(self):
        raw = b'prefix:' + KEY.encode() + b':suffix'
        safe = raw.replace(KEY.encode(), b'[REDACTED]')
        for split in range(1, len(KEY)):
            capture = NativeCapture(self.root, split, KEY)
            part = b'prefix:' + KEY[:split].encode()
            capture.save(part, part, final=False)
            self.assertFalse(capture.streams['stdout']['complete'], 'Partial capture marked complete')
            for path in capture.paths.values():
                self.assertTrue(safe.startswith(path.read_bytes()), 'Unsafe key prefix published')
            capture.save(raw, raw, final=False)
            capture.save(raw, raw, process_exit=-9)
            for stream, path in capture.paths.items():
                self.assertEqual(path.read_bytes(), safe, 'Full key not filtered')
                self.assertEqual(capture.streams[stream]['sha256'], hashlib.sha256(safe).hexdigest())
                self.assertTrue(capture.streams[stream]['complete'])
            for path in self.root.iterdir():
                self.assertNotIn(KEY.encode(), path.read_bytes())

    def test_recovered_usage_keeps_distinct_identities_and_rejects_ambiguity(self):
        budget = TokenBudget(self.root / 'codex', 100)
        budget.start_phase()
        budget.native = {'a': 10, 'b': 20}
        budget.phase_tokens = 30
        usage = {'input_tokens': 10, 'output_tokens': 5}
        self.assertEqual(budget.recover_phase(usage, 'a'), 35, 'Other identity usage lost during recovery')
        budget.baseline = 15
        budget.native, budget.terminal = {'a': 15}, {'a': 15}
        budget.phase_tokens = None
        self.assertIsNone(budget.recover_phase({'input_tokens': 20, 'output_tokens': 10}, None))
        self.assertEqual(budget.recover_phase({'input_tokens': 20, 'output_tokens': 10}, 'a'), 15)

    def test_uncapped_interruption_replaces_communicate_buffer_without_duplication(self):
        capture = NativeCapture(self.root, 0)
        out, err = b'prefix\xfftail\n', b'stderr\n'
        child = Mock(pid=1234, returncode=-9)
        child.communicate.side_effect = [KeyboardInterrupt(), (out, err)]
        with patch.object(evals.subprocess, 'Popen', return_value=child), patch.object(evals.os, 'killpg') as kill:
            with self.assertRaises(KeyboardInterrupt):
                evals.execute(['explicit-fake'], {}, self.root, 10, capture=capture)
            kill.assert_called_once()
        self.assertEqual(capture.paths['stdout'].read_bytes(), out)
        self.assertEqual(capture.paths['stderr'].read_bytes(), err)

    def test_capped_exception_drains_unread_bytes_once_and_filters_key(self):
        go, ready = self.root / 'go', self.root / 'ready'
        os.mkfifo(go)
        os.mkfifo(ready)
        split = len(KEY) // 2
        prefix = b'prefix:' * 20 + KEY[:split].encode()
        tail = KEY[split:].encode() + b':tail' * 1000
        stderr = b'error:' + KEY.encode() + b':end'
        script = ('import os,sys\n'
                  + 'sys.stdout.buffer.write(' + repr(prefix) + ');sys.stdout.buffer.flush()\n'
                  + 'with open(sys.argv[1]) as go: go.readline()\n'
                  + 'sys.stdout.buffer.write(' + repr(tail) + ');sys.stdout.buffer.flush()\n'
                  + 'sys.stderr.buffer.write(' + repr(stderr) + ');sys.stderr.buffer.flush()\n'
                  + 'with open(sys.argv[2], "w") as ready: ready.write("ready\\n")\n'
                  + 'read_end,write_end=os.pipe();os.read(read_end,1)\n')
        capture = NativeCapture(self.root, 0, KEY)
        budget = TokenBudget(self.root / 'codex', 100)
        def fail_after_full_output(_):
            self.assertGreater(capture.paths['stdout'].stat().st_size, 0, 'Native interpreted before capture')
            with go.open('w') as writer:
                writer.write('go\n')
            with ready.open() as reader:
                reader.readline()
            raise ValueError('Injected usage parser failure')
        with patch.object(budget, 'observe', side_effect=fail_after_full_output):
            with self.assertRaisesRegex(ValueError, 'Injected usage parser failure'):
                budget.execute([sys.executable, '-B', '-c', script, str(go), str(ready)],
                               {'HOME': str(self.root), 'SILTA_HOME': str(self.root / 'data'), 'PATH': os.defpath},
                               self.root, 30, capture=capture)
        self.assertEqual(capture.paths['stdout'].read_bytes(), (prefix + tail).replace(KEY.encode(), b'[REDACTED]'), 'Unread native bytes lost or duplicated')
        self.assertEqual(capture.paths['stderr'].read_bytes(), stderr.replace(KEY.encode(), b'[REDACTED]'), 'Unread native bytes lost or duplicated')
        self.assertEqual(capture.process_exit, -9)

    def test_failed_stream_write_is_explicit_and_other_stream_survives(self):
        capture = NativeCapture(self.root, 0, KEY)
        original = Path.write_bytes
        def write(path, value):
            if path == capture.paths['stdout']:
                raise OSError('Capture write failed: ' + KEY)
            return original(path, value)
        with patch.object(Path, 'write_bytes', write):
            with self.assertRaises(OSError):
                capture.save(b'out', b'err', process_exit=7)
        self.assertFalse(capture.streams['stdout']['complete'])
        self.assertTrue(capture.streams['stderr']['complete'])
        self.assertEqual(capture.paths['stderr'].read_bytes(), b'err')
        self.assertNotIn(KEY, str(capture.status()))

    def test_capture_exception_still_kills_and_reaps_capped_client(self):
        capture = NativeCapture(self.root, 0)
        budget = TokenBudget(self.root / 'codex', 100)
        actual_popen = evals.subprocess.Popen
        actual_kill = os.killpg
        children = []
        killed = set()
        def kill(pid, sig):
            killed.add(pid)
            actual_kill(pid, sig)
        def launch(*args, **kwargs):
            child = actual_popen(*args, **kwargs)
            children.append(child)
            communicate = child.communicate
            def reap(*args, **kwargs):
                if child.pid not in killed:
                    actual_kill(child.pid, signal.SIGKILL)
                    communicate(*args, **kwargs)
                    self.fail('Capture failure left client running')
                return communicate(*args, **kwargs)
            child.communicate = reap
            return child
        script = 'import os,sys;sys.stdout.write("prefix\\n");sys.stdout.flush();r,w=os.pipe();os.read(r,1)'
        with patch.object(evals.subprocess, 'Popen', side_effect=launch), patch.object(evals.os, 'killpg', side_effect=kill), patch.object(capture, 'save', side_effect=OSError('Injected capture write failure')):
            with self.assertRaisesRegex(OSError, 'Injected capture write failure'):
                budget.execute([sys.executable, '-B', '-c', script],
                               {'HOME': str(self.root), 'SILTA_HOME': str(self.root / 'data'), 'PATH': os.defpath},
                               self.root, 30, capture=capture)
        self.assertEqual(len(children), 1)
        self.assertEqual(children[0].returncode, -9, 'Capture failure left client running')


if __name__ == '__main__':
    unittest.main()
