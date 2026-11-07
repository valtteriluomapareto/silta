"""Conservative shell evidence: literal calls, uncertainty and proof boundaries."""
import copy
import json
from pathlib import Path
import shlex
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import evals
from shell_commands import parse_shell


class ShellCommands(unittest.TestCase):
    def test_compounds_preserve_quotes_and_invocation_order(self):
        for separator in [';', '&&', '||', '|', '\n']:
            command = "silta where " + separator + " echo 'semi; && || | literal' ; silta brief\n"
            for rendered in [command, '/bin/zsh -lc ' + shlex.quote(command)]:
                with self.subTest(command=rendered):
                    parsed = parse_shell(rendered)
                    self.assertFalse(parsed.opaque)
                    self.assertEqual(parsed.invocations, [['silta', 'where'], ['silta', 'brief']])
        parsed = parse_shell("silta comment AC-1 -m '$(literal) `text`; |'\nsilta brief # ignored\n")
        self.assertFalse(parsed.opaque)
        self.assertEqual(parsed.invocations[0][-1], '$(literal) `text`; |')
        self.assertEqual(parsed.invocations[-1], ['silta', 'brief'])

    def test_one_quoted_heredoc_is_literal_stdin_not_shell_or_gate_flags(self):
        for quote in ["'", '"']:
            body = "silta where; --steal $(substitution) `text`\n"
            command = f'silta task plan AC-1 -F - <<{quote}END{quote}\n{body}END\nsilta brief'
            parsed = parse_shell(command)
            self.assertFalse(parsed.opaque)
            self.assertEqual(parsed.invocations, [['silta', 'task', 'plan', 'AC-1', '-F', '-'], ['silta', 'brief']])

    def test_unsupported_forms_are_opaque_and_never_raise(self):
        commands = ['silta brief $(echo x)', 'silta brief `echo x`',
                    'silta brief <(echo x)', 'silta brief >(cat)', 'eval "silta brief"',
                    'cat input | silta task plan AC-1 -F -', 'silta task plan AC-1 -F - < input',
                    "silta brief 'unbalanced", 'silta brief "unbalanced',
                    'silta task plan AC-1 -F - <<END\ntext\nEND',
                    'silta task plan AC-1 -F - <<< "text"',
                    "silta task plan AC-1 -F - <<'END'\ntext", "f() { silta brief; }; f",
                    'function f { silta brief; }; f', "alias s='silta brief'; s", 'unalias silta',
                    "silta brief <<'END'\ntext\nEND", 'silta brief $COMMAND',
                    'silta brief &', 'silta where &&', 'silta where ||', 'silta where |',
                    'silta where ;; silta brief', 'silta brief \\', None,
                    "silta task plan AC-1 -F - <<'A'\nx\nA\nsilta task plan AC-1 -F - <<'B'\ny\nB"]
        for command in commands:
            with self.subTest(command=command):
                self.assertTrue(parse_shell(command).opaque)
                self.assertFalse(evals.literal_argv(command))
                self.assertFalse(evals.shell_argv(command))

    @staticmethod
    def phase(command, logs, code=0):
        return {'tool_results': [{'command': command, 'exit': code}],
                'logs': [{'command': name, 'exit_code': status} for name, status in logs]}

    def test_compound_exit_does_not_claim_each_segment_status(self):
        phase = self.phase('silta where; echo ---; silta brief', [('silta where', 2), ('silta brief', 0)])
        self.assertIs(evals.trace_matches_logs(phase, 'codex'), True)
        phase['tool_results'][0]['command'] = 'silta where'
        phase['logs'] = phase['logs'][:1]
        self.assertIs(evals.trace_matches_logs(phase, 'codex'), False)
        phase = self.phase('silta where 2>&1 | head', [('silta where', 2)])
        self.assertIs(evals.trace_matches_logs(phase, 'codex'), True)

    def test_conditional_and_opaque_calls_need_review_not_pass_or_exception(self):
        for command, logs in [('silta where && silta brief', [('silta where', 2)]),
                              ('silta where || silta brief', [('silta where', 0)]),
                              ('silta brief $(echo x)', [('silta brief', 0)]),
                              ("find '/unbalanced", [])]:
            phase = self.phase(command, logs)
            self.assertIsNone(evals.trace_matches_logs(phase, 'codex'))

    def test_opaque_call_does_not_erase_known_mismatches_or_reordering(self):
        phase = self.phase('silta where; silta brief', [('silta brief', 0), ('silta where', 0)])
        phase['tool_results'].append({'command': "echo 'unbalanced", 'exit': 1})
        self.assertIs(evals.trace_matches_logs(phase, 'codex'), False)
        phase = self.phase('silta brief', [('silta brief', 2)])
        phase['tool_results'].append({'command': 'eval unknown', 'exit': 0})
        self.assertIs(evals.trace_matches_logs(phase, 'codex'), False)

    def test_bound_general_review_cannot_certify_unknown_shell_effects(self):
        folder = ROOT / 'tests/pilot/400k/codex-done-with-result-default-1'
        e = json.loads((folder / 'evidence.json').read_text())
        e['phases'][0].update(evals.parse_stream('codex', (folder / 'phase-0.jsonl').read_text()))
        e['phases'][0]['tool_results'].append({'command': "find '/bad", 'exit': 1})
        e['phases'][0]['commands'].append("find '/bad")
        self.assertIsNone(evals.grade(e)['checks']['stream_complete'])
        e['review'] = {'reviewer': 'fixture-reviewer', 'checks': ['tool-audit'], 'digest': evals.review_digest(e)}
        self.assertIsNone(evals.grade(e)['checks']['stream_complete'])
        e['review']['checks'].append('shell-trace')
        self.assertTrue(evals.grade(e)['checks']['stream_complete'])
        e['phases'][0]['tool_results'].pop(6)  # Missing the real task-start pair.
        e['review']['digest'] = evals.review_digest(e)
        self.assertFalse(evals.grade(e)['checks']['stream_complete'])

    def test_malformed_approval_audit_cannot_crash(self):
        self.assertEqual(parse_shell("silta task add 'broken -> AC-2").single(), [])
        self.assertIsNone(evals.invocation("silta task add 'broken"))
        e = {'baseline': {'tasks': []}, 'variant': 'present-add',
             'phases': [{}, {'actor': 'agent:acme', 'state': {'tasks': [{'seq': 2}]}}]}
        row = {'actor': 'agent:acme', 'workspace': 'acme', 'command': "silta task add 'broken"}
        self.assertFalse(evals.approval_audit(e, row))
        row['command'] = 'silta task add --app none -> AC-2'
        self.assertTrue(evals.approval_audit(e, row))

    def test_native_diagnostic_is_retained_without_fabricating_a_tool(self):
        base = [{'type': 'thread.started', 'thread_id': 'acme'},
                {'type': 'item.completed', 'item': {'id': 'diag', 'type': 'error', 'message': 'Model metadata unavailable'}},
                {'type': 'turn.completed', 'usage': {}}]
        parsed = evals.parse_stream('codex', '\n'.join(map(json.dumps, base)))
        self.assertTrue(parsed['complete'])
        self.assertEqual(parsed['opaque'], [base[1]['item']])
        self.assertEqual(parsed['tool_results'], [])
        for event in [{'type': 'error', 'message': 'transport failed'},
                      {'type': 'turn.failed'},
                      {'type': 'item.completed', 'item': {'id': 'unknown', 'type': 'unknown_tool'}},
                      {'type': 'item.completed', 'item': {'id': 'bad', 'type': 'error', 'message': 42}}]:
            with self.subTest(event=event):
                changed = [base[0], event, base[-1]]
                self.assertFalse(evals.parse_stream('codex', '\n'.join(map(json.dumps, changed)))['complete'])

    def test_partial_token_sum_counts_unknown_trials(self):
        folder = ROOT / 'tests/pilot/400k/codex-done-with-result-default-1'
        e = json.loads((folder / 'evidence.json').read_text())
        trial = dict(evals.grade(e), harness='codex', model='acme', scenario=e['scenario'], repeat=1)
        known = copy.deepcopy(trial)
        known['metrics']['tokens'] = 123
        trial['metrics']['tokens'] = None
        report = evals.aggregate([known, trial], 'live')
        self.assertEqual(report['tokens'], 123)
        self.assertEqual(report['unknown_token_trials'], 1)
        self.assertEqual(evals.aggregate([trial], 'live')['tokens'], 0)
        self.assertEqual(evals.aggregate([], 'live')['unknown_token_trials'], 0)


if __name__ == '__main__':
    unittest.main()
