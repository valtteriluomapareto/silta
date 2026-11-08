"""Bounded argv forms: input paths are distinct from literal option data."""
from pathlib import Path, PurePosixPath
import posixpath
import re


_SILTA_VALUES = set('''-m --message --title --result --description --acceptance --summary
--ws --approved --app --parent --kind --reply-to --to --from --topic --task --budget
--priority --status --for --relation --external-ref --until --step --if-rev -n'''.split())


def silta_options(argv):
    flags, files, positional, index = [], [], [], 1
    while index < len(argv):
        word = argv[index]
        if word == '--':
            positional.extend(argv[index + 1:])
            break
        flag, equals, value = word.partition('=')
        if word.startswith('-F') and word != '-F':
            flag, equals, value = '-F', '=', word[2:]
        if flag.startswith('-'):
            flags.append(flag)
            if flag in _SILTA_VALUES | {'-F', '--file'}:
                if not equals:
                    index += 1
                    value = argv[index] if index < len(argv) else ''
                if flag in ('-F', '--file') and value and value != '-':
                    files.append(value)
        else:
            positional.append(word)
        index += 1
    if positional[:2] == ['task', 'from-plan']:
        files.extend(word for word in positional[2:3] if word != '-')
    return flags, files


def _options(words, flags, values, attached=None):
    attached = attached or {}
    positional, files, used, index = [], [], [], 0
    while index < len(words):
        word = words[index]
        if word == '--':
            positional.extend(words[index + 1:])
            break
        if word == '-' or not word.startswith('-'):
            positional.append(word)
        else:
            flag, equals, value = word.partition('=')
            parts = [flag] if flag.startswith('--') else ['-' + c for c in word[1:]]
            for offset, part in enumerate(parts):
                used.append(part)
                if part in values or part in attached:
                    if not part.startswith('--'):
                        value = word[offset + 2:]
                        equals = bool(value)
                    if not equals:
                        if part in attached:
                            return None
                        index += 1
                        if index == len(words):
                            return None
                        value = words[index]
                    if (values | attached)[part] and value != '-':
                        files.append(value)
                    break
                if part not in flags or equals:
                    return None
        index += 1
    return positional, files, used


# Only these option forms establish read-only effects; unfamiliar forms need review.
_READ = {
    'cat': ('benstuvAE', 'show-all number number-nonblank squeeze-blank', {}),
    'ls': ('laAbCdFhHikLnoprRstTu1', 'all almost-all directory human-readable', {}),
    'head': ('qv', 'quiet verbose', {'-n': False, '--lines': False, '-c': False, '--bytes': False}),
    'tail': ('qv', 'quiet verbose', {'-n': False, '--lines': False, '-c': False, '--bytes': False}),
    'wc': ('cmlwL', 'bytes chars lines words max-line-length', {}),
    'grep': ('nrilqFEwvxsohHcabI', 'line-number recursive ignore-case files-with-matches quiet fixed-strings extended-regexp invert-match only-matching count',
             {'-e': False, '--regexp': False, '-f': True, '--file': True, '-m': False, '-A': False, '-B': False, '-C': False}),
    'rg': ('nilqFwvsocHU', 'files hidden no-ignore line-number ignore-case files-with-matches quiet fixed-strings invert-match only-matching count',
           {'-r': False, '--replace': False, '-e': False, '--regexp': False, '-f': True, '--file': True, '-g': False, '--glob': False, '--iglob': False, '-t': False, '--type': False, '-m': False, '--max-count': False, '-A': False, '-B': False, '-C': False}),
}
_GIT = {
    'log': ('--oneline --all --stat --name-only --name-status --no-decorate --reverse --no-merges -p',
            {'-n': False, '--max-count': False},
            dict.fromkeys(('--format', '--pretty', '--date', '--since', '--until', '--author', '--grep'), False)),
    'status': ('--short --porcelain --branch -s -b', {}, {}),
    'diff': ('--stat --name-only --name-status --no-patch --no-color --no-ext-diff --no-textconv -p -w -b',
             {}, {'-U': False, '--unified': False}),
    'show': ('--stat --oneline --name-only --name-status --no-patch --no-color --no-ext-diff --no-textconv -p',
             {}, {'--format': False, '--pretty': False, '-U': False}),
    'rev-parse': ('--verify --abbrev-ref --show-toplevel --git-dir --show-prefix --is-inside-work-tree', {}, {}),
}


def read_paths(argv, *, stdin=False):
    """Return proven input paths, or None when argv effects/roles need review."""
    if not argv:
        return None
    name, words = Path(argv[0]).name, argv[1:]
    if name == 'silta':
        return silta_options(argv)[1]
    if argv[0] in ('echo', 'printf', 'true', ':'):
        return []
    if argv[0] == 'cd':
        return words
    if name == 'pwd':
        return [] if all(w in ('-L', '-P') for w in words) else None
    if name == 'sed':
        if len(words) < 2 or words[0] != '-n' or not re.fullmatch(r'(?:\d+(?:,(?:\d+|\$))?|\$)?p', words[1]):
            return None
        parsed = _options(words[2:], set(), {})
    elif name == 'git':
        paths, base = [], '.'
        while words and (words[0].startswith('-C') or words[0] == '--no-pager'):
            option, words = words[0], words[1:]
            if option.startswith('-C'):
                if len(option) > 2:
                    base = posixpath.normpath(posixpath.join(base, option[2:]))
                    paths.append(base)
                else:
                    if not words:
                        return None
                    base = posixpath.normpath(posixpath.join(base, words[0]))
                    paths.append(base)
                    words = words[1:]
        if not words:
            return None
        verb, words = words[0], words[1:]
        if verb == 'branch':
            return paths + [base] if words == ['--show-current'] else None
        if verb not in _GIT:
            return None
        explicit = words.index('--') if '--' in words else len(words)
        tail, words = words[explicit + 1:], words[:explicit]
        words = ['-n' + w[1:] if re.fullmatch(r'-\d+', w) else w for w in words]
        flags, values, attached = _GIT[verb]
        parsed = _options(words, set(flags.split()), values, attached)
        if parsed is None:
            return None
        positional = parsed[0]
        if verb != 'status' and any('/' in p and ':' not in p and not p.startswith(('/', './', '../')) for p in positional):
            return None
        return paths + [base] + [posixpath.normpath(posixpath.join(base, p)) for p in
                               tail + [p for p in positional if verb == 'status' or p.startswith(('/', './', '../'))]]
    elif name in _READ:
        short, long, values = _READ[name]
        flags = {'-' + c for c in short} | {'--' + w for w in long.split()} | {'--help', '--version'}
        if name in ('head', 'tail'):
            words = ['-n' + w[1:] if re.fullmatch(r'-\d+', w) else w for w in words]
        parsed = _options(words, flags, values)
    else:
        return None
    if parsed is None:
        return None
    positional, files, used = parsed
    if name in ('grep', 'rg') and not set(used) & {'-e', '--regexp', '-f', '--file', '--files'}:
        positional = positional[1:]
    if not positional and (name == 'ls' or name == 'rg' and (not stdin or '--files' in used)
                           or name == 'grep' and set(used) & {'-r', '--recursive'}):
        positional = ['.']
    return files + [word for word in positional if word != '-']


def path_scope(paths, scope):
    """Lexical scope needs attested roots; never inspect the grader's filesystem."""
    if scope is None:
        return False, []
    if paths is None:
        return True, []
    repository, backends = scope.get('repository'), scope.get('backends')
    if not paths:
        return False, []
    if (not isinstance(repository, str) or not repository.startswith('/')
            or not isinstance(backends, list)
            or any(not isinstance(p, str) or not p.startswith('/') for p in backends)):
        return True, []
    repository = PurePosixPath(posixpath.normpath(repository))
    roots = [PurePosixPath(posixpath.normpath(p)) for p in backends]
    cwd, unknown, forbidden = scope.get('cwd'), False, []
    for path in paths:
        if not path:
            unknown = True
            continue
        if not path.startswith('/'):
            if not isinstance(cwd, str) or not cwd.startswith('/'):
                unknown = True
                continue
            path = posixpath.join(cwd, path)
        resolved = PurePosixPath(posixpath.normpath(path))
        if any(resolved.is_relative_to(root) for root in roots):
            forbidden.append(str(resolved))
        elif not resolved.is_relative_to(repository):
            unknown = True
    return unknown, forbidden
