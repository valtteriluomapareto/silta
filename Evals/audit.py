#!/usr/bin/env python3
"""Print a compact digest of retained eval evidence for an independent reviewer."""
import argparse
import json
from pathlib import Path
import evals


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', type=Path)
    args = parser.parse_args()
    report = json.loads((args.results / 'report.json').read_text())
    for trial in report['trials']:
        path = args.results / trial['evidence']
        evidence = json.loads(path.read_text())
        print('\nTRIAL', trial['id'], 'evidence=' + trial['evidence'])
        print('provider=', evidence.get('provider'), 'model=', trial['model'],
              'operator=', evidence.get('operator'), 'source=', (evidence.get('approval') or {}).get('source'),
              'reviewer=', (evidence.get('review') or {}).get('reviewer'))
        print('digest=', evals.review_digest(evidence), 'tokens=', trial['metrics'].get('tokens'))
        failed = [key for key, passed in trial['checks'].items() if not passed and key != 'evidence_review']
        print('automatic failures=', failed, 'review=', trial['checks'].get('evidence_review', 'unavailable'),
              'error=', trial.get('error'))
        for phase in evidence.get('phases', []):
            print('PHASE', phase['actor'], 'exit=' + str(phase['exit']))
            for log in phase['all_logs']:
                print('SILTA', log['command'], 'exit=' + str(log['exit_code']))
            unmatched = list(phase['tool_results'])
            for command in phase['commands']:
                match = next((i for i, item in enumerate(unmatched) if item['command'] == command), None)
                item = unmatched.pop(match) if match is not None else None
                print('SHELL', json.dumps(command), 'exit=' + str(item['exit'] if item else 'unmatched'))
            for item in unmatched:
                print('ORPHAN SHELL RESULT', json.dumps(item['command']), 'exit=' + str(item['exit']))
            for tool in phase['opaque']:
                print('OPAQUE/NATIVE TOOL', json.dumps(tool, sort_keys=True))
            if evidence.get('scenario') in ('proposals-ask', 'ask-short'):
                for message in phase['messages']:
                    print('MESSAGE', json.dumps(message))
        if evidence.get('phases'):
            before = evidence['baseline']['files']
            after = evidence['phases'][-1]['state']['files']
            for name in sorted(before.keys() | after.keys()):
                if before.get(name) != after.get(name):
                    print('FILE', json.dumps(name), before.get(name), '->', after.get(name))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
