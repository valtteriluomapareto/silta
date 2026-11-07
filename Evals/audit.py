#!/usr/bin/env python3
"""Render bound eval evidence and ordered native observations for a reviewer."""
import argparse
import hashlib
import json
from pathlib import Path
import evals

OUTPUT_LIMIT = 2000
TABLES = ('tasks', 'plans', 'comments', 'approvals', 'events')


def observations(harness, event):
    kind = event.get('type')
    if harness == 'codex' and kind in ('item.started', 'item.updated', 'item.completed'):
        item = event['item']
        if item['type'] == 'agent_message' and kind == 'item.completed':
            yield 'message', item['text']
        elif item['type'] != 'reasoning':
            yield kind.split('.')[1], item
    elif harness == 'claude' and kind in ('assistant', 'user'):
        for block in event['message']['content']:
            if kind == 'assistant' and block['type'] == 'text':
                yield 'message', block['text']
            elif block['type'] == 'tool_use':
                yield 'started', dict(block, type=block['name'])
            elif block['type'] == 'tool_result':
                yield 'completed', dict(block, id=block['tool_use_id'])


def render_trial(directory, trial):
    path = directory / trial['evidence']
    e = json.loads(path.read_text())
    unresolved = []

    def issue(where, reason):
        unresolved.append(where)
        print('UNRESOLVED', where, reason)

    def excerpt(value, where):
        text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
        if len(text) > OUTPUT_LIMIT:
            omitted = len(text) - OUTPUT_LIMIT
            issue(where, f'TRUNCATED omitted={omitted}; inspect complete output before certification')
            text = text[:1500] + f'\n[TRUNCATED omitted={omitted}]\n' + text[-500:]
        return text

    print('\nTRIAL', trial['id'], 'evidence=' + trial['evidence'])
    print('provider=', e.get('provider'), 'model=', trial['model'], 'operator=', e.get('operator'),
          'source=', (e.get('approval') or {}).get('source'), 'reviewer=', (e.get('review') or {}).get('reviewer'))
    print('SCENARIO', e.get('scenario'), 'variant=', e.get('variant'), 'repeat=', e.get('repeat'), 'expected_sha=', e.get('sha'))
    settings = e.get('controls', {}).get('tiny', {}).get('data', {}).get('settings', {})
    print(trial['evidence'] + '#/controls/tiny/data/settings', 'POLICY SETTINGS', json.dumps(settings))
    print('digest=', evals.review_digest(e), 'tokens=', trial['metrics'].get('tokens'))
    print('automatic failures=', [k for k, v in trial['checks'].items() if not v and k != 'evidence_review'],
          'review=', trial['checks'].get('evidence_review', 'unavailable'), 'error=', trial.get('error'))
    if e.get('approval'):
        print('APPROVAL', trial['evidence'] + '#/approval', json.dumps(e['approval'], sort_keys=True))
    if not e.get('phases'):
        issue(trial['evidence'], 'no phase evidence; effects cannot be established')
    before = e.get('baseline', {})
    print('BASELINE', trial['evidence'] + '#/baseline', json.dumps(before, ensure_ascii=False))
    for number, phase in enumerate(e.get('phases', [])):
        prefix = f'phase-{number}'
        bound = trial['evidence'] + f'#/phases/{number}'
        raw_path = path.parent / (prefix + '.jsonl')
        source = str(raw_path.relative_to(directory))
        print('PHASE', prefix, phase['actor'], 'exit=' + str(phase['exit']),
              'process_exit=' + str(phase.get('process_exit', phase['exit'])))
        try:
            raw = raw_path.read_bytes()
        except OSError:
            raw = b''
            issue(source, 'missing native transcript; observation order cannot be established')
        if not phase.get('transcript_sha256') or hashlib.sha256(raw).hexdigest() != phase['transcript_sha256']:
            issue(bound + '/transcript_sha256', 'unbound or changed transcript; raw order/content is unverified: ' + source)
        parsed = evals.parse_stream(e['harness'], raw.decode(errors='replace'))
        for field in ('commands', 'messages', 'tool_results', 'opaque'):
            if parsed[field] != phase.get(field, []):
                issue(bound + '/' + field, 'raw/retained disagreement; both observations require investigation')
                for index, value in enumerate(phase.get(field, [])):
                    alias = f'{prefix}/tool-{index}' if field == 'commands' else f'{prefix}/retained-{field}-{index}'
                    print(alias, 'RETAINED', bound + f'/{field}/{index}', excerpt(value, bound + f'/{field}/{index}'))
        if not phase.get('complete') or not parsed['complete']:
            issue(bound, 'native lifecycle incomplete; tool effects cannot be certified')
        tools, pending = {}, set()
        tool_count = message_count = 0
        for line_number, line in enumerate(raw.decode(errors='replace').splitlines(), 1):
            locator = f'{source}:{line_number}'
            try:
                entries = list(observations(e['harness'], json.loads(line)))
            except (ValueError, KeyError, TypeError, AttributeError):
                issue(locator, 'unparsed native observation: ' + excerpt(line, locator))
                continue
            for kind, item in entries:
                if kind == 'message':
                    print(f'[{prefix}/message-{message_count} {locator} {bound}/messages/{message_count}] MESSAGE', item)
                    message_count += 1
                    continue
                identifier = item.get('id')
                if not isinstance(identifier, str) or not identifier:
                    issue(locator, 'missing/invalid native tool id')
                    identifier = f'unmatched-{line_number}-{tool_count}'
                if kind == 'started' or identifier not in tools:
                    if identifier in tools:
                        issue(locator, 'duplicate native tool id: ' + str(identifier))
                    tools[identifier] = (tool_count, item)
                    tool_count += 1
                    if kind != 'started':
                        issue(locator, 'orphan native tool completion/update')
                    pending.add(identifier)
                index, start = tools[identifier]
                result_index = next((i for i, result in enumerate(phase['tool_results']) if result['id'] == identifier), None)
                command = start.get('command', start.get('input', {}).get('command'))
                if result_index is not None:
                    retained = bound + f'/tool_results/{result_index}'
                elif command is not None and command in phase['commands']:
                    retained = bound + f"/commands/{phase['commands'].index(command)}"
                else:
                    opaque_index = next((i for i, tool in enumerate(phase['opaque']) if tool == item or tool.get('id') == identifier), None)
                    retained = bound + (f'/opaque/{opaque_index}' if opaque_index is not None else '/opaque')
                citation = f'[{prefix}/tool-{index} id={identifier} {locator} {retained}]'
                if kind == 'started':
                    label = 'SHELL' if command is not None else 'OPAQUE/NATIVE TOOL'
                    print(citation, label, excerpt(command if command is not None else start, locator))
                    if command is None:
                        issue(citation, 'opaque/native tool effects require investigation')
                    else:
                        argv = evals.trace_argv(command)
                        if not argv or Path(argv[0]).name != 'silta':
                            issue(citation, 'shell/program effects beyond output and snapshots are unverified')
                else:
                    if kind == 'completed':
                        pending.discard(identifier)
                    output = item.get('aggregated_output', item.get('content', item))
                    if kind != 'completed':
                        code = 'pending'
                    elif e['harness'] == 'claude':
                        error = item.get('is_error', False)
                        code = int(error) if type(error) is bool else 'unknown'
                    else:
                        code = item.get('exit_code', 'unknown')
                    print(citation, kind.upper(), 'exit=' + str(code), 'OUTPUT', excerpt(output, locator + ' ' + retained))
                    if command is not None and 'aggregated_output' not in item and 'content' not in item:
                        issue(citation, 'tool output not recorded')
                for change in item.get('changes', []):
                    print(citation, 'TRACE FILE reported/unverified', excerpt(change, locator))
                if item.get('type') in ('Write', 'Edit', 'MultiEdit'):
                    print(citation, 'TRACE FILE reported/unverified', excerpt(item.get('input', {}), locator))
        for identifier in pending:
            issue(prefix + '/tool-' + str(tools[identifier][0]), 'missing completion/output for ' + str(identifier))
        for index, log in enumerate(phase['all_logs']):
            print(bound + f'/all_logs/{index}', 'SILTA', log['command'], 'exit=' + str(log['exit_code']))
        boundary = f'SNAPSHOT after {prefix}/tool-{tool_count - 1}' if tool_count else f'SNAPSHOT {prefix}/no-tools'
        print(boundary, bound + '/state')
        state = phase['state']
        for table in TABLES:
            old = {row['id']: row for row in before.get(table, [])}
            new = {row['id']: row for row in state.get(table, [])}
            for index, row in enumerate(state.get(table, [])):
                if old.get(row['id']) != row:
                    print(boundary, bound + f'/state/{table}/{index}', 'STATE CHANGE', json.dumps(row, ensure_ascii=False))
            for identifier in old.keys() - new.keys():
                print(boundary, bound + '/state/' + table, 'STATE REMOVED', json.dumps(old[identifier], ensure_ascii=False))
        files(before.get('files', {}), state['files'], prefix + '/files ' + boundary + ' ' + bound + '/state/files', 'FILE')
        before = state
    if e.get('phases'):
        final = e['phases'][-1]['state']
        for table in TABLES:
            for index, row in enumerate(final.get(table, [])):
                print(boundary, trial['evidence'] + f"#/phases/{len(e['phases']) - 1}/state/{table}/{index}", 'FINAL ' + table, json.dumps(row, ensure_ascii=False))
        files(e['baseline']['files'], final['files'], trial['evidence'] + '#/baseline/files -> ' + trial['evidence'] + f"#/phases/{len(e['phases']) - 1}/state/files", 'FINAL FILE')
    print('UNRESOLVED COUNT', len(unresolved), ': investigate every unresolved observation before certifying tool-audit or policy-semantics')


def files(before, after, citation, label):
    changed = False
    for name in sorted(before.keys() | after.keys()):
        if before.get(name) != after.get(name):
            changed = True
            print(citation, label, json.dumps(name), before.get(name), '->', after.get(name))
    if not changed:
        print(citation, label, 'no snapshot changes; transient shell effects between snapshots are unverified')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', type=Path)
    args = parser.parse_args()
    report = json.loads((args.results / 'report.json').read_text())
    for trial in report['trials']:
        render_trial(args.results, trial)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
