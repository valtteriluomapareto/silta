"""Answer-bearing files in every supported disposable native state location."""

HISTORY_FILES = {
    'claude': (
        'history.jsonl', 'projects/acme/conversation.jsonl', 'projects/acme/memory/MEMORY.md',
        'backups/.claude.json', 'debug/session.log', 'todos/tasks.json', 'tasks/session/tasks.json',
        'plans/plan.md', 'session-env/session.env', 'paste-cache/paste.txt', 'file-history/session/file.txt',
        'shell-snapshots/shell.sh', 'cache/changelog.md', 'statsig/cache.json', 'telemetry/events.json',
        '.cache/data.json', 'stats-cache.json', 'skills/remember/SKILL.md',
    ),
    'codex': (
        'history.jsonl', 'sessions/answer.jsonl', 'archived_sessions/answer.jsonl', 'session_index.jsonl',
        'log/session.log', 'logs/session.log', 'tmp/session.txt', 'shell_snapshots/shell.sh',
        'models_cache.json', 'version.json', 'sqlite/memories.sqlite', 'skills/remember/SKILL.md',
        '.codex-global-state.json', 'capabilities.json', 'state_5.sqlite', 'state_5.sqlite-wal', 'state_5.sqlite-shm',
    ),
}

UNCLASSIFIED_MEMORY = {'claude': 'agent-memory/acme/MEMORY.md', 'codex': 'memories/memory_summary.md'}
