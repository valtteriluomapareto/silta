#!/usr/bin/env python3
"""Sequential unattended Fireworks runs; preserves every model's process status."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--silta', type=Path, required=True)
    parser.add_argument('--client', type=Path, required=True)
    parser.add_argument('--models', nargs='+', required=True)
    parser.add_argument('--output', type=Path, default=ROOT.parent / 'artifacts/evals/open')
    parser.add_argument('--max-trial-tokens', type=int, required=True)
    parser.add_argument('--repeats', type=int, default=1)
    parser.add_argument('--core', action='store_true')
    args = parser.parse_args(argv)
    slugs = [re.sub(r'[^A-Za-z0-9_-]', '-', model.rsplit('/', 1)[-1]) for model in args.models]
    if args.max_trial_tokens < 1 or args.repeats < 1 or len(set(slugs)) != len(slugs) or args.output.exists():
        parser.error('positive cap/repeats, distinct model slugs and absent output required')
    args.output.mkdir(parents=True)
    models = []
    for model, slug in zip(args.models, slugs):
        output = args.output / slug
        command = [sys.executable, '-B', str(ROOT / 'evals.py'), '--silta', str(args.silta.resolve()),
                   '--live', '--harness', 'codex', '--client', str(args.client.resolve()), '--model', model,
                   '--provider', 'fireworks', '--operator', 'scripted', '--max-trial-tokens', str(args.max_trial_tokens),
                   '--repeats', str(args.repeats), '--output', str(output)]
        if args.core:
            command.append('--core')
        result = subprocess.run(command)
        report_path = output / 'report.json'
        try:
            report = json.loads(report_path.read_text()) if report_path.exists() else {}
        except (OSError, ValueError):
            report = {}
        models.append({'model': model, 'output': str(output), 'exit': result.returncode,
                       'tokens': report.get('tokens') if isinstance(report, dict) else None,
                       'unknown_token_trials': report.get('unknown_token_trials') if isinstance(report, dict) else None})
        (args.output / 'matrix.json').write_text(json.dumps({'models': models}, indent=2) + '\n')
    return 0 if all(m['exit'] == 0 for m in models) else 1


if __name__ == '__main__':
    sys.exit(main())
