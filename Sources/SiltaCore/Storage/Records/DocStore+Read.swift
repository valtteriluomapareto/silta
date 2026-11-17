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
    guard let storedSlug = try row.strictText("slug"), let body = try row.strictText("body_md"),
      let state = try row.strictText("state"), let actor = try row.strictText("actor"),
      let createdAt = try row.strictText("created_at")
    else { throw StorageError.corrupt }
    let raw = try row.strictText("about_refs")
    let rawTargets = try row.strictText("about_targets")
    let about: [String]?
    let targets: [DocTargetIdentity]?
    do {
      about = try raw.map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
      targets = try rawTargets.map {
        try JSONDecoder().decode([DocTargetIdentity].self, from: Data($0.utf8))
      }
    } catch { throw StorageError.corrupt }
    let source = try sourceTask(row["source_task_id"], workspace: workspace, in: db)
    let triagedBy = try row.strictText("triaged_by")
    let triagedAt = try row.strictText("triaged_at")
    guard (triagedBy == nil) == (triagedAt == nil) else { throw StorageError.corrupt }
    return try DocRevision(
      slug: storedSlug, revision: row["rev"], baseRevision: row["base_rev"],
      body: body, title: row.strictText("title"), kind: row.strictText("kind"), about: about,
      aboutTargets: targets,
      state: state, actor: actor, message: row.strictText("message"),
      createdAt: createdAt, sourceTask: source, triagedBy: triagedBy, triagedAt: triagedAt)
  }
  private static func sourceTask(_ id: Int64?, workspace: Int64, in db: Database) throws -> String?
  {
    guard let id else { return nil }
    let bytes = try Data.fetchOne(
      db,
      sql: """
        SELECT CAST(workspace.task_prefix||'-'||task.seq AS BLOB) FROM task
        JOIN workspace ON workspace.id=task.workspace_id
        WHERE task.id=? AND task.workspace_id=?
        """, arguments: [id, workspace])
    guard let bytes, let value = String(data: bytes, encoding: .utf8) else {
      throw StorageError.corrupt
    }
    return value
  }

}
