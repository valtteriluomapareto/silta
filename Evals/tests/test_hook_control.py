"""The fixture's session-start control survives hook deadlines without hiding empty output."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import evals

BRIEF = 'workspace: acme\nask_about: short\n'


class FakeHook:
    """Replays session-start attempts, logging each as the CLI's hook log would."""

    def __init__(self, data, attempts):
        self.data, self.attempts, self.calls = data, list(attempts), []

    def __call__(self, env, cwd, args, stdin=None, expected=0):
        self.calls.append((env['SILTA_ACTOR'], env['SILTA_SESSION'], args, json.loads(stdin)))
        stdout, warnings = self.attempts.pop(0)
        entry = {'actor': 'agent:claude:eval-control', 'command': 'silta agents session-start',
                 'exit_code': 0, 'flags': [], 'warnings': warnings}
        log = self.data / 'log'
        log.mkdir(exist_ok=True)
        with (log / 'hook.jsonl').open('a') as handle:
            handle.write(json.dumps(entry) + '\n')
        return {'exit': 0, 'stdout': stdout, 'stderr': ''}


class HookControl(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='silta-hook-control-')
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        self.env = evals.isolated_env(root)
        self.data = Path(self.env['SILTA_HOME'])

    def control(self, *attempts):
        hook = FakeHook(self.data, attempts)
        return evals.hook_control(self.env, self.data, run=hook), hook

    def test_retries_an_attempt_the_cli_logged_as_hook_timeout(self):
        result, hook = self.control(('', ['hook_timeout']), (BRIEF, []))
        self.assertEqual(result['stdout'], BRIEF)
        self.assertEqual(len(hook.calls), 2)
        self.assertEqual(hook.calls[0], ('agent:claude', 'eval-control', ['agents', 'session-start'],
                                         {'session_id': 'eval-control'}))

    def test_empty_output_without_a_timeout_record_is_the_evidence(self):
        result, hook = self.control(('', []), (BRIEF, []))
        self.assertEqual(result['stdout'], '')
        self.assertEqual(len(hook.calls), 1)

    def test_timeouts_on_every_attempt_fail_as_infrastructure(self):
        with self.assertRaisesRegex(RuntimeError, 'hook_timeout on all 3 attempts'):
            self.control(*[('', ['hook_timeout'])] * 3)


if __name__ == '__main__':
    unittest.main()
