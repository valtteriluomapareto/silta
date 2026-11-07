"""Run-scoped native authentication, with disposable per-trial installations."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import sys
import tempfile
import tomllib


class RunProfile:
    def __init__(self, harness, client, output, isolated_env, execute):
        # /tmp is an allowed ENV_FILE anchor for the real installed Claude hook.
        self.root = Path(tempfile.mkdtemp(prefix='silta-eval-profile-', dir='/tmp')).resolve()
        (output / 'profile-location.txt').write_text(str(self.root) + '\n')
        self.harness, self.output, self.execute = harness, output, execute
        self.env = isolated_env(self.root)
        self.home = Path(self.env['HOME'])
        self.directory = self.home / ('.codex' if harness == 'codex' else '.claude')
        self.directory.mkdir()
        self.configs = ([self.directory / 'config.toml'] if harness == 'codex' else
                        [self.directory / 'settings.json', self.directory / '.claude.json', self.home / '.claude.json'])
        if harness == 'codex':
            self.configs[0].write_text('cli_auth_credentials_store = "file"\n')
        self.baseline = {}
        self.context = None
        self.retained = []
        cwd = self.root / 'acme-login'
        cwd.mkdir()
        login_env = dict(self.env)
        if harness == 'claude':
            login_env['CLAUDE_CODE_TMPDIR'] = self.env['TMPDIR']
        if harness == 'claude' and sys.platform == 'darwin':
            login_env['HOME'] = os.environ['HOME']
            login_env['USER'] = os.environ.get('USER', 'unknown')
        self.launcher = self.root / 'profile-launcher.sh'
        self.marker = self.root / 'login-complete'
        login_args = ['login'] if harness == 'codex' else ['auth', 'login']
        command = ['env', '-i', *[f'{k}={v}' for k, v in login_env.items()], str(client)]
        self.launcher.write_text('#!/bin/sh\ncd ' + shlex.quote(str(cwd)) + ' || exit 1\n'
                                 + shlex.join(command) + ' "$@"\nresult=$?\n'
                                 + 'if [ "$result" = 0 ] && [ "$*" = ' + shlex.quote(' '.join(login_args))
                                 + ' ]; then : > ' + shlex.quote(str(self.marker)) + '; fi\nexit "$result"\n')
        self.launcher.chmod(0o700)

    def sign_in(self):
        login = ['login'] if self.harness == 'codex' else ['auth', 'login']
        print('Sign in once in another terminal:\n' + shlex.join([str(self.launcher), *login]), flush=True)
        if input('Type signed-in after the login command exits: ') != 'signed-in' or not self.marker.is_file():
            raise RuntimeError('Login not completed; no trials started')
        for path in self.configs:
            self.safe_config(path)
            self.baseline[path] = path.read_bytes() if path.exists() else None
        if self.harness == 'codex':
            config = tomllib.loads(self.baseline[self.configs[0]].decode())
            if config.get('sandbox_workspace_write', {}).get('writable_roots'):
                raise RuntimeError('Unexpected writable roots in fresh login profile')
        self.reset()

    def safe_config(self, path):
        for parent in [self.home, self.directory]:
            if parent.is_symlink() or not parent.is_dir():
                raise RuntimeError('Unsafe profile directory: ' + str(parent))
        if path.is_symlink() or (path.exists() and (not stat.S_ISREG(path.stat().st_mode) or path.stat().st_nlink != 1)):
            raise RuntimeError('Refusing aliased or non-regular config: ' + str(path))

    def reset(self):
        # Credentials are opaque. Only explicitly named disposable runtime entries
        # may be removed; an unfamiliar entry stops reuse for human inspection.
        runtime = ({'sessions', 'archived_sessions', 'history.jsonl', 'session_index.jsonl', 'log', 'logs',
                    'tmp', 'shell_snapshots', 'models_cache.json', 'version.json', 'sqlite', 'skills',
                    '.codex-global-state.json', 'capabilities.json'} if self.harness == 'codex' else
                   {'projects', 'debug', 'todos', 'tasks', 'plans', 'session-env', 'paste-cache', 'file-history',
                    'backups', 'shell-snapshots', 'cache', 'statsig', 'telemetry', '.cache', 'stats-cache.json',
                    'history.jsonl', 'skills'})
        auth = 'auth.json' if self.harness == 'codex' else '.credentials.json'
        allowed = {p.name for p in self.configs if p.parent == self.directory} | {auth}
        disposable = []
        for path in self.directory.iterdir():
            if path.name in runtime or (self.harness == 'codex' and re.fullmatch(r'state_\d+\.sqlite(?:-wal|-shm)?', path.name)):
                disposable.append(path)
            elif path.name not in allowed:
                raise RuntimeError('Unknown profile entry retained: ' + str(path))
        home_entries = {self.directory.name} | {p.name for p in self.configs if p.parent == self.home}
        for path in self.home.iterdir():
            if path.name not in home_entries:
                raise RuntimeError('Unknown temporary HOME entry retained: ' + str(path))
        for path in self.configs:
            self.safe_config(path)
        for path in disposable:
            if path.is_symlink() or not path.is_dir():
                path.unlink()
            else:
                shutil.rmtree(path)
        for path, content in self.baseline.items():
            if content is None:
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(content)

    def install(self, binary, env, cwd):
        host = dict(env, HOME=str(self.home), CODEX_HOME=str(self.home / '.codex'),
                    CLAUDE_CONFIG_DIR=str(self.home / '.claude'))
        self.context = (binary, host, cwd)
        args = ['agents', 'install', '--' + self.harness]
        if self.harness == 'claude':
            args += ['--hook', '--stop-hook']
        preview = self.call(args, json_output=True)
        self.call(args + ['--apply', preview['token']])

    def call(self, args, json_output=False):
        binary, env, cwd = self.context
        result = self.execute([str(binary), '--ws', 'acme', *args, *(['--json'] if json_output else [])], env, cwd, 30)
        if result['exit'] != 0:
            raise RuntimeError('Profile installer failed: ' + json.dumps(result))
        return json.loads(result['stdout'])['data'] if json_output else result

    def finish_trial(self, root, destination, retain=False):
        try:
            destination.mkdir(parents=True, exist_ok=True)
            if self.context:
                args = ['agents', 'uninstall', '--' + self.harness]
                preview = self.call(args, json_output=True)
                applied = self.call(args + ['--apply', preview['token']], json_output=True)
                remaining = self.call(args, json_output=True)['changes']
                if remaining:
                    raise RuntimeError('Owned installation remains after uninstall')
                (destination / 'cleanup.json').write_text(json.dumps({'uninstalled': True, 'preview': preview,
                    'applied': applied, 'remaining_changes': remaining}, indent=2) + '\n')
            if not retain:
                self.reset()
                shutil.rmtree(root)
        except BaseException:
            retain = True
            raise
        finally:
            self.context = None
            if retain:
                self.retained.append(root)

    def instructions(self):
        logout = ['logout'] if self.harness == 'codex' else ['auth', 'logout']
        print('Log out of the temporary profile:\n' + shlex.join([str(self.launcher), *logout]), flush=True)
        print('After logout, clean up:\n' + shlex.join(['rm', '-rf', '--', str(self.root),
                                                       *map(str, self.retained)]), flush=True)
