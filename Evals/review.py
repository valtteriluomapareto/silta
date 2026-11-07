#!/usr/bin/env python3
"""Apply maintainer evidence verdicts; automatic failures cannot be overridden."""
import argparse
import json
from pathlib import Path
import evals

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('results', type=Path)
parser.add_argument('verdicts', type=Path)
args = parser.parse_args()
report = json.loads((args.results / 'report.json').read_text())
verdicts = json.loads(args.verdicts.read_text())
for trial in report['trials']:
    verdict = verdicts.get(trial['id'])
    if verdict is None or 'infrastructure' in trial['checks']:
        continue
    evidence_path = args.results / trial['evidence']
    evidence = json.loads(evidence_path.read_text())
    if (verdict.get('digest') != evals.review_digest(evidence)
            or not verdict.get('reviewer') or not verdict.get('citations')
            or verdict.get('reviewer') == 'recorded-stub-oracle'):
        raise SystemExit('Unbound/unsigned/uncited verdict: ' + trial['id'])
    evidence['review'] = verdict
    evals.write_json(evidence_path, evidence)
    trial.update(evals.grade(evidence))
    trial.update(evals.trial_labels(evidence))
updated = evals.aggregate(report['trials'], report['provenance'])
updated.update({key: report[key] for key in ('commit', 'dirty', 'binary_sha256')})
updated.update({key: report[key] for key in evals.RUN_FIELDS if key in report})
evals.write_json(args.results / 'report.json', updated)
(args.results / 'report.html').write_text(evals.render_html(updated))
raise SystemExit(0 if not updated.get('aborted', False) and all(t['passed'] for t in updated['trials']) else 1)
