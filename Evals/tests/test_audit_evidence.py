"""Audit must retain evidence needed to certify behavior without model claims."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import evals


class AuditEvidence(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='silta-audit-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.trial = self.root / 'fixture'
        self.trial.mkdir()

    def evidence(self, harness='codex'):
        tools = [('tool-0', 'printf hidden', 'OPAQUE_PROGRAM_READ_BACKEND_SECRET_SENTINEL'),
                 ('tool-1', 'printf long', 'START' + 'x' * 5000 + 'MIDDLE_UNSEEN_SENTINEL' + 'x' * 5000 + 'HIDDEN_OUTPUT_TAIL')]
        if harness == 'codex':
            events = [{'type': 'thread.started', 'thread_id': 'a'},
                      {'type': 'item.completed', 'item': {'type': 'agent_message', 'text': 'BEFORE_TOOL'}}]
            for identifier, command, output in tools:
                events += [{'type': 'item.started', 'item': {'id': identifier, 'type': 'command_execution', 'command': command}},
                           {'type': 'item.completed', 'item': {'id': identifier, 'type': 'command_execution', 'command': command,
                                                              'exit_code': 0, 'aggregated_output': output}}]
            events += [{'type': 'item.completed', 'item': {'type': 'agent_message', 'text': 'AFTER_TOOL'}},
                       {'type': 'item.started', 'item': {'type': 'file_change', 'id': 'file', 'changes': [{'path': 'transient.txt', 'kind': 'add'}]}},
                       {'type': 'item.completed', 'item': {'type': 'file_change', 'id': 'file', 'status': 'completed',
                                                        'changes': [{'path': 'transient.txt', 'kind': 'delete'}]}},
                       {'type': 'turn.completed', 'usage': {'input_tokens': 10, 'output_tokens': 5}}]
        else:
            events = [{'type': 'system', 'session_id': 'a'},
                      {'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'BEFORE_TOOL'}]}}]
            for identifier, command, output in tools:
                events += [{'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'id': identifier, 'name': 'Bash', 'input': {'command': command}}]}},
                           {'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': identifier, 'content': output, 'is_error': False}]}}]
            events += [{'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'AFTER_TOOL'},
                       {'type': 'tool_use', 'id': 'file', 'name': 'Write', 'input': {'file_path': 'transient.txt', 'content': 'temporary'}}]}},
                       {'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'file', 'content': 'Unverified file write', 'is_error': False}]}},
                       {'type': 'result', 'is_error': False}]
        stream = '\n'.join(json.dumps(event) for event in events) + '\n'
        (self.trial / 'phase-0.jsonl').write_text(stream)
        state = {'tasks': [{'id': 'task', 'plan_md': 'STORED_PLAN_BODY', 'result_md': 'STORED_RESULT_BODY'}],
                 'plans': [{'id': 'plan', 'body_md': 'STDIN_PLAN_BODY'}],
                 'comments': [{'id': 'comment', 'body_md': 'STDIN_COMMENT_BODY'}],
                 'approvals': [{'id': 'approval', 'words': 'BOUND_APPROVAL_WORDS'}],
                 'events': [{'id': 'event', 'kind': 'claim'}], 'files': {'intermediate.txt': 'created-hash'}}
        phase = dict(evals.parse_stream(harness, stream), actor='agent:fixture', exit=0, all_logs=[], logs=[], state=state,
                     transcript_sha256=hashlib.sha256(stream.encode()).hexdigest())
        e = {'id': 'fixture', 'harness': harness, 'scenario': 'plan-not-file', 'variant': 'default',
             'baseline': {key: {} if key == 'files' else [] for key in state}, 'phases': [phase], 'review': None}
        second = dict(phase, state=dict(state, files={}), commands=[], tool_results=[], opaque=[], messages=[])
        second_stream = json.dumps({'type': 'thread.started', 'thread_id': 'b'}) + '\n' if harness == 'codex' else json.dumps({'type': 'system', 'session_id': 'b'}) + '\n'
        (self.trial / 'phase-1.jsonl').write_text(second_stream)
        second['transcript_sha256'] = hashlib.sha256(second_stream.encode()).hexdigest()
        e['phases'].append(second)
        return e

    def audit(self, evidence):
        evals.write_json(self.trial / 'evidence.json', evidence)
        evals.write_json(self.root / 'report.json', {'trials': [{'id': 'fixture', 'model': 'fixture', 'evidence': 'fixture/evidence.json',
                         'metrics': {'tokens': 15}, 'checks': {'evidence_review': False}}]})
        result = subprocess.run([sys.executable, '-B', str(ROOT / 'audit.py'), str(self.root)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_audit_exposes_outputs_full_state_order_and_intermediate_files(self):
        for harness in ('claude', 'codex'):
            with self.subTest(harness=harness):
                output = self.audit(self.evidence(harness))
                for expected in ['OPAQUE_PROGRAM_READ_BACKEND_SECRET_SENTINEL', 'STORED_PLAN_BODY', 'STDIN_PLAN_BODY',
                                 'STDIN_COMMENT_BODY', 'STORED_RESULT_BODY', 'BOUND_APPROVAL_WORDS',
                                 'phase-0/tool-0', 'phase-0/tool-1', 'fixture/phase-0.jsonl:',
                                 'fixture/evidence.json#/phases/0', 'intermediate.txt', 'created-hash',
                                 'transient.txt', 'OPAQUE', 'UNRESOLVED', 'TRUNCATED', 'omitted=']:
                    self.assertIn(expected, output)
                self.assertLess(output.index('BEFORE_TOOL'), output.index('OPAQUE_PROGRAM_READ_BACKEND_SECRET_SENTINEL'))
                self.assertLess(output.index('OPAQUE_PROGRAM_READ_BACKEND_SECRET_SENTINEL'), output.index('AFTER_TOOL'))
                self.assertNotIn('MIDDLE_UNSEEN_SENTINEL', output)
                self.assertIn('phase-1/files', output)
                self.assertIn('SNAPSHOT after phase-0/tool-2', output)
                self.assertIn('FINAL FILE', output)

    def test_transcript_hash_binds_actual_trial_order_for_review(self):
        e = self.evidence()
        self.assertEqual(e['phases'][0]['transcript_sha256'], hashlib.sha256((self.trial / 'phase-0.jsonl').read_bytes()).hexdigest())
        output = self.audit(e)
        self.assertNotIn('unbound or changed transcript', output)
        e['phases'][0].pop('transcript_sha256')
        self.assertIn('unbound or changed transcript', self.audit(e))

    def test_changed_raw_and_retained_observations_remain_visible_and_unresolved(self):
        e = self.evidence()
        e['phases'][0]['tool_results'][0]['output'] = 'RETAINED_OUTPUT_SENTINEL'
        e['phases'][0]['messages'][0] = 'RETAINED_MESSAGE_SENTINEL'
        (self.trial / 'phase-0.jsonl').write_text((self.trial / 'phase-0.jsonl').read_text().replace('BEFORE_TOOL', 'RAW_CHANGED_MESSAGE'))
        output = self.audit(e)
        for expected in ['RETAINED_OUTPUT_SENTINEL', 'RETAINED_MESSAGE_SENTINEL', 'RAW_CHANGED_MESSAGE',
                         'UNRESOLVED', 'transcript', 'tool_results/0', 'messages/0']:
            self.assertIn(expected, output)

    def test_missing_native_exit_is_unknown_instead_of_success(self):
        e = self.evidence()
        transcript = self.trial / 'phase-0.jsonl'
        events = [json.loads(line) for line in transcript.read_text().splitlines()]
        completion = next(event['item'] for event in events if event.get('type') == 'item.completed'
                          and event.get('item', {}).get('id') == 'tool-0')
        completion.pop('exit_code')
        transcript.write_text('\n'.join(json.dumps(event) for event in events) + '\n')
        output = self.audit(e)
        self.assertRegex(output, r'phase-0/tool-0[^\n]*COMPLETED exit=unknown')

    def test_missing_raw_and_missing_tool_result_are_unresolved(self):
        e = self.evidence()
        e['phases'][0]['tool_results'].pop(0)
        (self.trial / 'phase-0.jsonl').unlink()
        output = self.audit(e)
        self.assertIn('UNRESOLVED', output)
        self.assertIn('phase-0/tool-0', output)
        self.assertIn('BEFORE_TOOL', output)
        self.assertIn('phase-0.jsonl', output)


if __name__ == '__main__':
    unittest.main()
