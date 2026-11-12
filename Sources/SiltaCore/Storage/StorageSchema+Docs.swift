import GRDB

extension StorageSchema {
  static func migrateDocMetadata(in db: Database) throws {
    try db.execute(
      sql: """
        ALTER TABLE doc_rev ADD COLUMN title TEXT;
        ALTER TABLE doc_rev ADD COLUMN kind TEXT;
        ALTER TABLE doc_rev ADD COLUMN about_refs TEXT;
        ALTER TABLE doc_rev ADD COLUMN source_task_id INTEGER REFERENCES task(id);
        CREATE TABLE doc_verification (
          id INTEGER PRIMARY KEY, uid TEXT NOT NULL UNIQUE,
          doc_rev_id INTEGER NOT NULL REFERENCES doc_rev(id),
          actor TEXT NOT NULL, message TEXT,
          app_shas TEXT NOT NULL DEFAULT '[]', created_at TEXT NOT NULL
        );
        """)
    let revisions = try Row.fetchAll(
      db,
      sql: """
        SELECT doc.id AS doc_id,doc_rev.id AS rev_id,doc.workspace_id,doc.title,doc.kind
        FROM doc JOIN doc_rev ON doc_rev.doc_id=doc.id AND doc_rev.rev=doc.current_rev
        WHERE doc_rev.state='accepted'
        """)
    for revision in revisions {
      let links = try Row.fetchAll(
        db,
        sql: """
          SELECT to_kind,to_id,to_ext,anchor FROM link
          WHERE workspace_id=? AND from_kind='doc' AND from_id=? AND rel='about'
          """, arguments: [revision["workspace_id"], revision["doc_id"]])
      let refs = try links.map { try TaskLinkTarget.render($0, in: db) }.sorted()
      try db.execute(
        sql: "UPDATE doc_rev SET title=?,kind=?,about_refs=? WHERE id=?",
        arguments: [
          revision["title"], revision["kind"], try WorkspaceConfig.json(refs),
          revision["rev_id"],
        ])
    }
    try db.execute(sql: "UPDATE meta SET value='5' WHERE key='min_writer_version'")
  }
}
