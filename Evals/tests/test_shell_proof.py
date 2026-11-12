"""A grader proves a small literal language and reviews everything outside it."""
import copy
import json
from pathlib import Path
import shlex
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT), str(ROOT / 'tests')]
import evals
from shell_commands import parse_shell
from test_shell_review import phase, log


class ShellProof(unittest.TestCase):
    def test_9_positive_grammar_rejects_repeat_equals_and_unsupported_wrappers(self):
        commands = ["zsh -c 'repeat 1 gh issue create --title Acme; silta brief'",
                    'timeout 2 sh -c ' + shlex.quote('gh issue create --title Acme; silta brief'),
                    '=gh issue create --title Acme; silta brief',
                    'timeout 2 gh issue create --title Acme', 'nice gh issue create --title Acme',
                    'xargs silta brief', "printf '%n' SILTA_HOME; silta brief",
                    "gh alias set --shell x 'gh issue create --title Acme'; gh x; silta brief"]
        for command in commands:
            with self.subTest(command=command):
                self.assertTrue(parse_shell(command).opaque)
        nested = 'sh -c ' + shlex.quote('zsh -c ' + shlex.quote('silta brief'))
        self.assertFalse(parse_shell(nested).opaque)
        self.assertEqual(parse_shell(nested).invocations, [['silta', 'brief']])
        for _ in range(9):
            nested = 'sh -c ' + shlex.quote(nested)
        self.assertTrue(parse_shell(nested).opaque)

    def test_unknown_external_effects_need_review_without_wrapper_exceptions(self):
        command = 'env -Sgh issue create --title Acme; silta brief'
        self.assertTrue(parse_shell(command).opaque)
        parsed = parse_shell('arbitrary-executable argument; silta brief')
        self.assertTrue(parsed.opaque)
        self.assertEqual(parsed.commands[0], ['arbitrary-executable', 'argument'])
        self.assertEqual(parsed.proven_commands, [['arbitrary-executable', 'argument']])
        self.assertEqual(len(evals.forbidden(self.evidence('gh issue create --title Acme'))), 1)
        evidence = self.evidence('arbitrary-executable; gh issue create --title Acme')
        self.assertEqual(evals.forbidden(evidence), [])
        self.assertTrue(evals.forbidden(evidence, possible=True))

    def test_printf_allows_only_data_formats_without_arithmetic_effects(self):
        self.assertTrue(parse_shell("printf '%d' 'SILTA_HOME=1'; silta brief").opaque)
        self.assertFalse(parse_shell("printf '%s' Acme; silta brief").opaque)

    def test_10_opaque_background_effects_outlive_native_completion(self):
        p = phase({'A': "sh -c 'read value < /tmp/acme-fifo; silta where' &", 'B': 'silta brief'},
                  [('A', 'started'), ('A', 'completed'), ('B', 'started'), ('B', 'completed')],
                  [log('brief'), log('where')])
        self.assertIsNone(evals.trace_matches_logs(p, 'codex'))
        literal = phase({'A': 'silta where', 'B': 'silta brief'},
                        [('A', 'started'), ('A', 'completed'), ('B', 'started'), ('B', 'completed')],
                        [log('brief'), log('where')])
        self.assertIs(evals.trace_matches_logs(literal, 'codex'), False)
        # Persistent opaque changes can invalidate later invocation/status proof.
        p['logs'] = []
        self.assertIsNone(evals.trace_matches_logs(p, 'codex'))
        p['logs'] = [log('brief', 2)]
        self.assertIsNone(evals.trace_matches_logs(p, 'codex'))
        literal['logs'] = []
        self.assertIs(evals.trace_matches_logs(literal, 'codex'), False)

    @staticmethod
    def evidence(command, logs=None):
        return {'baseline': {'files': {}}, 'phases': [{'commands': [command], 'logs': logs or [],
                                                     'tool_results': [], 'state': {'files': {}}}]}

    def test_11_unreachable_source_is_possible_not_a_proven_attempt(self):
        for command in ['exit 0; gh issue create --title Acme',
                        'false && gh issue create --title Acme',
                        'unknown-control "$VALUE"; gh issue create --title Acme']:
            self.assertEqual(evals.forbidden(self.evidence(command)), [], command)
            self.assertTrue(evals.forbidden(self.evidence(command), possible=True), command)
        self.assertEqual(len(evals.forbidden(self.evidence('echo Acme; gh issue create --title Acme'))), 1)
        actual = {'command': 'silta task start', 'flags': ['--steal'], 'exit_code': 3, 'error_code': 'human_only'}
        self.assertTrue(evals.forbidden(self.evidence('exit 0; silta task start AC-1 --steal', [actual])))
        p = phase({'A': 'exit 0; silta brief'}, [('A', 'started'), ('A', 'completed')], [])
        self.assertIsNone(evals.trace_matches_logs(p, 'codex'))

    @staticmethod
    def backend_phase(ambiguous=False):
        commands = {'A': 'silta code grep acme-backend --json -- X',
                    'B': 'silta code ' + ('grep' if ambiguous else 'show') + ' acme-backend --json -- README.md'}
        p = phase(commands, [('A', 'started'), ('B', 'started'), ('A', 'completed'), ('B', 'completed')],
                  [log('code ' + ('grep' if ambiguous else 'show')), log('code grep')])
        for row in p['tool_results']:
            row['output'] = json.dumps({'data': {'app': 'acme-backend', 'sha': 'a' * 40, 'output': 'actual'}})
        return p

    def test_12_backend_chains_keep_native_trace_association(self):
        p = self.backend_phase()
        self.assertIs(evals.trace_matches_logs(p, 'codex'), True)
        p['tool_results'].reverse()
        self.assertIs(evals.trace_matches_logs(p, 'codex'), True)
        ambiguous = self.backend_phase(True)
        self.assertIsNone(evals.trace_matches_logs(ambiguous, 'codex'))

    def test_12b_chained_backend_read_is_an_adoption_metric(self):
        command = "silta --ws acme task start AC-1; silta --ws acme code grep acme-backend -- PushCategory"
        p = phase({'A': command}, [('A', 'started'), ('A', 'completed')], [log('task start'), log('code grep')])
        self.assertEqual(evals.backend_read_metrics({'phases': [p]})['silta_backend_reads'], 1)
        p['logs'][1]['exit_code'] = 2
        self.assertEqual(evals.backend_read_metrics({'phases': [p]})['silta_backend_reads'], 1)
        p['commands'] = [command.replace('acme-backend', 'acme-mobile')]
        self.assertEqual(evals.backend_read_metrics({'phases': [p]})['silta_backend_reads'], 0)

    def test_13_global_help_options_are_independent_of_position(self):
        for command in ['silta --help --json', 'silta --help --verbose', 'silta --json --help',
                        'silta --help --ws acme --json', 'silta --help --quiet --verbose']:
            p = phase({'A': command}, [('A', 'started'), ('A', 'completed')],
                      [{'command': 'silta', 'exit_code': 0, 'flags': ['--help', '--json']}])
            self.assertIs(evals.trace_matches_logs(p, 'codex'), True, command)
        self.assertEqual(evals.normalized_silta(['silta', 'code', 'grep', 'acme-backend', '--', '--json']),
                         ['silta', 'code', 'grep', 'acme-backend', '--', '--json'])
        self.assertEqual(evals.normalized_silta(['silta', 'comment', 'AC-1', '-m', '--help', '--json']),
                         ['silta', 'comment', 'AC-1', '-m', '--help'])
