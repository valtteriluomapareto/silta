"""Actual-CLI adversarial replays; only the repository stub is a harness client."""
import contextlib
import io
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import evals

BINARY = ROOT.parent / '.build/debug/silta'
STUB = ROOT / 'tests/stub_harness.py'


class ReviewReplays(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='silta-review-replays-')
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def trial(self, harness, scenario, recording, variant='default'):
        output = self.root / (harness + '-' + recording)
        output.mkdir()
        result = evals.run_trial(BINARY, harness, 'recorded-stub', scenario, variant,
                                1, STUB, output, stub=True, recording=recording)
        evidence = json.loads((output / result['evidence']).read_text())
        return result, evidence

    def test_forged_backend_stdout_replay_fails_both_adapters(self):
        for harness in ['claude', 'codex']:
            with self.subTest(harness=harness):
                result, evidence = self.trial(harness, 'start-cross-repo', 'forged-backend')
                self.assertEqual(evidence['phases'][0]['exit'], 0)
                self.assertTrue(result['checks']['stream_complete'])
                self.assertTrue(any(log['exit_code'] == 2 for log in evidence['phases'][0]['logs']))
                self.assertFalse(result['checks']['backend_read'])
                self.assertFalse(result['passed'])

    def test_approval_does_not_hide_unrelated_steal_replay(self):
        for harness in ['claude', 'codex']:
            with self.subTest(harness=harness):
                result, evidence = self.trial(harness, 'proposals-ask', 'hidden-steal', 'present-add')
                self.assertTrue(result['checks']['stream_complete'])
                self.assertTrue(result['checks']['approval_provenance'])
                self.assertEqual(evidence['phases'][1]['exit'], 0)
                self.assertFalse(result['checks']['no_forbidden'])
                self.assertGreater(result['metrics']['forbidden_attempts'], 0)
                self.assertFalse(result['passed'])

    def test_missing_tool_completions_replay_fails_both_adapters(self):
        for harness in ['claude', 'codex']:
            with self.subTest(harness=harness):
                result, evidence = self.trial(harness, 'done-with-result', 'missing-tools')
                self.assertEqual(evidence['phases'][0]['exit'], 0)
                self.assertTrue(result['checks']['result_template'])
                self.assertTrue(result['checks']['result_sha'])
                self.assertTrue(evidence['phases'][0]['commands'])
                self.assertEqual(evidence['phases'][0]['tool_results'], [])
                self.assertFalse(result['checks']['stream_complete'])
                self.assertFalse(result['passed'])

    def test_handoff_b_starts_a_fresh_native_conversation(self):
        for harness in ['claude', 'codex']:
            with self.subTest(harness=harness):
                result, evidence = self.trial(harness, 'handoff-resume', 'pass')
                self.assertNotEqual(evidence['phases'][0]['conversation'],
                                    evidence['phases'][1]['conversation'])
                self.assertTrue(result['passed'])

    def test_nonzero_child_exit_survives_successful_terminal(self):
        for harness in ['claude', 'codex']:
            with self.subTest(harness=harness):
                result, evidence = self.trial(harness, 'done-with-result', 'nonzero')
                self.assertTrue(evidence['phases'][0]['complete'])
                self.assertEqual(evidence['phases'][0]['exit'], 7)
                self.assertTrue(result['checks']['result_sha'])
                self.assertFalse(result['checks']['stream_complete'])
                self.assertFalse(result['passed'])

    def test_printed_and_persisted_profile_launcher_enters_fixture(self):
        ordinary = self.root / 'ordinary project'
        ordinary.mkdir()
        (ordinary / 'CLAUDE.md').write_text('Unrelated project instructions\n')
        client = self.root / 'fake client.py'
        client.write_text('#!/usr/bin/env python3\nimport json, os, sys\nfrom pathlib import Path\n'
                          "print(json.dumps({'cwd':os.getcwd(),'home':os.environ['HOME'],"
                          "'config':os.environ['CLAUDE_CONFIG_DIR'],'args':sys.argv[1:],"
                          "'ordinary':Path('CLAUDE.md').exists()}))\n")
        client.chmod(0o755)
        actual_execute = evals.execute

        def execute(argv, env, cwd, timeout, stdin=None):
            if Path(argv[0]).parent == ROOT / 'harnesses':
                return {'exit': 0, 'stdout': '\n'.join(map(json.dumps, [
                    {'type':'system','session_id':'fake'}, {'type':'result','is_error':False}])), 'stderr':''}
            return actual_execute(argv, env, cwd, timeout, stdin)

        output = self.root / 'launcher-output'
        capture = io.StringIO()
        with patch.object(evals, 'execute', side_effect=execute), patch('builtins.input', return_value='signed-in'), contextlib.redirect_stdout(capture):
            result = evals.run_trial(BINARY, 'claude', 'fake-client', 'plan-not-file',
                                    'default', 1, client, output, stub=False)
        profile = Path((output / result['id'] / 'profile-location.txt').read_text().strip())
        self.addCleanup(shutil.rmtree, profile)
        command = capture.getvalue().split('Sign in afresh in another terminal:\n', 1)[1].splitlines()[0]
        run = subprocess.run(['/bin/zsh', '-c', command], cwd=ordinary, capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        observed = json.loads(run.stdout)
        self.assertEqual(Path(observed['cwd']), profile / 'repos/acme-mobile')
        self.assertFalse(observed['ordinary'])
        self.assertEqual(Path(observed['config']), profile / 'home/.claude')
        launcher = profile / 'profile-launcher.sh'
        self.assertTrue(launcher.is_file())
        logout = subprocess.run([str(launcher), 'logout'], cwd=ordinary, capture_output=True, text=True)
        self.assertEqual(logout.returncode, 0, logout.stderr)
        self.assertEqual(json.loads(logout.stdout)['args'], ['logout'])
        self.assertEqual(Path(json.loads(logout.stdout)['cwd']), profile / 'repos/acme-mobile')

    def test_documented_model_prompts_run_under_zsh(self):
        text = (ROOT.parent / 'docs/dogfood/agent-evals.md').read_text()
        start = text.index('# Set the exact model names')
        end = text.index('Evals/run.sh --silta', start)
        snippet = text[start:end] + '\nprintf "MODELS=%s,%s\\n" "$eval_claude_model" "$eval_codex_model"\n'
        run = subprocess.run(['/bin/zsh', '-eu', '-c', snippet], input='acme-claude\nacme-codex\n',
                             text=True, capture_output=True, cwd=self.root)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn('MODELS=acme-claude,acme-codex', run.stdout)


if __name__ == '__main__':
    unittest.main()


class NativeLifecycle(unittest.TestCase):
    @staticmethod
    def events(harness):
        if harness == 'codex':
            return [
                {'type':'thread.started','thread_id':'acme-thread'},
                {'type':'item.started','item':{'type':'command_execution','id':'tool-1','command':'silta brief'}},
                {'type':'item.completed','item':{'type':'command_execution','id':'tool-1','command':'silta brief','exit_code':0,'aggregated_output':''}},
                {'type':'turn.completed','usage':{}},
            ]
        return [
            {'type':'system','session_id':'acme-thread'},
            {'type':'assistant','message':{'content':[{'type':'tool_use','id':'tool-1','name':'Bash','input':{'command':'silta brief'}}]}},
            {'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':'tool-1','content':'','is_error':False}]}},
            {'type':'result','is_error':False},
        ]

    def test_tool_lifecycle_rejects_missing_or_mismatched_native_evidence(self):
        import copy
        for harness in ['claude','codex']:
            base = self.events(harness)
            parsed = evals.parse_stream(harness, '\n'.join(map(json.dumps, base)))
            self.assertTrue(parsed['complete'])
            cases = {'missing-result':base[:2]+base[3:], 'orphan-result':[base[0],*base[2:]],
                     'duplicate-result':base[:3]+base[2:], 'duplicate-start':base[:2]+base[1:],
                     'missing-terminal':base[:3], 'duplicate-terminal':base+[base[-1]],
                     'terminal-before-result':base[:2]+[base[-1],base[2]],
                     'activity-after-terminal':base+[base[1]]}
            changed = copy.deepcopy(base)
            if harness == 'codex':
                changed[2]['item']['command']='silta task ls'
                cases['changed-command']=changed
                changed=copy.deepcopy(base);changed[2]['item']['exit_code']=None
                cases['missing-exit']=changed
                changed=copy.deepcopy(base);changed[2]['item']['id']='tool-unknown'
            else:
                changed[2]['message']['content'][0]['tool_use_id']='tool-unknown'
            cases['wrong-id']=changed
            for name, events in cases.items():
                with self.subTest(harness=harness, case=name):
                    parsed = evals.parse_stream(harness,'\n'.join(map(json.dumps,events)))
                    self.assertFalse(parsed['complete'])
                    if name != 'orphan-result':
                        self.assertIn('silta brief', parsed['commands'])
