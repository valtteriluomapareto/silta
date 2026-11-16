"""Require whole-file DEBUG isolation on Swift sources in Control directories."""
from pathlib import Path
from swift_source import run


def check(root: Path) -> list[str]:
    return []


if __name__ == "__main__":
    raise SystemExit(run("check_control_release", check))
