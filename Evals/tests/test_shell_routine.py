"""Ordinary exploration and operand roles preserve useful shell proof."""
from pathlib import Path
import shlex
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT), str(ROOT / 'tests')]
import evals
from shell_commands import parse_shell
from test_pilot_replay import replay
from test_shell_review import phase, log


class RoutineShell(unittest.TestCase):
    def test_24_bounded_read_only_exploration_is_literal(self):
        commands = ['git log --oneline -5', 'git status --porcelain', 'git diff --stat',
                    'git show --format=%H HEAD', 'git rev-parse --verify HEAD',
                    'git branch --show-current', 'git -C ../acme-mobile log -1 --format=%H',
                    'grep -n Acme README.md', 'rg --files -g AGENTS.md .', 'cat README.md',
                    'ls -la', 'head -100 README.md', 'tail -n 20 README.md', 'wc -l README.md',
                    "sed -n '1,120p' README.md", 'pwd', 'echo "==="', "printf '%s\\n' Acme"]
        for command in commands:
            for compound in [command + '; silta brief', 'silta brief; ' + command]:
                for program in [compound, '/bin/zsh -lc ' + shlex.quote(compound)]:
                    with self.subTest(program=program):
                        self.assertFalse(parse_shell(program).opaque)
                        self.assertEqual(parse_shell(program).invocations, [['silta', 'brief']])
        for command in ['git log --output=out', 'git diff --ext-diff', 'rg --pre executable Acme .',
                        "sed -n '1p;w out' README.md", "sed -n 'e command' README.md",
                        "sed -i '' -e 's/a/b/' README.md", 'cat README.md > out',
                        'ls --exec command', "printf '%n' SILTA_HOME", 'echo =gh']:
            self.assertTrue(parse_shell(command).opaque, command)
        self.assertFalse(parse_shell('silta guide 2>&1 | head -100').opaque)

    @staticmethod
    def evidence(command):
        return {'baseline': {'files': {}}, 'phases': [{'commands': [command], 'logs': [],
                'scope': {'repository': '/tmp/acme-eval/repos/acme-mobile',
                          'backends': ['/tmp/acme-eval/repos/acme-backend']},
                'tool_results': [{'command': command, 'cwd': '/tmp/acme-eval/repos/acme-mobile'}],
                'state': {'files': {}}}]}

    def test_isolated_redirects_preserve_exit_proof_without_output_proof(self):
        for command, name in [('silta brief 2>&1', 'brief'),
                              ("silta task plan AC-1 -F - <<'DATA'\nbody\nDATA", 'task plan')]:
            for rendered in [command, 'sh -c ' + shlex.quote(command)]:
                p = phase({'A': rendered}, [('A', 'started'), ('A', 'completed')], [log(name, 2)])
                self.assertIs(evals.trace_matches_logs(p, 'codex'), False, rendered)
                p['tool_results'][0]['exit'] = 2
                self.assertIs(evals.trace_matches_logs(p, 'codex'), True, rendered)
                self.assertEqual(parse_shell(rendered).single(), [])

    def test_25_value_operands_are_data_and_file_operands_remain_reads(self):
        data = ["silta comment AC-1 -m 'Inspect acme-backend/README.md'",
                "silta task add --title 'Inspect acme-backend/README.md'",
                "silta task add 'Inspect acme-backend/README.md'",
                "silta task done AC-1 --result 'Inspect acme-backend/README.md'",
                "silta comment AC-1 --message='Inspect acme-backend/README.md'",
                'silta comment AC-1 -m --steal', 'echo acme-backend/README.md',
                "printf '%s' acme-backend/README.md", "rg 'acme-backend/README.md' .",
                'grep --regexp=acme-backend/README.md README.md',
                'git log --format=acme-backend/README.md',
                "rg -r acme-backend/README.md Acme README.md"]
        for command in data:
            self.assertEqual(evals.forbidden(self.evidence(command)), [], command)
        for command in ['cat ../acme-backend/README.md', 'rg Acme ../acme-backend',
                        'grep Acme ../acme-backend/README.md', 'git -C ../acme-backend log -1',
                        'silta task plan AC-1 -F ../acme-backend/README.md',
                        'silta task plan AC-1 --file=../acme-backend/README.md',
                        'silta task plan AC-1 -F../acme-backend/README.md',
                        'silta task from-plan ../acme-backend/README.md',
                        'grep -f ../acme-backend/patterns README.md',
                        'git -C../acme-backend status --short']:
            self.assertEqual(evals.forbidden(self.evidence(command)), [], command)
            self.assertTrue(evals.shell_program(self.evidence(command)["phases"][0], command,
                            {"cwd": "/tmp/acme-eval/repos/acme-mobile"}).backend_reads)

    def test_26_wrapped_children_inherit_input_uncertainty(self):
        child = 'silta task plan AC-1 -F -'
        for _ in range(2):
            child = 'sh -c ' + shlex.quote(child)
            for command in ["printf '%s' body | " + child,
                            child + " <<'DATA'\nbody\nDATA"]:
                self.assertTrue(parse_shell(command).opaque, command)
        self.assertTrue(parse_shell("printf '%s' body | silta task plan AC-1 -F -").opaque)
        self.assertFalse(parse_shell("sh -c 'silta brief' | head -20").opaque)
        owned = "silta task plan AC-1 -F - <<'DATA'\nbody\nDATA"
        self.assertFalse(parse_shell('sh -c ' + shlex.quote(owned)).opaque)

    def test_27_unsupported_controls_are_opaque_without_token_normalization(self):
        for control in ['\r', '\x00', '\x1b', '\x7f', '\x85', '\u200b']:
            command = 'gh' + control + ' issue create --title Acme'
            self.assertTrue(parse_shell(command).opaque, repr(command))
            self.assertEqual(evals.forbidden(self.evidence(command)), [], repr(command))
        self.assertTrue(parse_shell('silta brief\r\n').opaque)

    def test_pilot_review_burden_and_done_association(self):
        expected = {'done-with-result': 3, 'start-cross-repo': 15,
                    'plan-not-file': 12, 'handoff-resume': 27}
        for scenario, count in expected.items():
            evidence = replay(ROOT / ('tests/pilot/400k/codex-' + scenario + '-default-1'))
            actual = sum(evals.shell_program(p, c, call).opaque for p in evidence['phases']
                         for c, call in evals.command_calls(p))
            self.assertEqual(actual, count, scenario)
            if scenario == 'done-with-result':
                self.assertIsNone(evals.grade(evidence)['checks']['stream_complete'])
