"""Freeze a genuine format-1 export with legacy names, using source 725bf236bd3d68ec18055bbecaa952cd74927efb.
Usage: make-docs-format1-fixture.py <v4-binary> <output-directory>
All state and configuration are synthetic Acme data in a temporary HOME.
"""
from pathlib import Path
import json
import shutil
import sqlite3
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
output = Path(sys.argv[2]).resolve()
assert not output.exists(), 'fixture output must not exist'
with tempfile.TemporaryDirectory(prefix='silta-docs-format1-', dir='/private/tmp') as scratch:
    root = Path(scratch)
    (root/'home').mkdir()
    yaml = root/'workspace.yaml'
    yaml.write_text('''workspace: {slug: acme, name: Acme, task_prefix: AC}
repos: [{slug: platform}]
apps:
  - {slug: mobile, repo: platform, ref: origin/mobile}
  - {slug: doc, repo: platform, ref: origin/api}
  - {slug: edge, repo: platform, ref: origin/edge}
  - {slug: service, repo: platform, ref: origin/service}
services: [push service]
edges:
  - {from: mobile, to: doc, kind: HTTP API, summary: Push categories, code: ['doc:Sources/Rules.swift']}
  - {from: mobile, to: 'service:push service', kind: SDK / v1, summary: Push delivery, code: ['service@release:Sources/Push.swift']}
topics: [{slug: messaging}]
''')
    env = {'PATH':'/usr/bin:/bin','HOME':str(root/'home'),'SILTA_HOME':str(root/'state'),
           'SILTA_ACTOR':'agent:codex:acme','SILTA_NOW':'2023-11-14T22:13:20.000Z','SILTA_ID_SEED':'1'}
    def call(*args):
        result = subprocess.run([binary,*args],cwd=root,env=env,text=True,capture_output=True)
        if result.returncode:
            raise RuntimeError(f'{args}: {result.returncode}: {result.stdout} {result.stderr}')
        return result.stdout
    call('ws','edit','-F',str(yaml),'--approved','Create synthetic Acme fixture')
    call('--ws','acme','task','add','Handle unknown push categories','--app','doc')
    # Distinct deterministic seeds prevent collisions across short-lived calls at frozen time.
    env['SILTA_ID_SEED']='3'
    call('--ws','acme','comment','AC-1','-m','Check the fallback rule before changing the API.')
    with sqlite3.connect(root/'state/silta.db') as db:
        assert db.execute("SELECT value FROM meta WHERE key='min_writer_version'").fetchone()==('4',)
        assert db.execute('SELECT identifier FROM grdb_migrations ORDER BY rowid').fetchall()==[(f'v{i}',) for i in range(1,5)]
        assert db.execute('SELECT count(*) FROM doc').fetchone()==(0,)
    call('--ws','acme','export','--to',str(root/'export'))
    manifest = json.loads((root/'export/acme/manifest.json').read_text())
    assert manifest['format']=='1' and manifest['schema']=='v4'
    shutil.copytree(root/'export/acme',output)
print(output)
