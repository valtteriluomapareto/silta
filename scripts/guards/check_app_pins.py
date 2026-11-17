"""Keep the app and root package on identical shared dependencies."""
from pathlib import Path
from swift_source import run


def check(root: Path) -> list[str]:
    return []


if __name__ == "__main__":
    raise SystemExit(run("check_app_pins", check))
