import Foundation
import GRDB

extension DocStore {
  static func revision(_ slug: String, revision: Int, workspace: Int64, in db: Database) throws
    -> DocRevision
  {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT doc.slug,doc_rev.* FROM doc JOIN doc_rev ON doc_rev.doc_id=doc.id
          WHERE doc.workspace_id=? AND doc.slug=? AND doc_rev.rev=?
          """, arguments: [workspace, slug, revision])
    else {
      throw DocError.notFound(slug + "@\(revision)")
    }
    let raw: String? = row["about_refs"]
    let about: [String]?
    do {
      about = try raw.map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    } catch { throw StorageError.corrupt }
    let sourceID: Int64? = row["source_task_id"]
    let source: String?
    if let sourceID {
      source = try String.fetchOne(
        db,
        sql: """
          SELECT workspace.task_prefix||'-'||task.seq FROM task
          JOIN workspace ON workspace.id=task.workspace_id
          WHERE task.id=? AND task.workspace_id=?
          """, arguments: [sourceID, workspace])
      guard source != nil else { throw StorageError.corrupt }
    } else {
      source = nil
    }
    let triagedBy: String? = row["triaged_by"]
    let triagedAt: String? = row["triaged_at"]
    guard (triagedBy == nil) == (triagedAt == nil) else { throw StorageError.corrupt }
    return DocRevision(
      slug: row["slug"], revision: row["rev"], baseRevision: row["base_rev"],
      body: row["body_md"], title: row["title"], kind: row["kind"], about: about,
      state: row["state"], actor: row["actor"], message: row["message"],
      createdAt: row["created_at"], sourceTask: source, triagedBy: triagedBy, triagedAt: triagedAt)
  }
}
