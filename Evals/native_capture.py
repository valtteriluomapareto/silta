"""Two durable native streams, sanitized before any interpretation."""
import hashlib


class NativeCapture:
    def __init__(self, directory, number, key=''):
        directory.mkdir(parents=True, exist_ok=True)
        self.paths = {'stdout': directory / f'phase-{number}.jsonl', 'stderr': directory / f'phase-{number}.stderr'}
        self.key = key.encode()
        self.buffers, self.streams, self.errors = {}, {}, {}
        self.process_exit = None
        self.save(b'', b'', final=False)

    def save(self, stdout, stderr, final=True, process_exit=None):
        self.process_exit = process_exit
        failure = None
        for name, value in (('stdout', stdout), ('stderr', stderr)):
            raw = value.encode() if isinstance(value, str) else bytes(value or b'')
            safe = raw.replace(self.key, b'[REDACTED]') if self.key else raw
            self.buffers[name] = safe
            # Withhold a possible split-key suffix until the final drain.
            payload = safe if final or not self.key else safe[:max(0, len(safe) - len(self.key) + 1)]
            try:
                self.paths[name].write_bytes(payload)
                self.streams[name] = {'complete': final, 'bytes': len(payload),
                                      'sha256': hashlib.sha256(payload).hexdigest(), 'redacted': bool(self.key)}
            except OSError as error:
                self.errors[name] = str(error).replace(self.key.decode(), '[REDACTED]') if self.key else str(error)
                self.streams[name] = {'complete': False, 'bytes': None, 'sha256': None, 'redacted': bool(self.key)}
                failure = error
        if failure:
            raise failure

    def text(self, name, errors='strict'):
        return self.buffers.get(name, b'').decode('utf-8', errors=errors)

    def status(self):
        return {'streams': dict(self.streams), 'errors': dict(self.errors), 'process_exit': self.process_exit}
