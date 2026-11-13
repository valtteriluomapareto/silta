"""Freeze a synthetic v6 database using source b65eab8994b7ada9f54495f9c050ebe5a3090d74.
Usage: make-docs-v6-fixture.py <v6-binary> <frozen-v4-db> <output-db>
The real writer migrates the checked-in synthetic prior DB before extra rows are seeded.
"""
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
binary=str(Path(sys.argv[1]).resolve())
prior=Path(sys.argv[2]).resolve()
output=Path(sys.argv[3]).resolve()
assert not output.exists()
with tempfile.TemporaryDirectory(prefix='silta-v6-fixture-',dir='/private/tmp') as scratch:
 root=Path(scratch)
 (root/'home').mkdir(); (root/'state').mkdir()
 shutil.copyfile(prior,root/'state/silta.db')
 env={'PATH':'/usr/bin:/bin','HOME':str(root/'home'),'SILTA_HOME':str(root/'state'),
      'SILTA_ACTOR':'agent:codex:acme','SILTA_NOW':'2023-11-14T22:13:20.000Z','SILTA_ID_SEED':'71'}
 result=subprocess.run([binary,'--ws','acme','task','add','Check the shared push rule'],cwd=root,env=env,text=True,capture_output=True,check=True)
 with sqlite3.connect(root/'state/silta.db') as db:
  assert db.execute("SELECT value FROM meta WHERE key='min_writer_version'").fetchone()==('6',)
  assert db.execute('SELECT identifier FROM grdb_migrations ORDER BY rowid').fetchall()==[(f'v{i}',) for i in range(1,7)]
  assert not {'triaged_at','triaged_by'} & {r[1] for r in db.execute('PRAGMA table_info(doc_rev)')}
  db.executescript('''
   UPDATE doc_rev SET source_task_id=1 WHERE id=13;
   INSERT INTO doc_rev(id,uid,doc_id,rev,base_rev,body_md,state,actor,message,created_at,title,kind,about_refs,source_task_id)
   VALUES(14,'01HF7YAT00ZZZZZZZZZZZZZ014',1,4,2,'An alternative rule.','rejected',
    'agent:codex:acme','A rejected suggestion.','2023-11-14T22:13:20.000Z',
    'Push rules','contract','["edge:mobile/api/http-api"]',1),
    (15,'01HF7YAT00ZZZZZZZZZZZZZ015',1,5,2,'A merged suggestion.','superseded',
    'agent:codex:acme','Merged wording.','2023-11-14T22:13:20.000Z',NULL,NULL,NULL,1);
   INSERT INTO seq_counter(scope,next) VALUES('doc_rev:1:push-rules',10);
   INSERT INTO doc_verification(uid,doc_rev_id,actor,message,app_shas,created_at)
   VALUES('01HF7YAT00ZZZZZZZZZZZZZ030',12,'human:acme','Checked push rule',
   '[{"app":"api","ref":"origin/api","sha":"0000000000000000000000000000000000000000"}]',
   '2023-11-14T22:13:20.000Z');
  ''')
  db.execute('PRAGMA wal_checkpoint(TRUNCATE)'); db.execute('PRAGMA journal_mode=DELETE')
  db.execute('VACUUM INTO ?',(str(output),))
 with sqlite3.connect(output) as db:
  assert db.execute('PRAGMA integrity_check').fetchone()==('ok',)
print(output)
