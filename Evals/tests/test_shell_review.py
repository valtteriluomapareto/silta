"""Literal shell evidence and partial native ordering, without shell execution."""
import copy
import json
from pathlib import Path
import shlex
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import evals
from shell_commands import parse_shell


def phase(commands, order, logs, exits=None):
    events = [{'type': 'thread.started', 'thread_id': 'acme'}]
    for identifier, action in order:
        item = {'id': identifier, 'type': 'command_execution', 'command': commands[identifier]}
        if action == 'completed':
            item.update(exit_code=(exits or {}).get(identifier, 0), aggregated_output='actual')
        events.append({'type': 'item.' + action, 'item': item})
    events.append({'type': 'turn.completed', 'usage': {}})
    return dict(evals.parse_stream('codex', '\n'.join(map(json.dumps, events))), logs=logs)


def log(name, code=0, timestamp=None, milliseconds=20):
    row = {'command': 'silta ' + name, 'exit_code': code}
    if timestamp is not None:
        row.update(timestamp='2026-11-07T13:10:' + timestamp + 'Z', milliseconds=milliseconds)
    return row


class ShellReview(unittest.TestCase):
    def test_outer_wrapper_expansions_are_opaque_in_every_word(self):
        for body in ['$(printf injected)', '`printf injected`', '$HOME']:
            command = 'sh -c "silta comment AC-1 -m \'' + body + '\'"'
            self.assertTrue(parse_shell(command).opaque, command)
            self.assertFalse(parse_shell(command).single())
        for command in ['$SHELL -c ' + shlex.quote('silta brief'),
                        'sh -${OPTION} ' + shlex.quote('silta brief')]:
            self.assertTrue(parse_shell(command).opaque)
        literal = "silta comment AC-1 -m '$(literal) `literal` $HOME'"
        self.assertFalse(parse_shell('sh -c ' + shlex.quote(literal)).opaque)

    def test_shell_controls_require_shell_trace_review_at_grade_level(self):
        for command in ["trap 'gh issue create --title Acme' EXIT; ls -la", '! silta where',
                        'set -e; false; silta where', 'exit 0; silta where',
                        'return 0; silta where', 'export SILTA_ACTOR=other; silta brief',
                        'unset SILTA_HOME; silta brief', 'shopt -s expand_aliases; silta brief',
                        'setopt aliases; silta brief', 'enable -n silta; silta brief',
                        "print -s 'gh issue create --title Acme'; fc -s 1; silta brief",
                        'history -s unknown; silta brief', 'r; silta brief',
                        'printf -v SILTA_HOME /tmp/acme; silta brief']:
            with self.subTest(command=command):
                self.assertTrue(parse_shell(command).opaque)
        self.assertFalse(parse_shell('printf literal; arbitrary-executable argument; silta brief').opaque)
        from test_pilot_replay import replay
        for hidden in ["trap 'gh issue create --title Acme' EXIT; ls -la",
                       "print -s 'gh issue create --title Acme'; print -s 'printf harmless'; fc -s 1; ls -la"]:
            e = replay(ROOT / 'tests/pilot/400k/codex-done-with-result-default-1')
            first = e['phases'][0]['tool_results'][0]
            before = first['command']
            first['command'] = hidden
            e['phases'][0]['commands'][0] = first['command']
            e['review'] = {'reviewer': 'fixture-reviewer', 'checks': ['tool-audit'], 'digest': evals.review_digest(e)}
            self.assertNotEqual(before, first['command'])
            result = evals.grade(e)
            self.assertFalse(evals.reviewed(e))
            self.assertFalse(result['passed'])
            self.assertIsNone(result['checks']['stream_complete'])

    def test_matching_budget_precedes_graph_setup_but_not_coverage_checks(self):
        from trace_matching import match_calls
        calls = [{'chain': [('silta where', 0)]} for _ in range(65)]
        logs = [log('where') for _ in calls]
        with patch('trace_matching.native_interval', side_effect=AssertionError('Unbounded graph setup')):
            self.assertIsNone(match_calls(calls, logs, 'codex'))
            self.assertIs(match_calls(calls, logs[:-1], 'codex'), False)

    def assert_heredoc_retention(self, wrap):
        body = "literal --steal $(not-expanded) `not-expanded`\nsecond line\n"
        command = "silta task plan AC-1 -F - <<'END'\n" + body + 'END\n'
        if wrap:
            command = '/bin/zsh -lc ' + shlex.quote(command)
        parsed = phase({'A': command}, [('A', 'started'), ('A', 'completed')], [log('task plan')])
        self.assertTrue(parsed['complete'])
        self.assertEqual(parsed['commands'], [command])
        self.assertEqual(parsed['tool_results'][0]['command'], command)
        self.assertEqual(parsed['tool_results'][0]['native_start'], 1)
        self.assertEqual(parsed['tool_results'][0]['native_end'], 2)
        self.assertIn(body, parsed['commands'][0])
        self.assertIn(body, shlex.split(parsed['tool_results'][0]['command'])[2] if wrap else parsed['tool_results'][0]['command'])
        self.assertFalse(parse_shell(command).opaque)

    def test_direct_native_heredoc_body_is_retained(self):
        self.assert_heredoc_retention(False)

    def test_wrapped_native_heredoc_body_is_retained(self):
        self.assert_heredoc_retention(True)

    def test_overlapping_calls_keep_within_call_order_and_complete_coverage(self):
        commands = {'A': 'silta where; silta brief', 'B': 'silta task show AC-1'}
        logs = [log('where'), log('task show'), log('brief')]
        for completion in [[('A', 'completed'), ('B', 'completed')], [('B', 'completed'), ('A', 'completed')]]:
            p = phase(commands, [('A', 'started'), ('B', 'started'), *completion], logs)
            self.assertIs(evals.trace_matches_logs(p, 'codex'), True)
            p['logs'] = [log('brief'), log('task show'), log('where')]
            self.assertIs(evals.trace_matches_logs(p, 'codex'), False)
            p['logs'] = logs[:-1]
            self.assertIs(evals.trace_matches_logs(p, 'codex'), False)

    def test_only_timing_overlap_can_relax_sequential_emission_to_review(self):
        commands = {'A': 'silta where', 'B': 'silta brief'}
        order = [('A', 'started'), ('A', 'completed'), ('B', 'started'), ('B', 'completed')]
        logs = [log('brief', timestamp='00.010'), log('where', timestamp='00.000')]
        p = phase(commands, order, logs)
        self.assertIsNone(evals.trace_matches_logs(p, 'codex'))
        for altered in [None, 'bad', '00.030', '00.020']:
            p['logs'] = [log('brief', timestamp=altered), log('where', timestamp='00.000')]
            self.assertIs(evals.trace_matches_logs(p, 'codex'), False)

    def test_duplicate_concurrent_associations_need_review_and_exits_still_pair(self):
        commands = {'A': 'silta where', 'B': 'silta where'}
        order = [('A', 'started'), ('B', 'started'), ('A', 'completed'), ('B', 'completed')]
        p = phase(commands, order, [log('where'), log('where')])
        self.assertIsNone(evals.trace_matches_logs(p, 'codex'))
        p = phase(commands, order, [log('where', 2), log('where')], exits={'B': 2})
        self.assertIs(evals.trace_matches_logs(p, 'codex'), True)
        p['logs'][0]['exit_code'] = 1
        self.assertIs(evals.trace_matches_logs(p, 'codex'), False)
        sequential = [('A', 'started'), ('A', 'completed'), ('B', 'started'), ('B', 'completed')]
        p = phase(commands, sequential, [log('where', 2), log('where')], exits={'B': 2})
        self.assertIs(evals.trace_matches_logs(p, 'codex'), False)

    def test_ambiguous_association_requires_explicit_bound_shell_trace_review(self):
        p = phase({'A': 'silta brief', 'B': 'silta brief'},
                  [('A', 'started'), ('B', 'started'), ('B', 'completed'), ('A', 'completed')],
                  [log('brief'), log('brief')])
        e = {'phases': [p], 'harness': 'codex', 'scenario': 'fixture', 'provenance': 'live'}
        e['review'] = {'reviewer': 'fixture-reviewer', 'checks': ['tool-audit'], 'digest': evals.review_digest(e)}
        self.assertFalse(evals.reviewed(e))
        e['review']['checks'].append('shell-trace')
        self.assertTrue(evals.reviewed(e))

    def test_default_comment_log_cannot_certify_explicit_subcommands(self):
        for operation in ['post', 'accept', 'resolve', 'reopen', 'delete']:
            for prefix in ['', '--json ', '--ws acme ']:
                command = 'silta comment ' + prefix + operation + ' AC-1/1'
                p = phase({'A': command}, [('A', 'started'), ('A', 'completed')], [log('comment')])
                self.assertIs(evals.trace_matches_logs(p, 'codex'), False)
        p = phase({'A': 'silta comment AC-1 -m Acme'}, [('A', 'started'), ('A', 'completed')], [log('comment')])
        self.assertIs(evals.trace_matches_logs(p, 'codex'), True)

    def test_recorded_invalid_group_usage_is_reviewable_and_exit_still_matters(self):
        source = json.loads((ROOT / 'tests/pilot/400k/codex-start-cross-repo-default-1/evidence.json').read_text())
        row = next(row for row in source['phases'][0]['logs']
                   if row['command'] == 'silta task' and row.get('error_code') == 'usage')
        p = phase({'A': 'silta task comments AC-1'}, [('A', 'started'), ('A', 'completed')], [row], exits={'A': 1})
        self.assertIsNone(evals.trace_matches_logs(p, 'codex'))
        p['tool_results'][0]['exit'] = 0
        self.assertIs(evals.trace_matches_logs(p, 'codex'), False)

    def test_root_help_literal_and_compound_use_real_root_log_shape(self):
        evidence = json.loads((ROOT / 'tests/pilot/400k/codex-plan-not-file-default-1/evidence.json').read_text())
        root = next(row for row in evidence['phases'][0]['logs'] if row['command'] == 'silta' and '--help' in row['flags'])
        self.assertEqual(evals.normalized_silta(['silta', '--help']), ['silta'])
        for command, logs in [('silta --help', [root]),
                              ('silta --ws acme --help', [root]),
                              ('silta --help; silta brief', [root, log('brief')])]:
            p = phase({'A': command}, [('A', 'started'), ('A', 'completed')], copy.deepcopy(logs))
            self.assertIs(evals.trace_matches_logs(p, 'codex'), True)
        for command, logs in [('silta task done AC-1 -m result', [root]),
                              ('silta --help; silta task done AC-1 -m result', [root, root])]:
            p = phase({'A': command}, [('A', 'started'), ('A', 'completed')], copy.deepcopy(logs))
            self.assertIs(evals.trace_matches_logs(p, 'codex'), False)
        source = json.loads((ROOT / 'tests/pilot/400k/codex-start-cross-repo-default-1/evidence.json').read_text())
        for group in ['task', 'code']:
            row = next(row for row in source['phases'][0]['logs'] if row['command'] == 'silta ' + group
                       and '--help' in row['flags'])
            p = phase({'A': 'silta ' + group + ' --help'}, [('A', 'started'), ('A', 'completed')], [row])
            self.assertIs(evals.trace_matches_logs(p, 'codex'), True)
        for command, group in [('silta task done AC-1 -m result', 'task'),
                               ('silta code grep acme-backend -- X', 'code')]:
            p = phase({'A': command}, [('A', 'started'), ('A', 'completed')], [log(group)])
            self.assertIs(evals.trace_matches_logs(p, 'codex'), False)
