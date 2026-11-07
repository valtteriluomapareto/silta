"""A bounded shell grammar for evidence, never an evaluator or shell executor."""
from dataclasses import dataclass, field
from pathlib import Path
import re
import shlex


@dataclass
class ShellProgram:
    invocations: list = field(default_factory=list)
    opaque: bool = False
    commands: list = field(default_factory=list)
    composed: bool = False
    conditional: bool = False

    def single(self):
        """Output/approval proof requires exactly one unmodified literal call."""
        return self.commands[0][:] if (not self.opaque and not self.composed
                                      and len(self.commands) == 1) else []


def _lex(program, audit=False):
    words, index, heredocs = [], 0, 0
    while index < len(program):
        char = program[index]
        if audit and program.startswith('->', index) and (index + 2 == len(program) or program[index + 2].isspace()):
            words.append(('word', ('->', '->')))
            index += 2
            continue
        if char in ' \t\r':
            index += 1
            continue
        if char == '#':
            end = program.find('\n', index)
            index = len(program) if end < 0 else end
            continue
        # Only descriptor duplication is a supported non-word redirection.
        duplicate = re.match(r'[12]?>&[12](?=$|[\s;|&])', program[index:])
        if duplicate:
            words.append(('redirect', duplicate[0]))
            index += len(duplicate[0])
            continue
        descriptor = re.match(r'[12](>>?)', program[index:])
        if descriptor:
            words.append(('operator', descriptor[1]))
            index += len(descriptor[0])
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
        start, quote = index, None
        while index < len(program):
            char = program[index]
            if char == '\\' and quote != "'":
                if index + 1 == len(program):
                    raise ValueError('trailing escape')
                index += 2
                continue
            if char in "'\"":
                if quote is None:
                    quote = char
                elif quote == char:
                    quote = None
                index += 1
                continue
            if quote is None and char in ' \t\r\n;&|<>(){}':
                break
            index += 1
        if quote:
            raise ValueError('unbalanced quote')
        raw = program[start:index]
        # shlex only decodes a word already delimited by the quote-aware scanner.
        decoded = shlex.split(raw)
        if len(decoded) != 1:
            raise ValueError('unsupported word')
        words.append(('word', (decoded[0], raw)))
    return words


def _expands(raw):
    quote, index = None, 0
    while index < len(raw):
        char = raw[index]
        if char == '\\' and quote != "'":
            index += 2
            continue
        if char in "'\"":
            if quote is None:
                quote = char
            elif quote == char:
                quote = None
        elif quote != "'" and char in '$`*?[~':
            return True
        index += 1
    return False


def parse_shell(program, *, audit=False):
    """Return ordered literal Silta invocations and uncertainty without throwing.

    Unknown syntax invalidates this call, not the trial. Heredoc bodies are
    skipped as literal data and never scanned as shell commands or gate flags.
    """
    result = ShellProgram()
    if not isinstance(program, str):
        result.opaque = True
        return result
    try:
        words = _lex(program, audit=audit)
        if (not audit and len(words) == 3 and all(kind == 'word' for kind, _ in words)
                and Path(words[0][1][0]).name in ('sh', 'bash', 'zsh')
                and words[1][1][0] in ('-c', '-lc')):
            words = _lex(words[2][1][0])
        command, heredoc, previous, incoming_pipe = [], False, None, False

        def finish():
            nonlocal command, heredoc
            if command:
                result.commands.append(command)
                if Path(command[0]).name == 'silta':
                    if incoming_pipe:
                        result.opaque = True
                    if heredoc and not any(command[n:n + 2] == ['-F', '-'] for n in range(len(command))):
                        result.opaque = True
                    result.invocations.append(['silta', *command[1:]])
                elif heredoc:
                    result.opaque = True
                if (Path(command[0]).name in ('eval', 'alias', 'unalias', 'function', 'source', '.', 'exec',
                                   'env', 'command', 'builtin', 'sudo', 'time', 'if', 'then',
                                   'else', 'fi', 'for', 'while', 'do', 'done', 'case', 'esac')
                        or Path(command[0]).name in ('sh', 'bash', 'zsh')
                        or re.match(r'[A-Za-z_]\w*=', command[0])):
                    result.opaque = True
            command, heredoc = [], False

        index = 0
        while index < len(words):
            kind, value = words[index]
            if kind == 'word':
                decoded, raw = value
                result.opaque |= _expands(raw)
                command.append(decoded)
                previous = None
            elif kind == 'heredoc':
                heredoc = True
                result.composed = True
            elif kind == 'redirect':
                result.composed = True
            elif value in ('>', '>>'):
                result.composed = True
                if index + 1 >= len(words) or words[index + 1][0] != 'word':
                    raise ValueError('missing output target')
                result.opaque |= _expands(words[index + 1][1][1])
                index += 1
            elif value in (';', '&&', '||', '|', '\n'):
                if not command and value != '\n':
                    raise ValueError('empty simple command')
                finish()
                result.composed = True
                result.conditional |= value in ('&&', '||')
                incoming_pipe = value == '|'
                previous = value if value != '\n' else previous
            else:
                raise ValueError('unsupported operator')
            index += 1
        if not command and previous in ('&&', '||', '|'):
            raise ValueError('missing command')
        finish()
    except (ValueError, TypeError, IndexError):
        # Partial argv must not certify a malformed call.
        result.invocations, result.commands, result.opaque = [], [], True
    return result
