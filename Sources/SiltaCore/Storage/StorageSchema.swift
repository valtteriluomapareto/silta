import GRDB

// This schema may be corrected until first dogfood shipping (D20).
enum StorageSchema {
  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.execute(sql: sql)
      try db.execute(
        sql:
          """
          INSERT INTO meta(key, value) VALUES ('min_writer_version', '1'), ('change_seq', '0'),
          ('last_backup_day', '')
          """
      )
    }
    migrator.registerMigration("v2") { db in
      try db.execute(sql: anchorMigration)
    }
    migrator.registerMigration("v3") { db in
      try db.execute(sql: "ALTER TABLE task ADD COLUMN follow_up_at TEXT")
      try db.execute(sql: "UPDATE meta SET value='3' WHERE key='min_writer_version'")
    }
    migrator.registerMigration("v4") { db in
      try db.execute(sql: "UPDATE meta SET value='4' WHERE key='min_writer_version'")
    }
    return migrator
  }

  private static let anchorMigration = """
    ALTER TABLE link ADD COLUMN anchor TEXT;
    DROP INDEX link_unique;
    CREATE UNIQUE INDEX link_unique
    ON link(workspace_id,from_kind,from_id,rel,to_kind,IFNULL(to_id,to_ext),IFNULL(anchor,''));
    UPDATE meta SET value='2' WHERE key='min_writer_version';
    """

  private static let sql = """
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE workspace (
      id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
      slug TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      task_prefix TEXT NOT NULL UNIQUE,
      settings TEXT NOT NULL DEFAULT '{}'
    );
    CREATE TABLE repo (
      id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
      workspace_id INTEGER NOT NULL REFERENCES workspace(id),
      slug TEXT NOT NULL, remote_url TEXT, default_ref TEXT,
      UNIQUE (workspace_id, slug)
    );
    CREATE TABLE repo_path (
      repo_id INTEGER PRIMARY KEY REFERENCES repo(id),
      path TEXT NOT NULL UNIQUE,
      fetched_at TEXT
    );
    CREATE TABLE app (
      id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
      workspace_id INTEGER NOT NULL REFERENCES workspace(id),
      slug TEXT NOT NULL, previous_slugs TEXT NOT NULL DEFAULT '[]',
      name TEXT NOT NULL,
      repo_id INTEGER NOT NULL REFERENCES repo(id),
      ref TEXT NOT NULL, prod_ref TEXT, subpath TEXT,
      is_primary INTEGER NOT NULL DEFAULT 1,
      stack TEXT, summary TEXT,
      lifecycle TEXT NOT NULL DEFAULT 'active',
      UNIQUE (workspace_id, slug)
    );
    CREATE UNIQUE INDEX app_primary_ref ON app(repo_id, ref)
      WHERE is_primary = 1 AND subpath IS NULL;
    CREATE TABLE environment (
      id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
      app_id INTEGER NOT NULL REFERENCES app(id),
      name TEXT NOT NULL, url TEXT, deploy TEXT, notes TEXT
    );
    CREATE TABLE service (
      id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
      workspace_id INTEGER NOT NULL REFERENCES workspace(id),
      slug TEXT NOT NULL, name TEXT NOT NULL,
      summary TEXT, secrets_location TEXT,
      UNIQUE (workspace_id, slug)
    );
    CREATE TABLE edge (id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
      workspace_id INTEGER NOT NULL REFERENCES workspace(id),
      from_app_id INTEGER NOT NULL REFERENCES app(id),
      to_app_id INTEGER REFERENCES app(id), to_service_id INTEGER REFERENCES service(id),
      kind TEXT NOT NULL, summary TEXT NOT NULL, code_refs TEXT NOT NULL DEFAULT '[]',
      CHECK ((to_app_id IS NULL) <> (to_service_id IS NULL)));
    CREATE TABLE topic (id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
      workspace_id INTEGER NOT NULL REFERENCES workspace(id),
      slug TEXT NOT NULL, previous_slugs TEXT NOT NULL DEFAULT '[]',
      name TEXT NOT NULL, summary TEXT, status TEXT NOT NULL DEFAULT 'active',
      UNIQUE (workspace_id, slug));
    CREATE TABLE topic_alias (
      workspace_id INTEGER NOT NULL REFERENCES workspace(id),
      topic_id INTEGER NOT NULL REFERENCES topic(id),
      alias TEXT NOT NULL,
      PRIMARY KEY (workspace_id, alias));
    CREATE TABLE seq_counter (scope TEXT PRIMARY KEY, next INTEGER NOT NULL);
    CREATE TABLE task (
      id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
      workspace_id INTEGER NOT NULL REFERENCES workspace(id),
      seq INTEGER NOT NULL,
      title TEXT NOT NULL,
      type TEXT NOT NULL DEFAULT 'feature',
      status TEXT NOT NULL,
      priority INTEGER NOT NULL DEFAULT 2,
      description_md TEXT NOT NULL DEFAULT '',
      plan_md TEXT NOT NULL DEFAULT '',
      plan_rev INTEGER NOT NULL DEFAULT 0,
      acceptance_md TEXT NOT NULL DEFAULT '',
      result_md TEXT,
      parent_id INTEGER REFERENCES task(id),
      app_id INTEGER REFERENCES app(id),
      claimed_by TEXT, claimed_at TEXT,
      branch TEXT, worktree TEXT,
      done_sha TEXT, done_branch TEXT, done_dirty INTEGER,
      archive_override TEXT,
      external_ref TEXT,
      created_by TEXT NOT NULL,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, closed_at TEXT,
      UNIQUE (workspace_id, seq)
    );
    CREATE TABLE task_plan_rev (
      id INTEGER PRIMARY KEY,
      task_id INTEGER NOT NULL REFERENCES task(id),
      rev INTEGER NOT NULL, body_md TEXT NOT NULL, actor TEXT NOT NULL, created_at TEXT NOT NULL,
      UNIQUE (task_id, rev)
    );
    CREATE TABLE task_event (id INTEGER PRIMARY KEY, task_id INTEGER NOT NULL REFERENCES task(id),
      actor TEXT NOT NULL, kind TEXT NOT NULL,
      body TEXT, created_at TEXT NOT NULL);
    CREATE INDEX task_event_task ON task_event(task_id, kind);
    CREATE TABLE comment (
      id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
      task_id INTEGER REFERENCES task(id),
      doc_rev_id INTEGER REFERENCES doc_rev(id),
      seq INTEGER NOT NULL,
      thread_id INTEGER REFERENCES comment(id),
      kind TEXT NOT NULL,
      verdict TEXT,
      subject TEXT,
      anchor TEXT, anchor_sha TEXT, anchor_snippet TEXT,
      body_md TEXT NOT NULL,
      mentions TEXT NOT NULL DEFAULT '[]',
      accepted INTEGER NOT NULL DEFAULT 0,
      actor TEXT NOT NULL,
      resolved_at TEXT, resolved_by TEXT, deleted_at TEXT,
      created_at TEXT NOT NULL,
      CHECK ((task_id IS NULL) <> (doc_rev_id IS NULL))
    );
    CREATE UNIQUE INDEX comment_task_seq ON comment(task_id, seq) WHERE task_id IS NOT NULL;
    CREATE UNIQUE INDEX comment_doc_seq  ON comment(doc_rev_id, seq) WHERE doc_rev_id IS NOT NULL;
    CREATE TABLE review_request (
      id INTEGER PRIMARY KEY, task_id INTEGER NOT NULL REFERENCES task(id),
      reviewer TEXT NOT NULL,
      subject TEXT NOT NULL, requested_by TEXT NOT NULL, created_at TEXT NOT NULL,
      taken_by TEXT, taken_at TEXT,
      done_at TEXT);
    CREATE TABLE doc (id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
      workspace_id INTEGER NOT NULL REFERENCES workspace(id),
      slug TEXT NOT NULL, previous_slugs TEXT NOT NULL DEFAULT '[]',
      title TEXT NOT NULL, kind TEXT NOT NULL, owner TEXT,
      current_rev INTEGER, verified_at TEXT, archived INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, UNIQUE (workspace_id, slug));
    CREATE TABLE doc_rev (id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
      doc_id INTEGER NOT NULL REFERENCES doc(id), rev INTEGER NOT NULL,
      base_rev INTEGER,
      body_md TEXT NOT NULL,
      state TEXT NOT NULL,
      actor TEXT NOT NULL, message TEXT, created_at TEXT NOT NULL, UNIQUE (doc_id, rev));
    CREATE TABLE link (
      id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
      workspace_id INTEGER NOT NULL REFERENCES workspace(id),
      from_kind TEXT NOT NULL, from_id INTEGER NOT NULL,
      rel TEXT NOT NULL,
      to_kind TEXT NOT NULL,
      to_id INTEGER, to_ext TEXT,
      created_by TEXT NOT NULL, created_at TEXT NOT NULL,
      CHECK ((to_id IS NULL) <> (to_ext IS NULL)));
    CREATE UNIQUE INDEX link_unique
      ON link(workspace_id, from_kind, from_id, rel, to_kind, IFNULL(to_id, to_ext));
    CREATE TABLE alias_decision (
      workspace_id INTEGER NOT NULL REFERENCES workspace(id),
      note_ref TEXT NOT NULL, topic_id INTEGER NOT NULL REFERENCES topic(id),
      decision TEXT NOT NULL,
      actor TEXT NOT NULL, created_at TEXT NOT NULL,
      PRIMARY KEY (workspace_id, note_ref, topic_id));
    CREATE TABLE source (id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
      workspace_id INTEGER NOT NULL REFERENCES workspace(id),
      kind TEXT NOT NULL,
      root TEXT NOT NULL, include TEXT NOT NULL, exclude TEXT NOT NULL DEFAULT '[]',
      repo_id INTEGER REFERENCES repo(id));
    CREATE TABLE worktree_override (
      path TEXT PRIMARY KEY,
      app_id INTEGER NOT NULL REFERENCES app(id),
      set_by TEXT NOT NULL
    );
    CREATE TABLE approval (
      id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
      workspace TEXT,
      actor TEXT NOT NULL, command TEXT NOT NULL,
      words TEXT NOT NULL, created_at TEXT NOT NULL
    );
    CREATE TABLE change_log (seq INTEGER PRIMARY KEY, kind TEXT NOT NULL, row_id INTEGER NOT NULL);
    """
}
