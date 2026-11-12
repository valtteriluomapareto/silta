"""A bounded shell grammar for evidence, never an evaluator or shell executor."""
from dataclasses import dataclass, field
from pathlib import Path
import re

from command_arguments import read_paths, path_scope


@dataclass
class ShellProgram:
    invocations: list = field(default_factory=list)
    opaque: bool = False
    commands: list = field(default_factory=list)
    composed: bool = False
    conditional: bool = False
    redirected: bool = False
    proven_commands: list = field(default_factory=list)
    backend_reads: list = field(default_factory=list)
    possible_backend_reads: list = field(default_factory=list)

    backend_read_count: int = 0
    possible_backend_read_count: int = 0

    def isolated(self):
        """One command has the native exit even with supported stdin/stderr forms."""
        return self.commands[0][:] if (not self.opaque and not self.composed
                                      and len(self.commands) == 1) else []

    def single(self):
        """Output/approval proof also requires unmodified input and output."""
        return self.isolated() if not self.redirected else []


def _lex(program, audit=False):
    words, index, heredocs = [], 0, 0
    while index < len(program):
        char = program[index]
        if audit and program.startswith('->', index) and (index + 2 == len(program) or program[index + 2].isspace()):
            words.append(('word', ('->', '->')))
            index += 2
            continue
        if char in ' \t':
            index += 1
            continue
        if program.startswith('2>&1', index) and (index + 4 == len(program) or program[index + 4] in ' \t\n;&|'):
            words.append(('merge', '2>&1'))
            index += 4
            continue
        if char == '#':
            end = program.find('\n', index)
            index = len(program) if end < 0 else end
            continue
        if program.startswith('<<', index):
            header = re.match(r'''<<[ \t]*(['"])([A-Za-z_]\w*)\1[ \t]*\n''', program[index:])
            if not header or heredocs:
                raise ValueError('unsupported heredoc')
            heredocs += 1
            body_start = index + len(header[0])
            end = re.search(r'^' + re.escape(header[2]) + r'(?=\n|$)', program[body_start:], re.M)
            if not end:
                raise ValueError('unterminated heredoc')
            words.append(('heredoc', header[2]))
            words.append(('operator', '\n'))
            index = body_start + end.end()
            continue
        if char in ';&|<>\n(){}':
            operator = char
            if program[index:index + 2] in ('&&', '||', '>>', '>&', '<&', ';;', '|&'):
                operator = program[index:index + 2]
            words.append(('operator', operator))
            index += len(operator)
            continue
        raw_parts, literal_parts, quote = [], [], None
        while index < len(program):
            char = program[index]
            if char == '\\' and quote != "'":
                if index + 1 == len(program):
                    raise ValueError('trailing escape')
                if program[index + 1] != '\n':
                    raw_parts.append(program[index:index + 2])
                    escaped = program[index + 1]
                    if quote == '"' and escaped not in '$`"\\':
                        literal_parts.append('\\')
                    literal_parts.append(escaped)
                index += 2
                continue
            if char in "'\"":
                raw_parts.append(char)
                if quote is None:
                    quote = char
                elif quote == char:
                    quote = None
                else:
                    literal_parts.append(char)
                index += 1
                continue
            if quote is None and char in ' \t\r\n;&|<>(){}':
                break
            raw_parts.append(char)
            literal_parts.append(char)
            index += 1
        if quote:
            raise ValueError('unbalanced quote')
        raw = ''.join(raw_parts)
        if not raw:
            continue
        words.append(('word', (''.join(literal_parts), raw)))
    return words


# Language vocabulary, not behavioral exceptions: sh/bash/zsh keywords and
# builtins. Only the small literal forms below are admitted from this vocabulary.
_SHELL_WORDS = frozenset("""
! - . : [ [[ ]] alias always autoload bg bind bindkey break builtin bye caller case
cd chdir command compadd comparguments compcall compctl compdescribe compfiles compgen
compgroups complete compopt compquote compset comptags comptry compvalues continue coproc
declare dirs disable disown do done echo echotc echoti elif else emulate enable end
esac eval exec exit export false fc fg fi float for foreach function functions getln
getopts hash help history if in integer jobs kill let limit local log logout nocorrect
mapfile noglob popd print printf private pushd pushln pwd r read readarray readonly rehash repeat return
sched select set setopt shift shopt source suspend test then time times trap true
ttyctl type typeset ulimit umask unalias unfunction unhash unlimit unset unsetopt until
vared wait whence where which while zcompile zformat zle zmodload zparseopts zregexparse zstyle
""".split())
_SHELLS = {'sh', 'bash', 'zsh'}
_ATOM = re.compile(r'[A-Za-z0-9_./:@%+=,-]+')
_DATA = re.compile(r"[A-Za-z0-9_ \t\n@%+=:,./!?*\[\]\"';|&(){}<>\\-]*")


def _expands(raw):
    quote, index = None, 0
    while index < len(raw):
        char = raw[index]
        if char == '\\' and quote != "'":
            index += 2
            continue
        if char in "'\"":
            quote = char if quote is None else (None if quote == char else quote)
        elif (char in '$`' and quote != "'" or char in '*?[~' and quote is None
              or char == '=' and index == 0):
            return True
        index += 1
    return False


def _literal(argv):
    if not argv or not re.fullmatch(r'[A-Za-z0-9_./-]+|:', argv[0]):
        return False
    if any(not _DATA.fullmatch(word) for word in argv):
        return False
    name = argv[0]
    if name in ('echo', 'true', ':'):
        return name == 'echo' or len(argv) == 1
    if name == 'printf':
        args = argv[1:] if argv[1:2] != ['--'] else argv[2:]
        return bool(args and not args[0].startswith('-') and re.fullmatch(r'(?:[^%]|%[%s])*', args[0]))
    if name == 'cd':
        return len(argv) == 2 and argv[1].startswith('/') and bool(_ATOM.fullmatch(argv[1]))
    if name == 'pwd':
        return read_paths(argv) is not None
    if name in _SHELL_WORDS or Path(name).name in _SHELLS:
        return False
    return True


def parse_shell(program, *, audit=False, scope=None, _depth=0):
    """Prove literal segments and their reachable prefix; otherwise require review."""
    result = ShellProgram()
    try:
        if not isinstance(program, str) or _depth >= 8 or len(program) > 65536:
            raise ValueError('unsupported program')
        if any(not c.isprintable() and c not in '\t\n' for c in program):
            raise ValueError('unsupported character')
        words = _lex(program, audit=audit)
        command, safe, heredoc, reachable, incoming = [], True, False, True, False

        def finish():
            nonlocal command, safe, heredoc, reachable, scope
            if not command:
                return
            result.composed |= bool(result.commands)
            name = Path(command[0]).name
            if (not audit and command[0] in _SHELLS | {base + shell for base in ('/bin/', '/usr/bin/') for shell in _SHELLS}
                    and safe and not incoming and not heredoc and len(command) == 3 and command[1] in ('-c', '-lc')):
                child = parse_shell(command[2], scope=scope, _depth=_depth + 1)
                result.commands.extend(child.commands)
                result.invocations.extend(child.invocations)
                if reachable:
                    result.proven_commands.extend(child.proven_commands)
                    result.backend_reads.extend(child.backend_reads)
                    result.backend_read_count += child.backend_read_count
                else:
                    result.possible_backend_reads.extend(child.backend_reads)
                    result.possible_backend_read_count += child.backend_read_count
                result.possible_backend_reads.extend(child.possible_backend_reads)
                result.possible_backend_read_count += child.possible_backend_read_count
                safe = not child.opaque
                result.composed |= child.composed
                result.conditional |= child.conditional
                result.redirected |= child.redirected
            else:
                safe &= (audit or _literal(command)) and not (incoming and name == 'silta')
                safe &= not heredoc or name == 'silta' and any(command[n:n + 2] == ['-F', '-'] for n in range(len(command)))
                result.commands.append(command)
                if name == 'silta':
                    result.invocations.append(['silta', *command[1:]])
                if reachable and safe:
                    result.proven_commands.append(command)
                paths = read_paths(command, stdin=incoming)
                unknown, backend = path_scope(paths, scope)
                (result.backend_reads if reachable and safe else result.possible_backend_reads).extend(backend)
                if backend:
                    if reachable and safe:
                        result.backend_read_count += 1
                    else:
                        result.possible_backend_read_count += 1
                elif paths and scope and any(
                        Path(root).name in Path(path).parts
                        for root in scope.get('backends', []) for path in paths):
                    # Explicit sibling names are potential reads without an attested cwd.
                    result.possible_backend_read_count += 1
                safe &= audit or paths is not None and not unknown
                if scope is not None and command[0] == 'cd':
                    safe = False
                    scope = dict(scope, cwd=None)
            result.opaque |= not safe
            reachable &= safe and not result.conditional
            command, safe, heredoc = [], True, False

        previous = None
        for kind, value in words:
            if kind == 'word':
                decoded, raw = value
                safe &= not _expands(raw)
                command.append(decoded)
                previous = None
            elif kind == 'merge':
                result.redirected = True
            elif kind == 'heredoc':
                heredoc, result.redirected = True, True
            elif value in (';', '&&', '||', '|', '\n'):
                if not command and value != '\n':
                    raise ValueError('empty command')
                had_command = bool(command)
                finish()
                result.composed |= value in ('&&', '||', '|')
                result.conditional |= value in ('&&', '||')
                reachable &= value not in ('&&', '||', '|')
                if value != '\n' or had_command:
                    incoming = value == '|'
                previous = value if value != '\n' else previous
            else:
                safe = False
                finish()
                raise ValueError('unsupported operator')
        if not command and previous in ('&&', '||', '|'):
            raise ValueError('missing command')
        finish()
    except (ValueError, TypeError, IndexError):
        result.opaque = True
        result.proven_commands = []
        result.possible_backend_reads.extend(result.backend_reads)
        result.backend_reads = []
        result.possible_backend_read_count += result.backend_read_count
        result.backend_read_count = 0
    return result
