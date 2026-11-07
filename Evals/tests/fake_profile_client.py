#!/usr/bin/env python3
"""Fake native client for run-profile isolation; never connects to a model."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import evals

journal, harness, mode, *args = sys.argv[1:]
journal = Path(journal)
profile = Path(os.environ['CODEX_HOME' if harness == 'codex' else 'CLAUDE_CONFIG_DIR'])
auth = profile / ('auth.json' if harness == 'codex' else '.credentials.json')


def record(value):
    with journal.open('a') as output:
        output.write(json.dumps(value) + '\n')


login = args == ['login'] if harness == 'codex' else args in ([], ['auth', 'login'])
logout = args == ['logout'] if harness == 'codex' else args == ['auth', 'logout']
if login:
    profile.mkdir(parents=True, exist_ok=True)
    if harness == 'claude':
        (profile / '.claude.json').write_text('{"hasCompletedOnboarding":true}\n')
    auth.touch()
    auth.chmod(0)
    config = profile / ('config.toml' if harness == 'codex' else '.claude.json')
    if mode in ('symlink-auth', 'hardlink-auth'):
        config.unlink(missing_ok=True)
        if mode == 'symlink-auth':
            config.symlink_to(auth)
        else:
            os.link(auth, config)
    if mode == 'unexpected-grant' and harness == 'codex':
        with config.open('a') as output:
            output.write('\n[sandbox_workspace_write]\nwritable_roots=["/acme/unexpected"]\n')
    info = {'event': 'login', 'profile': str(profile), 'home': os.environ['HOME'],
            'cwd': os.getcwd(), 'auth_inode': auth.stat().st_ino}
    record(info)
    print(json.dumps(info))
    sys.exit(0)
if logout:
    record({'event': 'logout', 'profile': str(profile), 'cwd': os.getcwd()})
    auth.unlink(missing_ok=True)
    sys.exit(0)
assert '--model' in args and args[args.index('--model') + 1] == 'fixture-profile', 'Only fixture model allowed'
assert auth.exists(), 'Fake profile was not signed in'
actor = os.environ['SILTA_ACTOR']
trial_root = Path.cwd().parent.parent
home = trial_root / 'home'
data = Path(os.environ['SILTA_HOME'])
assert data == trial_root / 'data'
previous = [json.loads(line) for line in journal.read_text().splitlines()]
old = next((item for item in reversed(previous) if item['event'] == 'model' and item['trial'] != str(trial_root)), None)
config = profile / ('config.toml' if harness == 'codex' else 'settings.json')
config_text = config.read_text()
grants = tomllib.loads(config_text).get('sandbox_workspace_write', {}).get('writable_roots', []) if harness == 'codex' else []
state = {'event': 'model', 'profile': str(profile), 'home': os.environ['HOME'], 'trial': str(trial_root),
         'data': str(data), 'actor': actor, 'auth_inode': auth.stat().st_ino,
         'auth_mode': auth.stat().st_mode & 0o777, 'grants': grants,
         'old_data_exists': bool(old and Path(old['data']).exists()),
         'old_hook_exists': bool(old and (Path(old['data']) / 'log/hook-sentinel').exists()),
         'old_runtime_exists': bool(old and (profile / 'projects/previous-trial').exists()),
         'old_session_exists': bool(old and (profile / 'sessions' / (old['actor'].split(':')[-1] + '.jsonl')).exists()),
         'old_config': bool(old and 'PRIVATE_TRIAL_CONFIG' in config_text),
         'real_config': 'REAL_PROFILE_SENTINEL' in config_text}
record(state)
if mode == 'cancel':
    with journal.with_suffix('.signal').open('w') as signal_file:
        signal_file.write(str(os.getpid()) + '\n')
    read_end, write_end = os.pipe()
    os.read(read_end, 1)
phase = int('resume' in args or '--resume' in args or actor.endswith('-b'))
scenario_actor = actor.split(':', 2)[-1].removeprefix(harness + '-')
scenario = next(s for s in evals.SCENARIOS if scenario_actor.startswith(s + '-'))
variant = scenario_actor.removeprefix(scenario + '-').rsplit('-', 2)[0]
sha = (Path.cwd() / '.git/refs/heads/feature/push').read_text().strip()
session = actor.split(':')[-1]
conversation = profile.parent.parent.name + '-' + session
if 'resume' in args:
    conversation = args[-2]
if '--resume' in args:
    conversation = args[args.index('--resume') + 1]


def emit(value):
    print(json.dumps(value), flush=True)


def message(text):
    emit({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': text}]}} if harness == 'claude'
         else {'type': 'item.completed', 'item': {'type': 'agent_message', 'text': text}})


def hook(event):
    if harness != 'claude':
        return
    settings = json.loads((profile / 'settings.json').read_text())
    command = settings['hooks'][event][0]['hooks'][0]['command']
    env_file = profile / 'session-env' / (session + '.env')
    env_file.parent.mkdir(exist_ok=True)
    run = subprocess.run(['/bin/sh', '-c', command], env=dict(os.environ, CLAUDE_ENV_FILE=str(env_file)),
                         input=json.dumps({'session_id': session, 'stop_hook_active': False}), text=True, capture_output=True)
    record({'event': event, 'trial': str(trial_root), 'data': str(data), 'actor': actor,
            'exit': run.returncode, 'output': run.stdout, 'env_file': str(env_file),
            'exported': env_file.read_text() if env_file.exists() else ''})


hook('SessionStart')
emit({'type': 'system', 'session_id': conversation} if harness == 'claude'
     else {'type': 'thread.started', 'thread_id': conversation})
recording = json.loads((ROOT / 'tests/recordings' / (scenario + '-pass.json')).read_text())
for index, action in enumerate(recording['phases'][phase]):
    if 'message' in action:
        message(action['message'])
        continue
    if 'proposal' in action:
        proposal = evals.proposal_command(variant, trial_root)
        if not phase:
            message('May I add the Acme retry fix? Exact command: ' + shlex.join(proposal))
            continue
        prompt = args[args.index('-p') + 1] if harness == 'claude' else args[-1]
        argv, stdin = [*proposal, '--approved', prompt], None
    else:
        argv = ['silta', '--ws', 'acme', *[value.format(sha=sha) for value in action['args']]]
        stdin = action.get('stdin')
    command = shlex.join(argv)
    identifier = 'tool-' + str(index)
    emit({'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'id': identifier, 'name': 'Bash', 'input': {'command': command}}]}}
         if harness == 'claude' else {'type': 'item.started', 'item': {'id': identifier, 'type': 'command_execution', 'command': command}})
    run = subprocess.run(argv, input=stdin, text=True, capture_output=True)
    emit({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': identifier,
           'content': run.stdout + run.stderr, 'is_error': run.returncode != 0}]}}
         if harness == 'claude' else {'type': 'item.completed', 'item': {'id': identifier, 'type': 'command_execution', 'command': command,
         'exit_code': run.returncode, 'aggregated_output': run.stdout + run.stderr}})
    assert run.returncode == 0, run.stdout + run.stderr
hook('Stop')
(profile / 'projects').mkdir(exist_ok=True)
(profile / 'projects/previous-trial').write_text('PRIVATE_TRIAL_HISTORY')
(data / 'log/hook-sentinel').write_text('PRIVATE_HOOK_STATE')
if harness == 'codex':
    if 'PRIVATE_TRIAL_CONFIG' not in config.read_text():
        with config.open('a') as output:
            output.write('\n[projects.' + json.dumps(str(Path.cwd())) + ']\ntrust_level="trusted"\n# PRIVATE_TRIAL_CONFIG\n')
else:
    settings = json.loads(config.read_text())
    settings['privateTrialState'] = 'PRIVATE_TRIAL_CONFIG'
    config.write_text(json.dumps(settings))
if mode == 'unknown':
    (profile / 'unknown-opaque').touch()
if mode == 'runtime-link':
    (profile / 'cache').symlink_to(journal.parent / 'real', target_is_directory=True)
if mode == 'corrupt':
    target = profile / ('AGENTS.md' if harness == 'codex' else 'CLAUDE.md')
    target.write_text(target.read_text().replace('Read `silta brief`', 'Altered `silta brief`'))
count = 2 if phase and ('resume' in args or '--resume' in args) else 1
if harness == 'codex':
    (profile / 'sessions').mkdir(exist_ok=True)
    (profile / 'sessions' / (session + '.jsonl')).write_text('\n'.join(map(json.dumps, [
        {'type': 'session_meta', 'payload': {'id': conversation}},
        {'type': 'event_msg', 'payload': {'type': 'token_count', 'info': {
            'total_token_usage': {'input_tokens': 10 * count, 'output_tokens': 5 * count}}}}])) + '\n')
emit({'type': 'result', 'is_error': False, 'usage': {'input_tokens': 10, 'output_tokens': 5}} if harness == 'claude'
     else {'type': 'turn.completed', 'usage': {'input_tokens': 10 * count, 'output_tokens': 5 * count}})
sys.exit(7 if mode == 'nonzero' else 0)
