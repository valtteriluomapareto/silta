"""Answer-bearing files in every supported disposable native state location."""

HISTORY_FILES = {
    'claude': (
        'history.jsonl', 'projects/acme/conversation.jsonl', 'projects/acme/memory/MEMORY.md',
        'backups/.claude.json', 'debug/session.log', 'todos/tasks.json', 'tasks/session/tasks.json',
        'plans/plan.md', 'session-env/session.env', 'paste-cache/paste.txt', 'file-history/session/file.txt',
        'shell-snapshots/shell.sh', 'cache/changelog.md', 'statsig/cache.json', 'telemetry/events.json',
        '.cache/data.json', 'stats-cache.json', 'skills/remember/SKILL.md', 'sessions/answer.jsonl',
        'plugins/data/answer.json', '.last-cleanup', 'policy-limits.json', 'policy-limits.json.signature.json',
        'policy-limits.json.stamp.json', 'remote-settings.json', 'remote-settings.json.signature.json',
        'remote-settings.json.synced-at',
    ),
    'codex': (
        'history.jsonl', 'sessions/answer.jsonl', 'archived_sessions/answer.jsonl', 'session_index.jsonl',
        'log/session.log', 'logs/session.log', 'tmp/session.txt', 'shell_snapshots/shell.sh',
        'models_cache.json', 'version.json', 'sqlite/memories.sqlite', 'skills/remember/SKILL.md',
        '.codex-global-state.json', 'capabilities.json', 'state_5.sqlite', 'state_5.sqlite-wal', 'state_5.sqlite-shm',
        'thread_history_1.sqlite', 'thread_history_1.sqlite-wal', 'thread_history_1.sqlite-shm',
        'goals_1.sqlite', 'logs_2.sqlite', 'memories_1.sqlite', 'queue_1.sqlite', 'cache/answer.json',
        'plugins/data/answer.json', 'thread-writer-locks/answer.lock', '.sandbox_migration',
    ),
}

UNCLASSIFIED_MEMORY = {'claude': 'agent-memory/acme/MEMORY.md', 'codex': 'memories/memory_summary.md'}
