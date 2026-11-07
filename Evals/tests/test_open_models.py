"""Offline acceptance of unattended provider, operator, budget and audit boundaries."""
import contextlib
import copy
import importlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import evals

KEY = 'fake-si63-credential-never-export-this'
BINARY = ROOT.parent / '.build/debug/silta'
FAKE = ROOT / 'tests/fake_codex.py'


class OpenModels(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='silta-open-test-')
        self.output = Path(self.temp.name)
        self.console = io.StringIO()
        self.env = patch.dict(os.environ, FIREWORKS_API_KEY=KEY)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.addCleanup(self.temp.cleanup)

    def trial(self, scenario='proposals-ask', variant='present-add', recording='pass',
              behavior='plain', cap=1000):
        model = f'fake:{scenario}:{variant}:{recording}:{behavior}'
        with patch('builtins.input', side_effect=AssertionError('Unattended input prompt')) as prompt:
            with contextlib.redirect_stdout(self.console), contextlib.redirect_stderr(self.console):
                result = evals.run_trial(BINARY, 'codex', model, scenario, variant, 1, FAKE,
                                        self.output, provider='fireworks', operator='scripted',
                                        max_trial_tokens=cap)
            self.assertEqual(prompt.call_count, 0)
        evidence = json.loads((self.output / result['evidence']).read_text())
        profile = Path((self.output / result['id'] / 'profile-location.txt').read_text().strip())
        self.addCleanup(shutil.rmtree, profile, True)
        return result, evidence, profile

    def test_fake_key_absent_from_shell_console_and_every_export(self):
        result, evidence, profile = self.trial(behavior='echo')
        self.assertEqual(evidence['phases'][0]['exit'], 0, (self.output / result['id'] / 'phase-0.stderr').read_text())
        self.assertTrue(evidence['phases'][0]['complete'])
        self.assertEqual([p['exit'] for p in evidence['phases']], [0, 0])
        self.assertFalse((profile / 'profile-launcher.sh').exists())
        report = evals.aggregate([result], 'live')
        evals.write_json(self.output / 'report.json', report)
        (self.output / 'report.html').write_text(evals.render_html(report))
        for path in self.output.rglob('*'):
            if path.is_file():
                self.assertNotIn(KEY.encode(), path.read_bytes(), str(path))
        self.assertNotIn(KEY, self.console.getvalue())
        self.assertIn('[REDACTED]', (self.output / result['id'] / 'phase-0.stderr').read_text())
        self.assertEqual(result['provider'], 'fireworks')
        self.assertEqual(result['operator_source'], 'scripted-operator')
        self.assertEqual(result['metrics']['tokens'], 30)
        self.assertIsNone(result['metrics']['cost_usd'])

    def test_key_never_reaches_setup_or_git_and_errors_are_sanitized(self):
        ordinary = os.environ['HOME']
        original = evals.subprocess.check_output
        observed = []
        def inspect(argv, **kwargs):
            if argv[0] == 'git':
                observed.append(argv)
                self.assertNotIn('FIREWORKS_API_KEY', kwargs['env'])
                self.assertEqual(kwargs['env']['HOME'], ordinary)
            return original(argv, **kwargs)
        original_execute = evals.execute
        def setup(argv, env, *args, **kwargs):
            self.assertNotIn('FIREWORKS_API_KEY', env)
            return original_execute(argv, env, *args, **kwargs)
        with patch.object(evals.subprocess, 'check_output', side_effect=inspect), patch.object(evals, 'execute', side_effect=setup):
            self.trial(scenario='plan-not-file', variant='default')
        self.assertTrue(observed)
        with patch.object(evals, 'run_trial', side_effect=RuntimeError(KEY)):
            with patch.object(sys, 'argv', ['evals.py', '--silta', str(BINARY), '--live', '--harness', 'codex',
                 '--client', str(FAKE), '--model', 'fake', '--provider', 'fireworks', '--operator', 'scripted',
                 '--scenario', 'plan-not-file', '--repeats', '1', '--output', str(self.output / 'failure')]):
                self.assertEqual(evals.main(), 1)
        for path in (self.output / 'failure').rglob('*'):
            if path.is_file():
                self.assertNotIn(KEY.encode(), path.read_bytes())

    def test_contaminated_data_is_infrastructure_failure_without_database_export(self):
        result, evidence, profile = self.trial(scenario='plan-not-file', variant='default', behavior='contaminate')
        self.assertFalse(result['checks']['infrastructure'])
        self.assertFalse(result['passed'])
        self.assertFalse((self.output / result['id'] / 'silta.db').exists())
        for path in self.output.rglob('*'):
            if path.is_file():
                self.assertNotIn(KEY.encode(), path.read_bytes())

    def test_scripted_grant_is_bound_and_cannot_impersonate_human(self):
        result, evidence, _ = self.trial()
        self.assertTrue(result['checks']['approval_provenance'])
        self.assertEqual(evidence['operator'], 'scripted')
        self.assertEqual(evidence['approval']['source'], 'scripted-operator')
        self.assertTrue(evidence['approval']['words'])
        for key, value in [('operator', 'interactive'), ('approval', dict(evidence['approval'], source='operator-stdin'))]:
            altered = copy.deepcopy(evidence)
            altered[key] = value
            self.assertFalse(evals.approval_matches(altered))

        unsolicited = copy.deepcopy(evidence)
        unsolicited['phases'][0]['messages'] = ['The model claims it followed policy.']
        unsolicited['approval']['phase_digest'] = evals.digest(unsolicited['phases'][0])
        self.assertFalse(evals.approval_matches(unsolicited))

    def test_scripted_denial_records_source_and_sends_no_approval(self):
        result, evidence, _ = self.trial(recording='fail')
        self.assertEqual(evidence['approval']['source'], 'scripted-operator')
        self.assertEqual(evidence['approval']['words'], '')
        self.assertFalse(result['checks']['approval_provenance'])
        self.assertEqual(evidence['phases'][1]['state']['approvals'], evidence['baseline']['approvals'])
        evidence['approval']['words'] = 'Add the Acme retry fix for later.'
        self.assertFalse(evals.approval_matches(evidence))

    def test_usage_cap_kills_before_terminal_and_prevents_next_phase(self):
        execute = evals.TokenBudget.execute
        def bounded(budget, argv, env, cwd, timeout):
            return execute(budget, argv, env, cwd, min(timeout, 5))
        with patch.object(evals.TokenBudget, 'execute', bounded):
            result, evidence, _ = self.trial(behavior='overflow', cap=50)
        self.assertEqual(len(evidence['phases']), 1)
        self.assertEqual(evidence['phases'][0]['exit'], 'token-limit')
        self.assertFalse(result['checks']['infrastructure'])
        self.assertEqual(result['metrics']['tokens'], 100)
        evidence['review'] = {'digest': evals.review_digest(evidence), 'reviewer': 'claude-coordinator',
                              'checks': ['tool-audit', 'policy-semantics']}
        self.assertFalse(evals.grade(evidence)['passed'])

    def test_two_turn_cap_counts_native_usage_once_and_preserves_failure(self):
        result, evidence, _ = self.trial(cap=20)
        self.assertEqual(result['metrics']['tokens'], 30)
        self.assertEqual(evidence['phases'][1]['exit'], 'token-limit')
        self.assertFalse(result['checks']['infrastructure'])

    def test_missing_usage_under_cap_fails_closed(self):
        result, _, _ = self.trial(scenario='plan-not-file', variant='default', behavior='missing-usage')
        self.assertFalse(result['checks']['infrastructure'])
        self.assertIsNone(result['metrics']['tokens'])

    def test_native_usage_reconciles_resume_repeats_partial_and_fresh_sessions(self):
        usage = importlib.import_module('codex_usage')
        sessions = self.output / 'sessions'
        sessions.mkdir()
        budget = usage.TokenBudget(self.output, 100)
        def record(name, n, tail=''):
            data = {'type': 'event_msg', 'payload': {'type': 'token_count', 'info': {'total_token_usage': {
                'input_tokens': n, 'cached_input_tokens': n, 'output_tokens': 5, 'reasoning_output_tokens': 5}}}}
            (sessions / name).write_text(json.dumps({'type': 'session_meta', 'payload': {'id': name[0]}}) + '\n' + json.dumps(data) + '\n' + tail)
        budget.start_phase()
        record('a.jsonl', 10, '{"partial":')
        thread = json.dumps({'type': 'thread.started', 'thread_id': 'a'}) + '\n'
        self.assertEqual(budget.observe(thread), 15)
        self.assertEqual(budget.observe(thread), 15)
        terminal = json.dumps({'type': 'turn.completed', 'usage': {'input_tokens': 10, 'output_tokens': 5}})
        self.assertEqual(budget.observe(thread + terminal), 15)
        budget.finish_phase()
        budget.start_phase()
        record('a.jsonl', 25)
        self.assertEqual(budget.observe(thread + terminal), 30)
        budget.finish_phase()
        budget.start_phase()
        record('b.jsonl', 10)
        thread = json.dumps({'type': 'thread.started', 'thread_id': 'b'}) + '\n'
        self.assertEqual(budget.observe(thread + terminal), 45)

    def test_audit_includes_failed_commands_opaque_files_messages_and_review_identity(self):
        result, evidence, _ = self.trial()
        phase = evidence['phases'][-1]
        phase['commands'].append('unmatched shell attempt')
        phase['opaque'].append({'type': 'file_change', 'id': 'native-file'})
        phase['state']['files']['acme-mobile/new.txt'] = 'changed-hash'
        evidence['review'] = {'digest': evals.review_digest(evidence), 'reviewer': 'claude-coordinator',
                              'checks': ['tool-audit', 'policy-semantics'], 'citations': ['phase-0.jsonl']}
        evals.write_json(self.output / result['evidence'], evidence)
        evals.write_json(self.output / 'report.json', evals.aggregate([result], 'live'))
        audit = subprocess.run([sys.executable, '-B', str(ROOT / 'audit.py'), str(self.output)],
                               capture_output=True, text=True)
        self.assertEqual(audit.returncode, 0, audit.stderr)
        for expected in ['unmatched shell attempt', 'unmatched', 'file_change', 'new.txt', 'Exact command:',
                         'scripted-operator', 'claude-coordinator', evals.review_digest(evidence), result['evidence'],
                         'silta task start', 'exit=0', 'APPROVAL', evidence['approval']['words']]:
            self.assertIn(expected, audit.stdout)

    def test_invalid_unattended_options_reject_before_launch(self):
        base = ['evals.py', '--silta', str(BINARY), '--live', '--client', str(FAKE),
                '--model', 'fake', '--output', str(self.output / 'unused')]
        for flags in [['--harness', 'claude', '--provider', 'fireworks'],
                      ['--harness', 'both', '--operator', 'scripted'],
                      ['--harness', 'codex', '--max-trial-tokens', '0'],
                      ['--harness', 'codex', '--core', '--scenario', 'ask-short']]:
            with self.subTest(flags=flags), patch.object(sys, 'argv', base + flags):
                with patch.object(evals, 'run_trial', side_effect=AssertionError('Unexpected launch')):
                    with contextlib.redirect_stderr(self.console), self.assertRaises(SystemExit) as stopped:
                        evals.main()
                    self.assertEqual(stopped.exception.code, 2)
        self.assertNotIn(KEY, self.console.getvalue())

    def test_coordinator_review_labels_report_and_never_overrides_failure(self):
        result, evidence, _ = self.trial()
        self.assertFalse(result['checks']['evidence_review'])
        evals.write_json(self.output / 'report.json', evals.aggregate([result], 'live'))
        verdicts = {result['id']: {'digest': evals.review_digest(evidence), 'reviewer': 'claude-coordinator',
                                 'checks': ['tool-audit', 'policy-semantics'], 'citations': ['phase-0.jsonl']}}
        evals.write_json(self.output / 'verdicts.json', verdicts)
        report = json.loads((self.output / 'report.json').read_text())
        report.update(commit='fixture', dirty=False, binary_sha256='fixture')
        evals.write_json(self.output / 'report.json', report)
        applied = subprocess.run([sys.executable, '-B', str(ROOT / 'review.py'), str(self.output),
                                  str(self.output / 'verdicts.json')], capture_output=True, text=True)
        self.assertEqual(applied.returncode, 0, applied.stderr)
        self.assertIn('claude-coordinator', (self.output / 'report.html').read_text())
        report = json.loads((self.output / 'report.json').read_text())
        self.assertEqual(report['trials'][0]['reviewer'], 'claude-coordinator')
        evidence['phases'][0]['exit'] = 7
        evidence['review'] = dict(verdicts[result['id']], digest=evals.review_digest(evidence))
        self.assertFalse(evals.grade(evidence)['passed'])

    def test_sequential_matrix_retains_each_exit_and_uses_bounded_unattended_flags(self):
        matrix = importlib.import_module('open_matrix')
        seen = []
        def launch(argv, **kwargs):
            seen.append(argv)
            self.assertIn('--provider', argv)
            self.assertEqual(argv[argv.index('--provider') + 1], 'fireworks')
            self.assertEqual(argv[argv.index('--operator') + 1], 'scripted')
            self.assertEqual(argv[argv.index('--max-trial-tokens') + 1], '50')
            self.assertNotIn(KEY, str(argv))
            return subprocess.CompletedProcess(argv, 7 if len(seen) == 1 else 0)
        with patch.object(matrix.subprocess, 'run', side_effect=launch):
            self.assertEqual(matrix.main(['--silta', str(BINARY), '--client', str(FAKE), '--models', 'acme/a', 'acme/b',
                                         '--output', str(self.output / 'matrix'), '--max-trial-tokens', '50', '--core']), 1)
        manifest = json.loads((self.output / 'matrix/matrix.json').read_text())
        self.assertEqual([m['exit'] for m in manifest['models']], [7, 0])
        self.assertEqual(len(seen), 2)
        self.assertIn('--core', seen[0])


if __name__ == '__main__':
    unittest.main()
