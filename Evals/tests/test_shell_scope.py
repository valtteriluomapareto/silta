"""Exact option arity and attested path scope constrain read-only proof."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT), str(ROOT / 'tests')]
import evals
from shell_commands import parse_shell
from test_shell_review import phase, log


class ShellScope(unittest.TestCase):
    def test_39_optional_values_never_swallow_an_option(self):
        for command in ['git diff -U --output=out; silta brief',
                        'git log --pretty --output=out; silta brief',
                        'git show --pretty --ext-diff; silta brief',
                        'git diff -U HEAD; silta brief', 'git log --pretty HEAD; silta brief',
                        'git status --oneline; silta brief', 'ls --all=anything; silta brief',
                        'head --quiet=value README.md; silta brief']:
            self.assertTrue(parse_shell(command).opaque, command)
        for command in ['git diff -U3', 'git log --pretty=oneline', 'git log -n 5 --format=%H',
                        'git status --porcelain', 'git show --stat --oneline HEAD']:
            self.assertFalse(parse_shell(command).opaque, command)

    @staticmethod
    def scoped(command, cwd='/tmp/acme-eval/repos/acme-mobile'):
        p = phase({'A': command}, [('A', 'started'), ('A', 'completed')], [log('brief')])
        p['scope'] = {'repository': '/tmp/acme-eval/repos/acme-mobile',
                      'backends': ['/tmp/acme-eval/repos/acme-backend']}
        if cwd is not None:
            p['tool_results'][0]['cwd'] = cwd
        return p

    @staticmethod
    def evidence(p):
        return {'baseline': {'files': {}}, 'phases': [dict(p, state={'files': {}})]}

    def test_40_recursive_ancestor_reads_require_review(self):
        with tempfile.TemporaryDirectory(prefix='si66-scope-') as root:
            root = Path(root)
            mobile, backend = root / 'repos/acme-mobile', root / 'repos/acme-backend'
            mobile.mkdir(parents=True)
            backend.mkdir()
            (backend / 'README.md').write_text('SENTINEL\n')
            env = dict(os.environ, HOME=str(root), SILTA_HOME=str(root / 'data'), ZDOTDIR=str(root))
            observed = subprocess.run(['/usr/bin/grep', '-r', 'SENTINEL', '..'], cwd=mobile,
                                      env=env, capture_output=True, text=True, check=True)
            self.assertIn('acme-backend/README.md:SENTINEL', observed.stdout)
            p = self.scoped('grep -r SENTINEL ..; silta brief', str(mobile))
            p['scope'] = {'repository': str(mobile), 'backends': [str(backend)]}
            self.assertIsNone(evals.trace_matches_logs(p, 'codex'))
            self.assertEqual(evals.forbidden(self.evidence(p)), [])

    def test_40_resolved_scope_includes_implicit_recursive_inputs(self):
        for command in ['grep -r SENTINEL .; silta brief', 'rg SENTINEL; silta brief',
                        'rg --files; silta brief', 'ls; silta brief', 'git log -1; silta brief']:
            for cwd, expected in [('/tmp/acme-eval/repos/acme-mobile', True),
                                  ('/tmp/acme-eval', None),
                                  ('/tmp/acme-eval/foreign', None)]:
                p = self.scoped(command, cwd)
                self.assertIs(evals.trace_matches_logs(p, 'codex'), expected, (command, cwd))
            backend = self.scoped(command, '/tmp/acme-eval/repos/acme-backend')
            self.assertTrue(evals.forbidden(self.evidence(backend)), command)
        for command in ['cat ../acme-backend/README.md; silta brief',
                        'git -C .. -C acme-backend log -1; silta brief',
                        'grep -f ../acme-backend/patterns README.md; silta brief']:
            self.assertTrue(evals.forbidden(self.evidence(self.scoped(command))), command)
        normalized = self.scoped('cat ../acme-backend/../acme-mobile/README.md; silta brief')
        self.assertEqual(evals.forbidden(self.evidence(normalized)), [])
        self.assertIs(evals.trace_matches_logs(normalized, 'codex'), True)

    def test_40_missing_native_cwd_is_not_the_launch_directory(self):
        p = self.scoped('rg SENTINEL; silta brief', None)
        p['scope']['launch_cwd'] = '/tmp/acme-eval/repos/acme-mobile'
        self.assertIsNone(evals.trace_matches_logs(p, 'codex'))
        self.assertIs(evals.trace_matches_logs(self.scoped('cat; silta brief', None), 'codex'), True)
        for command in ['which silta; silta brief', 'find . -print; silta brief',
                        'sort README.md; silta brief', 'ls 2>/dev/null; silta brief']:
            self.assertIsNone(evals.trace_matches_logs(self.scoped(command), 'codex'))

    def test_40_native_cwd_is_retained_without_guessing(self):
        events = [{'type': 'thread.started', 'thread_id': 'acme'},
                  {'type': 'item.started', 'item': {'id': 'A', 'type': 'command_execution',
                   'command': 'rg SENTINEL', 'cwd': '/tmp/acme-eval/repos/acme-mobile'}},
                  {'type': 'item.completed', 'item': {'id': 'A', 'type': 'command_execution',
                   'command': 'rg SENTINEL', 'cwd': '/tmp/acme-eval/repos/acme-mobile',
                   'exit_code': 0, 'aggregated_output': ''}},
                  {'type': 'turn.completed', 'usage': {}}]
        result = evals.parse_stream('codex', '\n'.join(map(json.dumps, events)))
        self.assertEqual(result['tool_results'][0].get('cwd'), '/tmp/acme-eval/repos/acme-mobile')
