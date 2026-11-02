"""The plans board in docs/README.md mirrors docs/plans/ (AGENTS.md invariant 6, D15)."""

from __future__ import annotations

import re
import sys
from pathlib import Path

from swift_source import run

BOARD_FILE = "docs/README.md"
PLANS_DIR = "docs/plans"
NOT_PLANS = {"README.md", "_template.md"}
START, END = "<!-- plans-board:start -->", "<!-- plans-board:end -->"
BOARD_LINK = re.compile(r"\]\(plans/([^)#\s]+\.md)\)")


def check(root: Path) -> list[str]:
    board_path = root / BOARD_FILE
    plans_dir = root / PLANS_DIR
    if not board_path.exists():
        return [f"{BOARD_FILE} is missing"]
    text = board_path.read_text(encoding="utf-8")
    if START not in text or END not in text:
        return [f"{BOARD_FILE} is missing the {START} / {END} markers"]
    board = text.split(START, 1)[1].split(END, 1)[0]
    on_board = set(BOARD_LINK.findall(board))
    on_disk = (
        {p.name for p in plans_dir.glob("*.md") if p.name not in NOT_PLANS}
        if plans_dir.is_dir()
        else set()
    )
    errors = [f"{PLANS_DIR}/{name} is not on the board in {BOARD_FILE}" for name in sorted(on_disk - on_board)]
    errors += [f"board row links plans/{name}, which does not exist" for name in sorted(on_board - on_disk)]
    return errors


if __name__ == "__main__":
    sys.exit(run("check_plans_board", check))
