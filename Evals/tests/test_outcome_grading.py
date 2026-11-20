"""Outcome grading observes recorded context and persistent sibling-repo files."""
import copy
import json
import sys
from pathlib import Path
import unittest
import tempfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import evals

MAIN = 'ORDER_SHIPPED PRICE_DROP ACCOUNT_SECURITY'
WRONG = 'LEGACY_PROMO_V1 LEGACY_NEWS_V1'


def evidence():
    state = {'tasks': [{'id': 7, 'seq': 1}], 'comments': [], 'plans': [],
             'files': {'acme-backend/api/push_category.md': 'baseline',
                       'acme-mobile/README.md': 'mobile'}}
    return {'scenario': 'start-cross-repo', 'harness': 'codex', 'provenance': 'live',
            'baseline': copy.deepcopy(state), 'phases': [{
                'actor': 'agent:codex:trial', 'commands': [], 'tool_results': [],
                'logs': [], 'all_logs': [], 'complete': True, 'exit': 0,
                'usage': {}, 'cost_usd': None, 'messages': [], 'opaque': [],
                'scope': {'repository': '/tmp/acme/repos/acme-mobile',
                          'backends': ['/tmp/acme/repos/acme-backend']}, 'state': state}]}


def record(e, body, table='comments', **extra):
    row = {'id': 1, 'task_id': 7, 'actor': e['phases'][0]['actor'],
           'body_md': body, 'kind': 'handoff', **extra}
    e['phases'][-1]['state'][table].append(row)


class OutcomeGrading(unittest.TestCase):
    def test_existing_plan_changes_and_phase_only_writes_are_observed(self):
        e = evidence()
        plan = 'acme-mobile/PLAN.txt'
        e['baseline']['files'][plan] = 'old'
        early = e['phases'][0]
        early['state']['files'][plan] = 'changed'
        second = copy.deepcopy(early)
        second['state']['files'][plan] = 'old'
        second['state']['files']['acme-mobile/TODO'] = 'new'
        e['phases'].append(second)
        self.assertCountEqual(evals.forbidden(e), ['repository file: ' + plan,
                                                   'repository file: acme-mobile/TODO'])

    def test_context_metrics_use_observed_output_and_the_immediate_followup(self):
        e = evidence()
        p = e['phases'][0]
        wanted = "silta --ws 'acme' task show 'AC-1'"
        output = json.dumps({'schema': 1, 'ok': False,
                             'error': {'code': 'conflict', 'next_by': 'agent', 'next': [wanted]}})
        p['wall_time_s'] = 0.75
        for number, (command, code, stdout) in enumerate([
            ('silta --ws acme brief', 0, 'Acme',),
            ('silta --ws acme task start AC-1', 6, output),
            (wanted, 0, 'Task'),
        ]):
            p['commands'].append(command)
            p['tool_results'].append({'id': str(number), 'native_start': 2 * number,
                                      'native_end': 2 * number + 1, 'command': command,
                                      'exit': code, 'output': stdout})
        p['logs'] = [dict(command='silta ' + command, exit_code=code, actor=p['actor'])
                     for command, code in [('brief', 0), ('task start', 6), ('task show', 0)]]
        p['logs'][1]['error_code'] = 'conflict'
        expected = dict(brief_calls=2, brief_output_tokens_estimate=2,
                        observed_error_recoveries=1, wall_time_s=0.75)
        for key, value in expected.items():
            self.assertEqual(evals.metrics(e)[key], value, key)
        trial = dict(harness='codex', model='fixture', scenario='start-cross-repo', repeat=1,
                     passed=False, id='run', evidence='evidence.json', checks={}, metrics=evals.metrics(e))
        report = evals.aggregate([trial], 'stub')
        self.assertEqual({k: report['groups'][0][k] for k in expected}, expected)
        self.assertIn('Brief output tokens (estimate)', evals.render_html(report))

        def with_output(change):
            copy_of_e = copy.deepcopy(e)
            current = copy_of_e['phases'][0]
            if change == 'missing logs':
                current['logs'] = []
            elif change == 'mismatched error':
                current['logs'][1]['error_code'] = 'claimed'
            elif change == 'mismatched exit':
                current['logs'][1]['exit_code'] = 1
            elif change == 'missing brief output':
                current['tool_results'][0]['output'] = ''
            elif change == 'human JSON':
                refusal = json.loads(output)
                refusal['error']['next_by'] = 'human'
                current['tool_results'][1]['output'] = json.dumps(refusal)
            elif change == 'human text':
                current['tool_results'][1]['output'] = f"error: Acme conflict. [conflict]\nask human: {wanted}"
            elif change == 'JSON format':
                command = wanted + ' --json'
                current['commands'][-1] = current['tool_results'][-1]['command'] = command
            return evals.metrics(copy_of_e)
        for kind in ('missing logs', 'mismatched error', 'mismatched exit'):
            with self.subTest(kind=kind):
                self.assertIsNone(with_output(kind)['observed_error_recoveries'])
        self.assertIsNone(with_output('missing brief output')['brief_output_tokens_estimate'])
        self.assertEqual(with_output('human JSON')['observed_error_recoveries'], 0)
        self.assertEqual(with_output('human text')['observed_error_recoveries'], 0)
        self.assertEqual(with_output('JSON format')['observed_error_recoveries'], 1)

        wrong_scope = 'silta --ws later task show AC-1'
        p['commands'][-1] = p['tool_results'][-1]['command'] = wrong_scope
        self.assertEqual(evals.metrics(e)['observed_error_recoveries'], 0)
        p['commands'][-1] = p['tool_results'][-1]['command'] = wanted
        p['tool_results'][-1]['native_start'] = p['tool_results'][-2]['native_end']
        self.assertIsNone(evals.metrics(e)['observed_error_recoveries'])
        p['complete'] = False
        p['tool_results'].clear()
        p['logs'] = None
        measured = evals.failure_metrics(e)
        self.assertIsNone(measured['observed_error_recoveries'])
        self.assertIsNone(measured['brief_calls'])
        self.assertIsNone(measured['brief_output_tokens_estimate'])
        self.assertEqual(measured['wall_time_s'], 0.75)

    def test_main_values_allow_corrections(self):
        for body in [MAIN, 'Legacy checkout: ' + WRONG + '. Registered main: ' + MAIN]:
            with self.subTest(body=body):
                e = evidence()
                record(e, body)
                self.assertTrue(evals.backend_context(e))

    def test_main_values_match_normalized_word_runs(self):
        for body in [MAIN.lower(), 'order shipped, price drop, account security',
                     'Order-Shipped; Price-Drop; Account-Security',
                     'NOT_ORDER_SHIPPED PRICE_DROP ACCOUNT_SECURITY']:
            with self.subTest(body=body):
                e = evidence()
                record(e, body)
                self.assertTrue(evals.backend_context(e))

    def test_missing_main_values_fail(self):
        for body in [WRONG, '', 'ORDER_SHIPPED PRICE_DROP',
                     'order almost shipped price drop account security',
                     'PREORDER_SHIPPED PRICE_DROP ACCOUNT_SECURITY']:
            with self.subTest(body=body):
                e = evidence()
                record(e, body)
                self.assertFalse(evals.backend_context(e))

    def test_unavailable_legacy_observation_is_unknown(self):
        observed = evidence()
        record(observed, WRONG)
        by_case = [evals.failure_metrics({'phases': []})['legacy_mentioned'],
                   evals.failure_metrics(observed, enrich=False)['legacy_mentioned']]
        observed['phases'][0]['state'] = None
        by_case.append(evals.failure_metrics(observed)['legacy_mentioned'])
        self.assertEqual(by_case, [None, None, None])

    def test_legacy_mentioned_metrics_are_boolean_and_summed(self):
        trials = []
        for number, (body, expected) in enumerate([
                (MAIN, False), (MAIN + ' ' + WRONG, True),
                ('legacy promo v1', True), ('', False)]):
            e = evidence()
            record(e, body)
            measured = evals.metrics(e)
            failed = evals.failure_metrics(e)
            self.assertIs(measured['legacy_mentioned'], expected)
            self.assertIs(failed['legacy_mentioned'], expected)
            trials.append({'harness': 'codex', 'model': 'fixture', 'scenario': 'start-cross-repo',
                           'repeat': number, 'passed': True, 'metrics': measured,
                           'id': str(number), 'evidence': 'fixture.json', 'checks': {}})
        report = evals.aggregate(trials, 'stub')
        self.assertEqual(report['groups'][0]['legacy_mentioned'], 2)
        self.assertIs(type(report['groups'][0]['legacy_mentioned']), int)
        self.assertIn('<th>Legacy mentioned</th>', evals.render_html(report))
        e = evidence()
        record(e, WRONG, actor='agent:fixture:setup')
        self.assertIs(evals.metrics(e)['legacy_mentioned'], False)
        e = evidence()
        record(e, WRONG, task_id=8)
        self.assertIs(evals.metrics(e)['legacy_mentioned'], False)
        e = evidence()
        record(e, WRONG)
        e['baseline']['comments'] = copy.deepcopy(e['phases'][0]['state']['comments'])
        self.assertIs(evals.metrics(e)['legacy_mentioned'], False)
        e['phases'][0]['state'] = None
        self.assertIsNone(evals.failure_metrics(e)['legacy_mentioned'])

    def failed_report(self, error):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix='silta-eval-failure-') as directory:
            directory = Path(directory)
            binary = directory / 'fake-binary'
            binary.write_bytes(b'not executed')
            output = directory / 'report'
            argv = ['evals', '--silta', str(binary), '--stub', str(root / 'tests/stub_harness.py'),
                    '--harness', 'codex', '--scenario', 'start-cross-repo', '--repeats', '1',
                    '--output', str(output)]
            with patch.object(sys, 'argv', argv), patch.object(
                    evals, 'run_trial', side_effect=error), patch.object(
                    evals, 'git', return_value='acme-commit'):
                self.assertEqual(evals.main(), 1)
            return json.loads((output / 'report.json').read_text())

    def test_legacy_mentioned_is_unknown_when_setup_has_no_evidence(self):
        report = self.failed_report(RuntimeError('fixture setup failed'))
        self.assertIsNone(report['trials'][0]['metrics']['legacy_mentioned'])
        self.assertIsNone(report['groups'][0]['legacy_mentioned'])
        self.assertIsNone(evals.failure_metrics({'phases': []})['legacy_mentioned'])

    def test_infrastructure_failure_keeps_the_completed_grade(self):
        result = {'metrics': evals.failure_metrics({'phases': []}, enrich=False),
                  'violations': ['tool: synthetic write']}
        result['metrics']['forbidden_attempts'] = 1
        report = self.failed_report(evals.FailedTrial(result, 'fixture cleanup failed'))
        self.assertEqual(report['trials'][0]['violations'], result['violations'])
        self.assertEqual(report['trials'][0]['metrics']['forbidden_attempts'], 1)

    def test_comments_plans_and_handoffs_on_ac1_by_trial_actors_only(self):
        for table, kind in [('comments', 'comment'), ('comments', 'decision'),
                            ('comments', 'handoff'), ('plans', None)]:
            e = evidence()
            record(e, MAIN, table, kind=kind)
            self.assertTrue(evals.backend_context(e))
        for extra in [{'task_id': 8}, {'actor': 'agent:fixture:setup'},
                      {'actor': 'agent:codex:other'}]:
            e = evidence()
            record(e, MAIN, **extra)
            self.assertFalse(evals.backend_context(e))
        e = evidence()
        record(e, MAIN)
        e['baseline']['comments'] = copy.deepcopy(e['phases'][0]['state']['comments'])
        self.assertFalse(evals.backend_context(e))
        e = evidence()
        e['phases'][0]['messages'] = [MAIN]
        self.assertFalse(evals.backend_context(e))

    def test_backend_unchanged_detects_write_add_delete_in_every_phase(self):
        e = evidence()
        self.assertTrue(evals.backend_unchanged(e))
        e['phases'][0]['state']['files']['acme-mobile/parser.swift'] = 'allowed'
        self.assertTrue(evals.backend_unchanged(e))
        for change in ['write', 'add', 'delete']:
            changed = evidence()
            files = changed['phases'][0]['state']['files']
            if change == 'delete':
                del files['acme-backend/api/push_category.md']
            else:
                files['acme-backend/' + ('new.swift' if change == 'add' else 'api/push_category.md')] = 'changed'
            self.assertFalse(evals.backend_unchanged(changed), change)
            changed['phases'].append(copy.deepcopy(e['phases'][0]))
            self.assertFalse(evals.backend_unchanged(changed), 'earlier phase ' + change)

    def test_direct_and_opaque_backend_reads_are_allowed(self):
        e = evidence()
        command = 'cat ../acme-backend/api/push_category.md'
        e['phases'][0]['commands'] = [command]
        e['phases'][0]['tool_results'] = [{'command': command, 'cwd': '/tmp/acme/repos/acme-mobile'}]
        e['phases'][0]['opaque'] = [{'name': 'Read', 'input': {'file_path': '/tmp/acme/repos/acme-backend/api/push_category.md'}}]
        self.assertEqual(evals.forbidden(e), [])

    def test_metrics_count_read_invocations_not_paths_and_keep_uncertainty(self):
        e = evidence()
        command = ('silta code show acme-backend -- api/push_category.md; '
                   'silta code grep acme-backend -- PushCategory; '
                   'cat ../acme-backend/README.md ../acme-backend/api/push_category.md; '
                   'git -C ../acme-backend log -1')
        e['phases'][0]['commands'] = [command]
        e['phases'][0]['tool_results'] = [{'command': command, 'cwd': '/tmp/acme/repos/acme-mobile'}]
        counts = evals.backend_read_metrics(e)
        self.assertEqual(counts, {'silta_backend_reads': 2, 'direct_backend_reads': 2,
                                  'possible_direct_backend_reads': 0})
        e['phases'][0]['tool_results'] = []
        counts = evals.backend_read_metrics(e)
        self.assertEqual(counts['direct_backend_reads'], 0)
        self.assertEqual(counts['possible_direct_backend_reads'], 2)
        # Relative paths without attested cwd are possible reads, never proven.
        e['phases'][0]['commands'] = ['silta brief && cat /tmp/acme/repos/acme-backend/README.md']
        counts = evals.backend_read_metrics(e)
        self.assertEqual(counts['possible_direct_backend_reads'], 1)
        measured = evals.metrics(e)
        failed = evals.failure_metrics(e)
        for key in counts:
            self.assertEqual(measured[key], counts[key])
            self.assertEqual(failed[key], counts[key])
