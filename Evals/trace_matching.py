"""Bounded association of ordered native call chains with body-free command logs."""
from collections import Counter
from datetime import datetime

_WORK_LIMIT = 4096


def native_interval(call):
    start, end = call.get('native_start'), call.get('native_end')
    return (start, end) if type(start) is int and type(end) is int and 0 <= start < end else None


def log_span(rows):
    spans = []
    for row in rows:
        try:
            start = datetime.fromisoformat(row['timestamp'].replace('Z', '+00:00'))
            duration = row['milliseconds']
            if start.utcoffset() is None or type(duration) is not int or duration < 0:
                return None
            start = start.timestamp()
            spans.append((start, start + duration / 1000))
        except (KeyError, ValueError, TypeError, AttributeError, OverflowError):
            return None
    return (min(a for a, _ in spans), max(b for _, b in spans)) if spans else None


def match_calls(calls, logs, harness):
    """Prove a unique literal association; unknown effects and timing need review."""
    def status(code):
        return code if harness == 'codex' else code == 0

    chains = [call['chain'] for call in calls]
    unknown = any(None in chain for chain in chains)
    intervals = [native_interval(call) for call in calls]
    if unknown:
        if len(calls) * (len(calls) - 1) > _WORK_LIMIT:
            return None
        starts = [span for call, span in zip(calls, intervals) if None in call['chain']]
        if any(span is None for span in starts):
            return None
        # Unknown effects may replace executables or startup files for later calls.
        cutoff = min(span[0] for span in starts)
        prefix = [call for call, span in zip(calls, intervals) if span and span[1] < cutoff]
        end = max((span[1] for span in intervals if span and span[1] < cutoff), default=-1)
        if any(call not in prefix and (not span or span[0] < end) for call, span in zip(calls, intervals)):
            return None
        length = sum(len(call['chain']) for call in prefix)
        return False if match_calls(prefix, logs[:length], harness) is False else None
    known = [entry for chain in chains for entry in chain if entry is not None]
    required = Counter(entry[0] for entry in known)
    available = Counter(row['command'] for row in logs)
    exits = Counter((entry[0], status(entry[1])) for entry in known if entry[1] is not None)
    observed_exits = Counter((row['command'], status(row['exit_code'])) for row in logs)
    if (required - available or exits - observed_exits
            or sum(required.values()) != len(logs)):
        return False
    if len(calls) * (len(calls) - 1) > _WORK_LIMIT:
        return None
    if any(intervals[a] and intervals[b] and intervals[b][1] < intervals[a][0]
           for a in range(len(calls)) for b in range(a + 1, len(calls))):
        return False
    before, predecessors = [], [set() for _ in calls]
    for a in range(len(calls)):
        for b in range(len(calls)):
            if a != b and (intervals[a][1] < intervals[b][0] if intervals[a] and intervals[b] else a < b):
                before.append((a, b))
                predecessors[b].add(a)
    lengths = tuple(map(len, chains))

    def search(relax):
        stack = [(0, (0,) * len(calls), ((),) * len(calls))]
        seen, solutions = set(), 0
        while stack:
            index, cursors, assigned = stack.pop()
            state = (index, cursors, assigned)
            if state in seen:
                continue
            seen.add(state)
            # Reaching the bound is missing proof, not acceptance or failure.
            if len(seen) + len(stack) > _WORK_LIMIT:
                return None
            if index == len(logs) and cursors == lengths:
                if relax:
                    spans = [log_span([logs[n] for n in indices]) for indices in assigned]
                    if any(not intervals[a] or not intervals[b] or not spans[a] or not spans[b]
                           or max(spans[a][0], spans[b][0]) >= min(spans[a][1], spans[b][1])
                           for a, b in before if assigned[a][-1] > assigned[b][0]):
                        continue
                solutions += 1
                if relax or solutions == 2:
                    return solutions
                continue
            for call, cursor in enumerate(cursors):
                if cursor == lengths[call]:
                    continue
                if any(cursors[p] != lengths[p]
                       and (not relax or not intervals[p] or not intervals[call])
                       for p in predecessors[call]):
                    continue
                entry = chains[call][cursor]
                if index == len(logs):
                    continue
                row = logs[index]
                if (row['command'] != entry[0]
                        or entry[1] is not None and status(row['exit_code']) != status(entry[1])):
                    continue
                advanced, association = list(cursors), list(assigned)
                advanced[call] += 1
                association[call] += (index,)
                stack.append((index + 1, tuple(advanced), tuple(association)))
        return solutions

    strict = search(False)
    if strict is None:
        return None
    if strict:
        return None if strict > 1 else True
    # Native order remains the default. Only overlapping measured call spans may
    # explain a conflicting association, and that explanation needs review.
    relaxed = search(True)
    return None if relaxed is None or relaxed else False
