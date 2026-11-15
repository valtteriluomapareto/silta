import Foundation
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
      let refs = try links.map { try v5Reference($0, in: db) }.sorted()
      try db.execute(
        sql: "UPDATE doc_rev SET title=?,kind=?,about_refs=? WHERE id=?",
        arguments: [
          revision["title"], revision["kind"], try v5JSON(refs),
          revision["rev_id"],
        ])
    }
    try db.execute(sql: "UPDATE meta SET value='5' WHERE key='min_writer_version'")
  }

  // Backfill bytes stay independent of application reference formatting.
  private static func v5Reference(_ row: Row, in db: Database) throws -> String {
    let kind: String = row["to_kind"]
    if let external: String = row["to_ext"] { return kind + ":" + external }
    guard let id: Int64 = row["to_id"] else { throw StorageError.corrupt }
    let anchor: String? = row["anchor"]
    if kind == "task", let anchor, anchor.hasPrefix("plan#") { return anchor }
    if kind == "task" { return "task:" + (try v5Task(id, in: db)) }
    if ["app", "topic", "doc", "service"].contains(kind) {
      return try v5Slug(kind, id: id, in: db)
    }
    if kind == "edge" { return try v5Edge(id, in: db) }
    if kind == "task_plan_rev" {
      guard
        let rev = try Int.fetchOne(
          db, sql: "SELECT rev FROM task_plan_rev WHERE id=?",
          arguments: [id])
      else { throw StorageError.corrupt }
      return "plan@\(rev)" + (anchor ?? "")
    }
    if kind == "doc_rev" { return try v5Document(id, in: db) }
    if kind == "comment" { return try v5Comment(id, in: db) }
    throw StorageError.corrupt
  }

  private static func v5Slug(_ kind: String, id: Int64, in db: Database) throws -> String {
    guard
      let slug = try String.fetchOne(
        db, sql: "SELECT slug FROM \(kind) WHERE id=?",
        arguments: [id])
    else { throw StorageError.corrupt }
    return kind + ":" + (kind == "service" ? v5Component(slug) : slug)
  }

  private static func v5Component(_ value: String) -> String {
    value.utf8.map { byte in
      if (65...90).contains(byte) || (97...122).contains(byte)
        || (48...57).contains(byte) || byte == 45 || byte == 95
      {
        return String(UnicodeScalar(byte))
      }
      let hex = String(byte, radix: 16, uppercase: true)
      return "%" + (hex.count == 1 ? "0" : "") + hex
    }.joined()
  }

  private static func v5Edge(_ id: Int64, in db: Database) throws -> String {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT source.slug AS source,target.slug AS target,service.slug AS service,edge.kind
          FROM edge JOIN app source ON source.id=edge.from_app_id
          LEFT JOIN app target ON target.id=edge.to_app_id
          LEFT JOIN service ON service.id=edge.to_service_id WHERE edge.id=?
          """, arguments: [id])
    else { throw StorageError.corrupt }
    let service: String? = row["service"]
    let app: String? = row["target"]
    guard let target = service.map({ "service:" + v5Component($0) }) ?? app else {
      throw StorageError.corrupt
    }
    let source: String = row["source"]
    let kind: String = row["kind"]
    return "edge:" + source + "/" + target + "/" + v5Component(kind)
  }

  private static func v5Comment(_ id: Int64, in db: Database) throws -> String {
    guard
      let comment = try Row.fetchOne(
        db, sql: "SELECT * FROM comment WHERE id=?",
        arguments: [id])
    else { throw StorageError.corrupt }
    let seq: Int = comment["seq"]
    if let task: Int64 = comment["task_id"] { return try v5Task(task, in: db) + "/\(seq)" }
    guard let revision: Int64 = comment["doc_rev_id"] else { throw StorageError.corrupt }
    return try v5Document(revision, in: db) + "/\(seq)"
  }

  private static func v5Task(_ id: Int64, in db: Database) throws -> String {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT workspace.task_prefix,task.seq FROM task
          JOIN workspace ON workspace.id=task.workspace_id
          WHERE task.id=?
          """, arguments: [id])
    else { throw StorageError.corrupt }
    return "\(row["task_prefix"] as String)-\(row["seq"] as Int)"
  }

  private static func v5Document(_ id: Int64, in db: Database) throws -> String {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT doc.slug,doc_rev.rev FROM doc_rev
          JOIN doc ON doc.id=doc_rev.doc_id
          WHERE doc_rev.id=?
          """, arguments: [id])
    else { throw StorageError.corrupt }
    return "doc:\(row["slug"] as String)@\(row["rev"] as Int)"
  }

  private static func v5JSON(_ refs: [String]) throws -> String {
    let bytes = try JSONSerialization.data(
      withJSONObject: refs,
      options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    guard let result = String(data: bytes, encoding: .utf8) else {
      throw StorageError.internalMisuse
    }
    return result
  }

}
