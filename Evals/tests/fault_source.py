"""Validate the exact mutation used by the static check and manual proofs."""


def mutated_source(original, file, name, marker, replacement):
    count = original.count(marker)
    if count != 1 or marker == replacement:
        raise ValueError(f'Invalid mutation for {name}: marker matches {count} times')
    result = original.replace(marker, replacement, 1)
    compile(result, f'{file} ({name})', 'exec')
    return result
