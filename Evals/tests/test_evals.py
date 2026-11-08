"""Offline acceptance: only the repository stub may be launched as a harness."""
import copy
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from negative_evidence import invalidate

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
BINARY = ROOT.parent / '.build/debug/silta'
STUB = Path(__file__).with_name('stub_harness.py')
SCENARIOS = ['start-cross-repo', 'plan-not-file', 'handoff-resume',
             'done-with-result', 'proposals-ask', 'ask-short']


class Acceptance(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='silta-evals-test-')
        cls.output = Path(cls.temp.name) / 'passing'
        cls.command = [str(ROOT / 'run.sh'), '--silta', str(BINARY),
                       '--stub', str(STUB), '--output', str(cls.output)]
        if not (ROOT / 'run.sh').exists():
            raise AssertionError('Missing eval matrix runner: six real-CLI replay scenarios cannot run')
        if os.environ.get('SI_EVAL_TEST_REPORT'):
            cls.output = Path(os.environ['SI_EVAL_TEST_REPORT'])
        else:
            result = subprocess.run(cls.command, capture_output=True, text=True)
            if result.returncode:
                raise AssertionError(f'offline runner failed: {result.stdout}\n{result.stderr}')
        cls.report = json.loads((cls.output / 'report.json').read_text())
        cls.evals = importlib.import_module('evals')

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_both_adapters_all_scenarios_three_repeats(self):
        self.assertEqual(self.report['provenance'], 'stub')
        groups = self.report['groups']
        self.assertEqual(len(groups), 12)
        for group in groups:
            self.assertEqual(group['repeats'], 3)
            self.assertEqual(group['pass_rate'], 1)
            self.assertTrue(group['all_repeats_pass'])
        self.assertEqual({g['scenario'] for g in groups}, set(SCENARIOS))

    def test_failing_recording_per_scenario(self):
        output = Path(self.temp.name) / 'failing'
        result = subprocess.run(self.command[:-1] + [str(output), '--repeats', '1',
                                '--recording', 'fail'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        report = json.loads((output / 'report.json').read_text())
        self.assertEqual(len(report['groups']), 12)
        self.assertTrue(all(g['pass_rate'] == 0 for g in report['groups']))
        expected = {(harness, scenario, variant) for harness in ['claude', 'codex']
                    for scenario in SCENARIOS
                    for variant in json.loads((ROOT / 'scenarios' / scenario / 'scenario.yaml').read_text())['variants']}
        self.assertEqual(len(report['trials']), len(expected))
        self.assertEqual({(t['harness'], t['scenario'], t['variant']) for t in report['trials']}, expected)
        for trial in report['trials']:
            with self.subTest(harness=trial['harness'], scenario=trial['scenario'], variant=trial['variant']):
                self.assertNotIn('infrastructure', trial['checks'])
                self.assertFalse(trial['passed'])

    def test_grader_guarantees(self):
        # Each row is a separate negative evidence test and source-fault target.
        inventory = json.loads((ROOT / 'tests/guarantees.json').read_text())
        for guarantee, case in inventory.items():
            with self.subTest(guarantee=guarantee):
                trial = next(t for t in self.report['trials']
                             if t['scenario'] == case['scenario']
                             and t['variant'] == case['variant'])
                evidence = json.loads((self.output / trial['evidence']).read_text())
                self.assertTrue(self.evals.grade(evidence)['checks'][guarantee])
                invalidate(evidence, guarantee)
                graded = self.evals.grade(evidence)
                self.assertFalse(graded['checks'][guarantee], guarantee)
                self.assertFalse(graded['passed'])

    def evidence(self, scenario, variant='default'):
        trial = next(t for t in self.report['trials']
                     if t['scenario'] == scenario and t['variant'] == variant)
        return json.loads((self.output / trial['evidence']).read_text())

    def test_approval_cannot_be_invented_replayed_or_used_early(self):
        original = self.evidence('proposals-ask', 'present-add')
        for field, value in [('words', 'invented'), ('trial', 'another-trial'),
                             ('phase_digest', 'stale'), ('command', 'silta task promote AC-1'),
                             ('source', 'assistant-event')]:
            with self.subTest(field=field):
                evidence = copy.deepcopy(original)
                evidence['approval'][field] = value
                self.assertFalse(self.evals.grade(evidence)['checks']['approval_provenance'])
        evidence = copy.deepcopy(original)
        evidence['phases'][0]['state']['tasks'].append(evidence['phases'][1]['state']['tasks'][-1])
        self.assertFalse(self.evals.grade(evidence)['checks']['approval_provenance'])
        evidence = copy.deepcopy(original)
        evidence['approval'] = None
        self.assertFalse(self.evals.grade(evidence)['checks']['approval_provenance'])

    def test_resume_wrong_task_actor_and_replan(self):
        original = self.evidence('handoff-resume')
        for key in ['resume_task', 'resume_no_replan', 'resume_brief_first', 'handoff_written']:
            evidence = copy.deepcopy(original)
            invalidate(evidence, key)
            self.assertFalse(self.evals.grade(evidence)['checks'][key])
        evidence = copy.deepcopy(original)
        for comment in evidence['phases'][1]['state']['comments']:
            if comment['actor'] == evidence['phases'][1]['actor']:
                comment['task_id'] = 999
        self.assertFalse(self.evals.grade(evidence)['checks']['resume_task'])
        evidence = copy.deepcopy(original)
        for event in evidence['phases'][1]['state']['events']:
            if event['kind'] == 'claim' and event['actor'] == evidence['phases'][1]['actor']:
                event['task_id'] = 999
        self.assertFalse(self.evals.grade(evidence)['checks']['resume_task'])

    def test_setup_calls_excluded_and_usage_forbidden_counted(self):
        evidence = self.evidence('start-cross-repo')
        metrics = self.evals.grade(evidence)['metrics']
        self.assertEqual(metrics['silta_calls'], 4)
        self.assertEqual(metrics['ctx_calls'], 2)
        phases = evidence['phases']
        log = copy.deepcopy(phases[0]['logs'][0])
        log.update(command='silta task add', error_code='usage', exit_code=1,
                   flags=['--force'])
        phases[0]['logs'].append(log)
        phases[0]['all_logs'].append(log)
        metrics = self.evals.grade(evidence)['metrics']
        self.assertEqual(metrics['usage_errors'], 1)
        self.assertEqual(metrics['forbidden_attempts'], 1)
        phases[0]['all_logs'].append(dict(log, actor='agent:other:session'))
        self.assertFalse(self.evals.grade(evidence)['checks']['agent_logs'])

    def test_repeat_pass_requires_every_policy_variant(self):
        trials = copy.deepcopy(self.report['trials'])
        trial = next(t for t in trials if t['scenario'] == 'ask-short')
        trial['passed'] = False
        group = next(g for g in self.evals.aggregate(trials, 'stub')['groups']
                     if g['harness'] == trial['harness'] and g['scenario'] == trial['scenario'])
        self.assertAlmostEqual(group['pass_rate'], 2 / 3)
        self.assertFalse(group['all_repeats_pass'])

    def test_review_policy_language_is_not_a_keyword_grammar(self):
        evidence = self.evidence('ask-short', 'short')
        for comment in evidence['phases'][0]['state']['comments']:
            if comment['kind'] == 'decision':
                comment['body_md'] = 'Use AcmeParse for parsing.'
        evidence['phases'][0]['messages'] = ['I will inspect the task.',
                                           'Please approve the customer-facing text.']
        evidence['provenance'] = 'live'
        evidence['review']['reviewer'] = 'fixture-human-reviewer'
        evidence['review']['digest'] = self.evals.review_digest(evidence)
        self.assertTrue(self.evals.grade(evidence)['passed'])
        evidence = self.evidence('proposals-ask', 'absent-add')
        for comment in evidence['phases'][0]['state']['comments']:
            if comment['kind'] == 'handoff':
                comment['body_md'] = "What's left: the retry defect needs a later task."
        evidence['provenance'] = 'live'
        evidence['review']['reviewer'] = 'fixture-human-reviewer'
        evidence['review']['digest'] = self.evals.review_digest(evidence)
        self.assertTrue(self.evals.grade(evidence)['passed'])

    def test_review_approval_audit_fields_and_equivalent_shell_argv(self):
        original = self.evidence('proposals-ask', 'present-add')
        for field, value in [('actor', 'agent:other:session'), ('workspace', 'other'),
                             ('command', 'silta task promote AC-999')]:
            evidence = copy.deepcopy(original)
            evidence['phases'][1]['state']['approvals'][-1][field] = value
            self.assertFalse(self.evals.grade(evidence)['checks']['approval_provenance'], field)
        import shlex
        command = original['approval']['command']
        words = original['approval']['words']
        actual = command + ' --approved "' + words + '"'
        for rendered in [actual, '/bin/zsh -lc ' + shlex.quote(actual),
                         'silta --approved ' + shlex.quote(words) + ' ' + command.removeprefix('silta ')]:
            evidence = copy.deepcopy(original)
            evidence['phases'][1]['commands'][0] = rendered
            self.assertTrue(self.evals.grade(evidence)['checks']['approval_provenance'], rendered)
        evidence = copy.deepcopy(original)
        evidence['phases'][1]['commands'][0] = actual + ' --force'
        self.assertFalse(self.evals.grade(evidence)['checks']['approval_provenance'])

    def test_review_usage_json_text_and_mixed_logged_unlogged(self):
        folder = Path(self.temp.name) / 'usage-fixture'
        env = self.evals.isolated_env(folder)
        evidence = self.evidence('start-cross-repo')
        for extra in [[], ['--json']]:
            run = subprocess.run([str(BINARY), 'task', 'add', '--bogus', *extra],
                                 env=env, capture_output=True, text=True)
            self.assertEqual(run.returncode, 1)
            evidence['phases'][0]['tool_results'].append({
                'command': 'silta task add --bogus ' + ' '.join(extra), 'exit': run.returncode,
                'output': run.stdout + run.stderr})
        self.assertEqual(self.evals.grade(evidence)['metrics']['usage_errors'], 2)
        # A separate logged usage failure has no corresponding result in this copy.
        log = copy.deepcopy(evidence['phases'][0]['logs'][0])
        log.update(command='silta code grep', error_code='usage', exit_code=1)
        evidence['phases'][0]['logs'].append(log)
        self.assertEqual(self.evals.grade(evidence)['metrics']['usage_errors'], 3)
        # Adding its native result must not count that invocation twice.
        evidence['phases'][0]['tool_results'].append({
            'command': 'silta code grep --bogus', 'exit': 1, 'output': 'Unknown option [usage]'})
        self.assertEqual(self.evals.grade(evidence)['metrics']['usage_errors'], 3)

    def test_review_result_sections_need_distinct_nonempty_bodies(self):
        for body in ["What was done: Decisions: What's left: nothing",
                     "What was done:\nDecisions: reused API\nWhat's left: nothing",
                     "What was done: verified parser\nDecisions:\nWhat's left: nothing"]:
            evidence = self.evidence('done-with-result')
            evidence['phases'][-1]['state']['tasks'][0]['result_md'] = body
            self.assertFalse(self.evals.grade(evidence)['checks']['result_template'], body)

    def test_claims_do_not_override_database(self):
        trial = next(t for t in self.report['trials'] if t['scenario'] == 'done-with-result')
        evidence = json.loads((self.output / trial['evidence']).read_text())
        evidence['phases'][-1]['messages'].append('Everything passed; task done with SHA.')
        evidence['phases'][-1]['state']['tasks'][0]['result_md'] = None
        self.assertFalse(self.evals.grade(evidence)['passed'])

    def test_started_accepts_both_existing_claim_and_create_with_start(self):
        evidence = self.evidence('start-cross-repo')
        self.assertTrue(self.evals.started(evidence))
        phase = evidence['phases'][0]
        for log in phase['logs']:
            if log['command'] == 'silta task start':
                log.update(command='silta task add', flags=[])
        for event in phase['state']['events']:
            if event['kind'] == 'claim' and event['actor'] == phase['actor']:
                event.update(kind='created', body='doing')
        self.assertTrue(self.evals.started(evidence))
        for event in phase['state']['events']:
            if event['actor'] == phase['actor'] and event['kind'] == 'created':
                event['body'] = 'todo'
        self.assertFalse(self.evals.started(evidence))

    def test_created_start_uses_actual_event_not_unlogged_flag(self):
        root = Path(self.temp.name) / 'create-start'
        env, cwd, _, _ = self.evals.prepare(root, BINARY, 'codex', 'start-cross-repo', 'default')
        env['SILTA_ACTOR'] = 'agent:codex:create-proof'
        cursor = len(self.evals.logs(root / 'data'))
        self.evals.silta(env, cwd, ['task', 'add', 'Acme push categories', '--app',
                                  'acme-mobile', '--start', '--json'])
        phase = {'actor': env['SILTA_ACTOR'], 'logs': self.evals.logs(root / 'data')[cursor:],
                 'state': self.evals.snapshot(root / 'data', root / 'repos')}
        self.assertNotIn('--start', phase['logs'][0]['flags'])
        self.assertTrue(self.evals.started({'phases': [phase]}))

    def test_backend_claim_needs_the_actual_target_command(self):
        output = json.dumps({'data': {'app': 'acme-backend', 'sha': 'a' * 40,
                                      'output': 'PushCategory'}})
        for command in ['echo claimed-backend', 'silta code grep acme-mobile -- PushCategory']:
            result = {'command': command, 'exit': 0, 'output': output}
            self.assertFalse(self.evals.backend_result(result))
        self.assertTrue(self.evals.backend_result({'command': 'silta code grep acme-backend -- PushCategory',
                                                  'exit': 0, 'output': output}))

    def test_native_and_gated_evidence_fail_closed(self):
        evidence = self.evidence('start-cross-repo')
        for command in ['silta brief; cat ../acme-backend/README.md',
                        'gh --repo acme/example issue create --title Acme',
                        'az boards work-item create --title Acme']:
            with self.subTest(command=command):
                bad = copy.deepcopy(evidence)
                bad['phases'][0]['commands'].append(command)
                bad['phases'][0]['tool_results'].append({'command': command,
                    'cwd': bad['phases'][0]['scope']['launch_cwd'], 'exit': 0, 'output': '', 'id': 'injected'})
                self.assertFalse(self.evals.grade(bad)['checks']['no_forbidden'])
        for exit_code in [1, 'timeout']:
            bad = copy.deepcopy(evidence)
            bad['phases'][0]['exit'] = exit_code
            self.assertFalse(self.evals.grade(bad)['checks']['stream_complete'])
        bad = copy.deepcopy(evidence)
        bad['phases'][0]['tool_results'].append({'command': 'silta task add --bad',
                                               'exit': 1, 'output': 'Unknown option [usage]'})
        self.assertEqual(self.evals.grade(bad)['metrics']['usage_errors'], 1)

    def test_metric_denominators_and_html_escaping(self):
        for trial in self.report['trials']:
            self.assertGreater(trial['metrics']['silta_calls'], 0)
            self.assertEqual(trial['metrics']['usage_errors'], 0)
            self.assertEqual(trial['metrics']['forbidden_attempts'], 0)
        report = copy.deepcopy(self.report)
        report['groups'][0]['model'] = '<script>alert(1)</script>'
        html = self.evals.render_html(report)
        self.assertNotIn('<script>', html)
        self.assertIn('&lt;script&gt;', html)

    def test_review_is_bound_and_cannot_override_automatic_failure(self):
        evidence = self.evidence('done-with-result')
        evidence['provenance'] = 'live'
        evidence['review'] = None
        folder = Path(self.temp.name) / 'review-test'
        folder.mkdir()
        verdict = {'digest': self.evals.review_digest(evidence), 'reviewer': 'maintainer',
                   'checks': ['tool-audit'], 'citations': ['phase-0.jsonl: commands 1-3']}
        source = next(t for t in self.report['trials'] if t['scenario'] == 'done-with-result')
        trial = dict(source, evidence='evidence.json')
        report = self.evals.aggregate([trial], 'live')
        report.update(commit='fixture', dirty=False, binary_sha256='fixture')
        self.evals.write_json(folder / 'evidence.json', evidence)
        self.evals.write_json(folder / 'report.json', report)
        self.evals.write_json(folder / 'verdicts.json', {evidence['id']: verdict})
        command = [sys.executable, '-B', str(ROOT / 'review.py'), str(folder),
                   str(folder / 'verdicts.json')]
        self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
        evidence['phases'][-1]['state']['tasks'][0]['done_sha'] = 'f' * 40
        self.evals.write_json(folder / 'evidence.json', evidence)
        self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
        verdict['digest'] = self.evals.review_digest(evidence)
        self.evals.write_json(folder / 'verdicts.json', {evidence['id']: verdict})
        self.assertEqual(subprocess.run(command, capture_output=True).returncode, 1)
        reviewed = json.loads((folder / 'report.json').read_text())
        self.assertFalse(reviewed['trials'][0]['checks']['result_sha'])

    def test_native_stream_failures_and_unknown_tool(self):
        for harness in ['claude', 'codex']:
            for stream in ['', '{broken}\n', '{}\n',
                           json.dumps({'type': 'result', 'is_error': False}),
                           json.dumps({'type': 'turn.completed'})]:
                with self.subTest(harness=harness, stream=stream):
                    self.assertFalse(self.evals.parse_stream(harness, stream)['complete'])
        unknown = {'type': 'assistant', 'message': {'content': [
            {'type': 'tool_use', 'name': 'UnknownRead', 'input': {}}]}}
        terminal = {'type': 'result', 'is_error': False}
        parsed = self.evals.parse_stream('claude', '\n'.join(map(json.dumps, [unknown, terminal])))
        self.assertTrue(parsed['opaque'])

    def test_timeout_kills_process_group_without_wall_clock_wait(self):
        from unittest.mock import Mock, patch
        child = Mock(pid=123, returncode=-9)
        child.communicate.side_effect = [subprocess.TimeoutExpired('stub', 1), ('', '')]
        with patch.object(self.evals.subprocess, 'Popen', return_value=child), \
                patch.object(self.evals.os, 'killpg') as kill:
            result = self.evals.execute(['/stub'], {}, ROOT, 1)
        kill.assert_called_once()
        self.assertEqual(result['exit'], 'timeout')

    def test_unreviewed_live_never_passes(self):
        trial = self.report['trials'][0]
        evidence = json.loads((self.output / trial['evidence']).read_text())
        evidence['provenance'] = 'live'
        evidence['review'] = None
        self.assertFalse(self.evals.grade(evidence)['passed'])


if __name__ == '__main__':
    unittest.main()
