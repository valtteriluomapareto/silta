"""Freeze a synthetic v7 database using the historical writer and the v6 fixture.

Usage: make-docs-v7-fixture.py <v7-binary> <frozen-v6-db> <output-db>
"""
from contextlib import closing
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile

binary, prior, output = (Path(arg).resolve() for arg in sys.argv[1:])
with tempfile.TemporaryDirectory(prefix="silta-v7-fixture-", dir="/private/tmp") as scratch:
    root = Path(scratch)
    home = root / "home"
    state = root / "state"
    home.mkdir()
    state.mkdir()
    database = state / "silta.db"
    shutil.copyfile(prior, database)
    subprocess.run(
        [binary, "--ws", "acme", "task", "add", "Review the push rule history"],
        cwd=root,
        env={
            "PATH": "/usr/bin:/bin",
            "HOME": str(home),
            "SILTA_HOME": str(state),
            "SILTA_ACTOR": "agent:codex:acme",
            "SILTA_NOW": "2023-11-14T22:14:00.000Z",
            "SILTA_ID_SEED": "72",
        },
        capture_output=True,
        check=True,
    )
    with closing(sqlite3.connect(database)) as db:
        assert db.execute("SELECT value FROM meta WHERE key='min_writer_version'").fetchone() == ("6",)
        migrations = db.execute("SELECT identifier FROM grdb_migrations ORDER BY rowid").fetchall()
        assert migrations == [(f"v{i}",) for i in range(1, 8)]
        columns = {row[1] for row in db.execute("PRAGMA table_info(doc_rev)")}
        assert {"triaged_at", "triaged_by"} <= columns and "about_targets" not in columns
        with db:
            changed = db.execute(
                "UPDATE doc_rev SET triaged_at=?,triaged_by=? WHERE id=14 AND state='rejected'",
                ("2023-11-14T22:14:00.000Z", "human:acme"),
            )
            assert changed.rowcount == 1
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        db.execute("PRAGMA journal_mode=DELETE")
        db.execute("VACUUM INTO ?", (str(output),))
with closing(sqlite3.connect(f"{output.as_uri()}?mode=ro", uri=True)) as db:
    assert db.execute("PRAGMA integrity_check").fetchone() == ("ok",)
