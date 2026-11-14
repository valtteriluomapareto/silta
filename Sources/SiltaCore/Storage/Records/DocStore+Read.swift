import Foundation
import GRDB

extension DocStore {
  static func revision(_ slug: String, revision: Int, workspace: Int64, in db: Database) throws
    -> DocRevision
  {
    let cursor = try Row.fetchCursor(
      db,
      sql: """
        SELECT doc.slug,doc_rev.* FROM doc JOIN doc_rev ON doc_rev.doc_id=doc.id
        WHERE doc.workspace_id=? AND doc.slug=? AND doc_rev.rev=?
        """, arguments: [workspace, slug, revision])
    defer { withExtendedLifetime(cursor) {} }
    guard let row = try cursor.next() else { throw DocError.notFound(slug + "@\(revision)") }
    func text(_ name: String) throws -> String? {
      try row.withUnsafeData(named: name) { bytes in
        guard let bytes else { return nil }
        guard let value = String(data: bytes, encoding: .utf8) else { throw StorageError.corrupt }
        return value
      }
    }
    guard let storedSlug = try text("slug"), let body = try text("body_md"),
      let state = try text("state"), let actor = try text("actor"),
      let createdAt = try text("created_at")
    else { throw StorageError.corrupt }
    let raw = try text("about_refs")
    let about: [String]?
    do {
      about = try raw.map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    } catch { throw StorageError.corrupt }
    let sourceID: Int64? = row["source_task_id"]
    let source: String?
    if let sourceID {
      let bytes = try Data.fetchOne(
        db,
        sql: """
          SELECT CAST(workspace.task_prefix||'-'||task.seq AS BLOB) FROM task
          JOIN workspace ON workspace.id=task.workspace_id
          WHERE task.id=? AND task.workspace_id=?
          """, arguments: [sourceID, workspace])
      guard let bytes, let value = String(data: bytes, encoding: .utf8) else {
        throw StorageError.corrupt
      }
      source = value
    } else {
      source = nil
    }
    let triagedBy = try text("triaged_by")
    let triagedAt = try text("triaged_at")
    guard (triagedBy == nil) == (triagedAt == nil) else { throw StorageError.corrupt }
    return try DocRevision(
      slug: storedSlug, revision: row["rev"], baseRevision: row["base_rev"],
      body: body, title: text("title"), kind: text("kind"), about: about,
      state: state, actor: actor, message: text("message"),
      createdAt: createdAt, sourceTask: source, triagedBy: triagedBy, triagedAt: triagedAt)
  }
}
