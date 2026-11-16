"""Require whole-file DEBUG isolation on Swift sources in Control directories."""
from pathlib import Path
from swift_source import run, split_swift, swift_files


def check(root: Path) -> list[str]:
    errors = []
    for path in swift_files(root, "Sources", "App", "Tests", "scripts"):
        if "Control" not in path.relative_to(root).parts:
            continue
        code, _ = split_swift(path.read_text(encoding="utf-8"))
        lines = [(n, line.strip()) for n, line in enumerate(code.splitlines(), 1) if line.strip()]
        valid = bool(lines) and lines[0][1] == "#if DEBUG" and lines[-1][1] == "#endif"
        depth = 0
        for n, line in lines:
            if line.startswith("#if "):
                depth += 1
            elif line == "#endif":
                depth -= 1
                if depth < 0 or (depth == 0 and n != lines[-1][0]):
                    valid = False
            elif (line == "#else" or line.startswith("#elseif ")) and depth == 1:
                valid = False
        if not valid or depth != 0:
            errors.append(f"{path.relative_to(root)}:1: wrap the entire control source in #if DEBUG")
    return errors


if __name__ == "__main__":
    raise SystemExit(run("check_control_release", check))
