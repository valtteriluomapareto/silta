"""Document outcomes use real CLI state and authored native evidence, never a model."""
from contextlib import closing
import copy
import json
from pathlib import Path
import re
import shlex
import sqlite3
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
TOKEN = 'UNSORTED_Q7'
ACTOR = 'agent:codex:doc-trial'
FOREIGN = 'agent:codex:other'


class DocContext(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='silta-doc-eval-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def prepare(self, proposed=False):
        real = evals.silta
        def seed(env, cwd, args, *values, **options):
            if proposed and args[:2] == ['task', 'add']:
                args = args[:-2]
            return real(env, cwd, args, *values, **options)
        with patch.object(evals, 'silta', side_effect=seed):
            self.env, self.cwd, sha, controls = evals.prepare(
                self.root, BINARY, 'codex', 'doc-context', 'default')
        self.e = dict(scenario='doc-context', harness='codex', provenance='live', sha=sha,
                      baseline=evals.snapshot(self.root / 'data', self.root / 'repos'),
                      controls=controls, phases=[])
        return self.e

    def run_cli(self, args, actor=ACTOR, stdin=None):
        argv = ['silta', '--ws', 'acme', *args]
        command = shlex.join(argv)
        index = len(self.events)
        self.events.append({'type': 'item.started', 'item': dict(
            type='command_execution', id=str(index), command=command)})
        result = evals.silta(dict(self.env, SILTA_ACTOR=actor), self.cwd, args, stdin)
        self.events.append({'type': 'item.completed', 'item': dict(
            type='command_execution', id=str(index), command=command,
            exit_code=result['exit'], aggregated_output=result['stdout'] + result['stderr'])})
        return result['stdout']

    def phase(self, action):
        cursor = len(evals.logs(self.root / 'data'))
        self.events = [{'type': 'thread.started', 'thread_id': 'doc-fixture'}]
        action()
        self.events.append({'type': 'turn.completed', 'usage': {}})
        phase = evals.parse_stream('codex', '\n'.join(json.dumps(e) for e in self.events))
        logs = evals.logs(self.root / 'data')[cursor:]
        phase.update(actor=ACTOR, exit=0, all_logs=logs,
                     logs=[log for log in logs if log['actor'] == ACTOR],
                     scope={'repository': str(self.cwd),
                            'backends': [str(self.cwd.parent / 'acme-backend')]},
                     state=evals.snapshot(self.root / 'data', self.root / 'repos'))
        self.assertTrue(phase['complete'])
        self.e['phases'].append(phase)
        return phase

    def outcome(self, evidence=None):
        return evals.grade(evidence or self.e)['checks'].get('doc_context', False)

    def edit(self, result=None, title=None, actor=ACTOR):
        document = json.loads(self.run_cli(['task', 'edit', 'AC-1', '--print', '--json'], actor))['data']['document']
        if result is not None:
            prefix, section = document.rsplit('## Result\n', 1)
            fence = section.splitlines()[0]
            document = prefix + '## Result\n' + fence + '\n' + result + '\n' + fence + '\n'
        if title is not None:
            document = re.sub(r'(## Title\n~~~\n).*?(\n~~~)',
                              lambda m: m[1] + title + m[2], document, count=1, flags=re.S)
        self.run_cli(['task', 'edit', 'AC-1', '-F', '-', '--approved',
                      'Synthetic Acme attribution test.', '--json'], actor, document)

    def test_plan_outcome_needs_no_doc_read(self):
        self.prepare()
        self.phase(lambda: self.run_cli(['task', 'plan', 'AC-1', '-F', '-', '--json'], stdin=TOKEN))
        self.assertTrue(self.outcome(), 'a real trial plan is the approved outcome, without doc show')
        for field, value in [('actor', FOREIGN), ('task_id', 999)]:
            e = copy.deepcopy(self.e)
            e['phases'][-1]['state']['plans'][-1][field] = value
            self.assertFalse(self.outcome(e))
        e = copy.deepcopy(self.e)
        e['baseline']['plans'] = copy.deepcopy(e['phases'][-1]['state']['plans'])
        self.assertFalse(self.outcome(e))

    def test_result_done_drop_edit_and_triage_drop(self):
        original = self.root
        for method in ['done', 'drop', 'edit', 'triage']:
            with self.subTest(method=method):
                self.root = original / method
                self.root.mkdir()
                self.prepare(proposed=method == 'triage')
                def write():
                    if method == 'edit':
                        self.run_cli(['task', 'start', 'AC-1', '--json'])
                        self.edit(result=TOKEN)
                    elif method == 'triage':
                        self.run_cli(['task', 'triage', '--drop', 'AC-1', '-m', TOKEN,
                                      '--approved', 'Synthetic Acme attribution test.', '--json'])
                    else:
                        self.run_cli(['task', method, 'AC-1', '-m', TOKEN,
                                      *(['--no-sha'] if method == 'done' else []), '--json'])
                self.phase(write)
                self.assertTrue(self.outcome(), 'actual ' + method + ' result must count')
                self.root = original

    def test_foreign_and_ambiguous_result_writers(self):
        self.prepare()
        def write():
            self.run_cli(['task', 'done', 'AC-1', '-m', 'Acme work finished.', '--no-sha', '--json'])
            self.edit(result=TOKEN, actor=FOREIGN)
            self.edit(title='Acme title changed')
        self.phase(write)
        self.assertFalse(self.outcome())
        self.phase(lambda: self.edit(title='Acme another title'))
        self.assertFalse(self.outcome())
        self.phase(lambda: self.edit(result='Use ' + TOKEN))
        self.assertTrue(self.outcome(), 'a later exclusive changed-result interval reestablishes ownership')
        self.phase(lambda: self.edit(title='Acme foreign title', actor=FOREIGN))
        self.assertFalse(self.outcome(), 'foreign title-only candidate is explicitly unproven')
        self.phase(lambda: self.run_cli(['task', 'plan', 'AC-1', '-F', '-', '--json'], stdin=TOKEN))
        self.assertTrue(self.outcome(), 'the independent plan alternative survives')

    def test_result_baseline_identity_history_and_tool_evidence(self):
        self.prepare()
        self.phase(lambda: self.edit(result=TOKEN))
        self.assertTrue(self.outcome())
        for change in ['baseline', 'identity', 'event', 'native', 'logs', 'partial', 'chat']:
            e = copy.deepcopy(self.e)
            state = e['phases'][-1]['state']
            if change == 'baseline':
                e['baseline']['tasks'][0]['result_md'] = TOKEN
            elif change == 'identity':
                state['tasks'][0]['uid'] = 'different'
            elif change == 'event':
                state['events'] = e['baseline']['events']
            elif change == 'native':
                e['phases'][0]['tool_results'] = []
            elif change == 'logs':
                e['phases'][0]['logs'] = []
            elif change == 'partial':
                state['tasks'][0]['result_md'] = 'NOT_' + TOKEN
            else:
                state['tasks'][0]['result_md'] = ''
                e['phases'][0]['messages'] = [TOKEN]
            with self.subTest(change=change):
                self.assertFalse(self.outcome(e))

    def test_fixture_token_only_in_body_below_summary_on_edge(self):
        self.prepare()
        with closing(sqlite3.connect(self.root / 'data/silta.db')) as db:
            rows = db.execute('SELECT d.slug,r.body_md FROM doc d JOIN doc_rev r ON r.doc_id=d.id AND r.rev=d.current_rev').fetchall()
        self.assertEqual(len(rows), 1, 'the primary fixture must seed an accepted edge doc')
        self.assertIn(TOKEN, rows[0][1])
        env = dict(self.env, SILTA_ACTOR=ACTOR)
        for args in [['brief', '--json'], ['doc', 'ls', '--about', 'edge:acme-mobile/acme-backend/http-api', '--json']]:
            output = evals.silta(env, self.cwd, args)['stdout']
            self.assertIn('doc:' + rows[0][0], output)
            self.assertNotIn(TOKEN, output)
        for path in (self.root / 'repos').rglob('*'):
            if path.is_file() and '.git' not in path.parts:
                self.assertNotIn(TOKEN, path.read_text())
        spec = (ROOT / 'scenarios/doc-context/scenario.yaml').read_text()
        self.assertNotIn(TOKEN, spec)
        self.assertNotIn(TOKEN, rows[0][1].splitlines()[0])

    def trial(self, harness, scenario, recording='pass'):
        output = self.root / (harness + '-' + scenario + '-' + recording)
        output.mkdir()
        result = evals.run_trial(BINARY, harness, 'recorded-stub', scenario, 'default', 1,
                                STUB, output, stub=True, recording=recording)
        return result, json.loads((output / result['evidence']).read_text())

    def test_primary_stub_reads_actual_ref_and_records_outcome_both_adapters(self):
        for harness in ['claude', 'codex']:
            with self.subTest(harness=harness):
                result, evidence = self.trial(harness, 'doc-context')
                self.assertTrue(result['checks'].get('doc_context', False))
                self.assertTrue(result['checks']['stream_complete'])
                self.assertTrue(any(log['command'] == 'silta doc show' for log in evidence['phases'][0]['logs']))
                self.assertTrue(any(TOKEN in row['body_md'] for row in evidence['phases'][0]['state']['plans']))
                failed, _ = self.trial(harness, 'doc-context', 'fail')
                self.assertFalse(failed['checks'].get('doc_context', False))

    def test_changed_token_and_slug_are_derived_from_real_output(self):
        real = evals.silta
        def seed(env, cwd, args, stdin=None, **options):
            if args[:2] == ['doc', 'edit']:
                args = [*args[:2], 'acme-other-rule', *args[3:]]
                stdin = stdin.replace(TOKEN, 'ACME_ALTERNATE_42')
            return real(env, cwd, args, stdin, **options)
        with patch.object(evals, 'silta', side_effect=seed):
            _, e = self.trial('codex', 'doc-context')
        plans = e['phases'][0]['state']['plans']
        self.assertTrue(any('ACME_ALTERNATE_42' in row['body_md'] for row in plans))
        self.assertTrue(any('acme-other-rule' in c and 'doc show' in c for c in e['phases'][0]['commands']))
        self.assertFalse(any(TOKEN in row['body_md'] for row in plans))

    def test_explicit_control_has_raw_failure_full_reports_and_no_infrastructure_error(self):
        for harness in ['claude', 'codex']:
            output = self.root / (harness + '-control')
            run = subprocess.run([sys.executable, '-B', str(ROOT / 'evals.py'), '--silta', str(BINARY),
                                  '--stub', str(STUB), '--harness', harness, '--scenario',
                                  'doc-context-no-doc', '--repeats', '1', '--output', str(output)],
                                 text=True, capture_output=True)
            self.assertEqual(run.returncode, 1, run.stderr)
            report = json.loads((output / 'report.json').read_text())
            self.assertTrue((output / 'report.html').exists())
            trial = report['trials'][0]
            self.assertIn('doc_context', trial['checks'])
            self.assertFalse(trial['checks']['doc_context'])
            self.assertNotIn('infrastructure', trial['checks'])
            e = json.loads((output / trial['evidence']).read_text())
            self.assertEqual(e['phases'][0]['exit'], 0)
            self.assertTrue(e['phases'][0]['complete'])
            self.assertFalse(trial['passed'])
            self.assertEqual(report['groups'][0]['pass_rate'], 0)

    def test_default_core_and_explicit_control_selection(self):
        for selection, expected in [([], set(evals.SCENARIOS) - {'doc-context-no-doc'}),
                                    (['--core'], {'start-cross-repo', 'plan-not-file',
                                                  'handoff-resume', 'done-with-result'}),
                                    (['--scenario', 'doc-context-no-doc'], {'doc-context-no-doc'})]:
            calls = []
            def observe(*args, **kwargs):
                calls.append((args[1], args[3]))
                raise RuntimeError('Selection-only unit test; no trial executed')
            output = self.root / ('selection-' + str(len(selection)) + '-' + str(len(expected)))
            argv = ['evals', '--silta', str(BINARY), '--stub', str(STUB),
                    '--output', str(output), '--repeats', '1', *selection]
            with patch.object(sys, 'argv', argv), patch.object(evals, 'run_trial', side_effect=observe):
                self.assertEqual(evals.main(), 1)
            self.assertEqual(set(calls), {(adapter, scenario) for adapter in ['claude', 'codex']
                                         for scenario in expected})
