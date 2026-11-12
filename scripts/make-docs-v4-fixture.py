#!/usr/bin/env python3
"""Create the synthetic v4 fixture: make-docs-v4-fixture.py <v4-binary> <output.db>.

The checked-in fixture was produced with source commit
725bf236bd3d68ec18055bbecaa952cd74927efb. Build that source in an isolated checkout
with swift build --disable-sandbox -c release --only-use-versions-from-resolved-file.
The supplied binary is run only with temporary HOME and SILTA_HOME.
"""
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path
root=Path(tempfile.mkdtemp(prefix='silta-v4-fixture-',dir='/private/tmp'))
(root/'home').mkdir()
yaml='''workspace: {slug: acme, name: Acme, task_prefix: AC}
repos: [{slug: platform}]
apps:
  - {slug: mobile, repo: platform, ref: origin/mobile}
  - {slug: api, repo: platform, ref: origin/api}
services: [push]
edges:
  - {from: mobile, to: api, kind: http-api, summary: Push categories}
  - {from: api, to: service:push, kind: sdk, summary: Push delivery}
topics: [{slug: messaging}]
'''
(root/'workspace.yaml').write_text(yaml)
env={'PATH':'/usr/bin:/bin','HOME':str(root/'home'),'SILTA_HOME':str(root/'state'),'SILTA_ACTOR':'agent:codex:acme','SILTA_NOW':'2023-11-14T22:13:20.000Z','SILTA_ID_SEED':'1'}
writer=str(Path(sys.argv[1]).resolve())
result=subprocess.run([writer,'ws','edit','-F',str(root/'workspace.yaml'),'--approved','Create synthetic Acme fixture'],cwd=root,env=env,text=True,capture_output=True)
assert result.returncode==0,result.stderr
fixture=Path(sys.argv[2]).resolve()
fixture.parent.mkdir(parents=True,exist_ok=True)
with sqlite3.connect(root/'state/silta.db') as db:
    assert db.execute("SELECT value FROM meta WHERE key='min_writer_version'").fetchone()==('4',), 'requires a v4 writer'
    assert db.execute('SELECT identifier FROM grdb_migrations ORDER BY rowid').fetchall()==[(f'v{i}',) for i in range(1,5)]
    db.executescript('''
    UPDATE workspace SET settings='{"future":42}';
    ALTER TABLE doc_rev ADD COLUMN future TEXT;
    INSERT INTO task(id,uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
      VALUES(1,'01HF7YAT00ZZZZZZZZZZZZZ010',1,1,'Handle unknown push categories','todo','human:acme','2023-11-14T22:13:20.000Z','2023-11-14T22:13:20.000Z');
    INSERT INTO seq_counter(scope,next) VALUES('task:1',2);
    INSERT INTO task_event(task_id,actor,kind,body,created_at) VALUES(1,'human:acme','created','Handle unknown push categories','2023-11-14T22:13:20.000Z');
    INSERT INTO doc(id,uid,workspace_id,slug,title,kind,current_rev,verified_at,created_at,updated_at)
      VALUES(1,'01HF7YAT00ZZZZZZZZZZZZZ001',1,'push-rules','Push rules','contract',2,'2023-11-14T22:13:20.000Z','2023-11-14T22:13:20.000Z','2023-11-14T22:13:20.000Z');
    INSERT INTO doc_rev(id,uid,doc_id,rev,base_rev,body_md,state,actor,message,created_at,future) VALUES
      (11,'01HF7YAT00ZZZZZZZZZZZZZ002',1,1,NULL,'Original rule.','accepted','human:acme','Initial rule','2023-11-14T22:13:20.000Z','retained history'),
      (12,'01HF7YAT00ZZZZZZZZZZZZZ003',1,2,1,'Keep unknown categories visible.','accepted','human:acme','Clarify fallback','2023-11-14T22:13:20.000Z','retained current'),
      (13,'01HF7YAT00ZZZZZZZZZZZZZ004',1,3,2,'A pending proposal.','proposed','agent:codex:acme','Propose wording','2023-11-14T22:13:20.000Z','retained proposal');
    INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,created_by,created_at) VALUES
      ('01HF7YAT00ZZZZZZZZZZZZZ020',1,'doc',1,'about','app',1,'human:acme','2023-11-14T22:13:20.000Z'),
      ('01HF7YAT00ZZZZZZZZZZZZZ021',1,'doc',1,'about','edge',1,'human:acme','2023-11-14T22:13:20.000Z'),
      ('01HF7YAT00ZZZZZZZZZZZZZ022',1,'doc',1,'about','service',1,'human:acme','2023-11-14T22:13:20.000Z'),
      ('01HF7YAT00ZZZZZZZZZZZZZ023',1,'task',1,'about','topic',1,'human:acme','2023-11-14T22:13:20.000Z');
    ''')
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    db.execute('PRAGMA journal_mode=DELETE')
    db.execute('VACUUM INTO ?', (str(fixture),))
with sqlite3.connect(fixture) as db:
    assert db.execute('PRAGMA integrity_check').fetchone()==('ok',)
    assert db.execute("SELECT value FROM meta WHERE key='min_writer_version'").fetchone()==('4',)
print(fixture)
print('Frozen schema v4; synthetic Acme only')
