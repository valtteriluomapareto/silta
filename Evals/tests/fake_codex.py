#!/usr/bin/env python3
"""Offline Codex stand-in: validates generated config, simulates shell filtering."""
import fnmatch
import json
import os
from pathlib import Path
import subprocess
import sys
import tomllib

root = Path(__file__).resolve().parents[1]
args = sys.argv[1:]
model_index = args.index('--model') + 1
_, scenario, variant, recording, behavior = args[model_index].split(':')
key = os.environ['FIREWORKS_API_KEY']
assert key.startswith('fake-si63-'), 'Only fake credentials permitted'
config = tomllib.loads((Path(os.environ['CODEX_HOME']) / 'config.toml').read_text())
assert config['model_provider'] == 'fireworks'
assert config['model_providers']['fireworks'] == {
    'name': 'Fireworks', 'base_url': 'https://api.fireworks.ai/inference/v1',
    'env_key': 'FIREWORKS_API_KEY', 'wire_api': 'responses'}
assert config['model_reasoning_effort'] == 'high'
assert key not in json.dumps(config)
excludes = config['shell_environment_policy']['exclude']
shell_env = {k: v for k, v in os.environ.items()
             if not any(fnmatch.fnmatchcase(k, pattern) for pattern in excludes)}
probe = subprocess.run(['/bin/sh', '-c', 'test -z "${FIREWORKS_API_KEY+x}"'], env=shell_env)
assert probe.returncode == 0, 'Key reached simulated agent shell'
phase = int('resume' in args or os.environ['SILTA_ACTOR'].endswith('-b'))
trial = Path(os.environ['HOME']).parent
if behavior == 'overflow':
    sessions = Path(os.environ['CODEX_HOME']) / 'sessions'
    sessions.mkdir(exist_ok=True)
    (sessions / 'native.jsonl').write_text(json.dumps({'type': 'event_msg', 'payload': {
        'type': 'token_count', 'info': {'total_token_usage': {'input_tokens': 60, 'output_tokens': 40}}}}) + '\n')
    print(json.dumps({'type': 'thread.started', 'thread_id': 'overflow'}), flush=True)
    # A pipe with its writer held open stays blocked until the supervisor kills us.
    read_fd, write_fd = os.pipe()
    os.read(read_fd, 1)
    raise AssertionError('Budget supervisor failed to stop blocked client')
args[model_index] = 'recorded-stub'
shell_env.update(SI_EVAL_HARNESS='codex', SI_EVAL_SCENARIO=scenario, SI_EVAL_VARIANT=variant,
                 SI_EVAL_RECORDING=recording, SI_EVAL_PHASE=str(phase),
                 SI_EVAL_SHA=(trial / 'fixture-sha.txt').read_text().strip() if (trial / 'fixture-sha.txt').exists()
                 else subprocess.check_output(['git', 'rev-parse', 'HEAD'], env=shell_env, text=True).strip())
if phase and variant.startswith('present-'):
    shell_env['SI_EVAL_APPROVAL'] = args[-1]
result = subprocess.run([sys.executable, '-B', str(root / 'tests/stub_harness.py'), *args],
                        env=shell_env, text=True, capture_output=True)
if behavior == 'contaminate':
    import sqlite3
    with sqlite3.connect(trial / 'data/silta.db') as db:
        db.execute('UPDATE task SET title = ? WHERE seq = 1', (key,))
for line in result.stdout.splitlines():
    event = json.loads(line)
    if event['type'] == 'turn.completed':
        if behavior == 'echo':
            print(json.dumps({'type': 'item.completed', 'item': {'type': 'agent_message',
                  'text': 'Echo: ' + key + ' Config: ' + json.dumps(config)}}))
        if behavior == 'missing-usage':
            event.pop('usage', None)
    print(json.dumps(event), flush=True)
if behavior == 'echo':
    print('Native stderr echo: ' + key, file=sys.stderr)
print(result.stderr, end='', file=sys.stderr)
sys.exit(result.returncode)
