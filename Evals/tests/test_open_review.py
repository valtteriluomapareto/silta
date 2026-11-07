"""Deterministic reproductions for mixed native usage and supervisor failure paths."""
import json
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import codex_usage
import open_matrix


def stream(thread, n=10):
    return '\n'.join(json.dumps(event) for event in [
        {'type': 'thread.started', 'thread_id': thread},
        {'type': 'turn.completed', 'usage': {'input_tokens': n, 'output_tokens': 5}}])


def native(path, thread, n):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('\n'.join(json.dumps(event) for event in [
        {'type': 'session_meta', 'payload': {'id': thread}},
        {'type': 'event_msg', 'payload': {'type': 'token_count', 'info': {
            'total_token_usage': {'input_tokens': n, 'output_tokens': 5}}}}]) + '\n')


class OpenReview(unittest.TestCase):
    def test_late_cumulative_resume_usage_is_not_charged_twice(self):
        for resumed in [True, False]:
            with self.subTest(resumed=resumed), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                budget = codex_usage.TokenBudget(root, 35)
                budget.start_phase()
                self.assertEqual(budget.observe(stream('a')), 15)
                budget.finish_phase()
                budget.start_phase()
                thread = 'a' if resumed else 'b'
                native(root / 'sessions/late.jsonl', thread, 25 if resumed else 10)
                self.assertEqual(budget.observe(stream(thread)), 30)
                self.assertEqual(budget.observe(stream(thread)), 30)
                self.assertLessEqual(budget.observe(stream(thread)), budget.limit)

    def test_terminal_usage_is_cumulative_across_resume_without_session_files(self):
        with tempfile.TemporaryDirectory() as directory:
            budget = codex_usage.TokenBudget(directory, 35)
            budget.start_phase()
            self.assertEqual(budget.observe(stream('a')), 15)
            budget.finish_phase()
            budget.start_phase()
            self.assertEqual(budget.observe(stream('a', 25)), 30)
            self.assertEqual(budget.phase_tokens, 15)
            self.assertEqual(budget.observe(stream('a', 25)), 30)

    def test_duplicate_native_files_reconcile_by_session_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            budget = codex_usage.TokenBudget(root, 35)
            budget.start_phase()
            native(root / 'sessions/a.jsonl', 'a', 10)
            self.assertEqual(budget.observe(stream('a')), 15)
            budget.finish_phase()
            budget.start_phase()
            native(root / 'sessions/copied.jsonl', 'a', 25)
            self.assertEqual(budget.observe(stream('a')), 30)

    def test_final_usage_observation_still_enforces_cap_and_retains_native_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            budget = codex_usage.TokenBudget(directory, 50)
            child = Mock(pid=1234, returncode=7, stdout=io.BytesIO(), stderr=io.BytesIO())
            child.poll.return_value = 7
            def observed(_):
                budget.phase_tokens = 100
                return 100
            with patch.object(codex_usage.subprocess, 'Popen', return_value=child):
                with patch.object(budget, 'observe', side_effect=observed), patch.object(codex_usage.os, 'killpg'), patch.object(codex_usage.selectors, 'DefaultSelector') as selector:
                    selector.return_value.__enter__.return_value.get_map.return_value = {}
                    result = budget.execute(['fake-only'], {}, Path(directory), 1)
            self.assertEqual(result['exit'], 'token-limit')
            self.assertEqual(result['process_exit'], 7)
            self.assertEqual(result['tokens'], 100)

    def test_closed_pipes_do_not_kill_a_process_before_its_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            budget = codex_usage.TokenBudget(directory, 50)
            child = Mock(pid=1234, returncode=7, stdout=io.BytesIO(), stderr=io.BytesIO())
            child.poll.side_effect = lambda: child.returncode if child.wait.called else None
            def observed(_):
                budget.phase_tokens = 15
                return 15
            with patch.object(codex_usage.subprocess, 'Popen', return_value=child):
                with patch.object(budget, 'observe', side_effect=observed), patch.object(codex_usage.os, 'killpg') as kill, patch.object(codex_usage.selectors, 'DefaultSelector') as selector:
                    selector.return_value.__enter__.return_value.get_map.return_value = {}
                    result = budget.execute(['fake-only'], {}, Path(directory), 1)
            kill.assert_not_called()
            self.assertEqual(result['exit'], 7)

    def test_malformed_optional_report_never_loses_model_exit_or_later_models(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'matrix'
            seen = []
            def launch(argv):
                seen.append(argv)
                output = Path(argv[argv.index('--output') + 1])
                output.mkdir()
                (output / 'report.json').write_text('{partial' if len(seen) == 1 else '{"tokens": 30}')
                return subprocess.CompletedProcess(argv, 7 if len(seen) == 1 else 0)
            with patch.object(open_matrix.subprocess, 'run', side_effect=launch):
                result = open_matrix.main(['--silta', 'fake-only', '--client', 'fake-only', '--models',
                                           'acme/a', 'acme/b', '--max-trial-tokens', '50', '--output', str(root)])
            self.assertEqual(result, 1)
            manifest = json.loads((root / 'matrix.json').read_text())
            self.assertEqual([m['exit'] for m in manifest['models']], [7, 0])
            self.assertIsNone(manifest['models'][0]['tokens'])
            self.assertEqual(manifest['models'][1]['tokens'], 30)


if __name__ == '__main__':
    unittest.main()
