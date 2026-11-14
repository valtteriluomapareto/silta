import Foundation
import GRDB

extension DocStore {
  /// Stores a complete pending snapshot without changing accepted state or attachments.
  func propose(
    _ draft: DocDraft, metadata: DocMetadata, base: Int?, source: Int64?
  ) throws -> DocRevision {
    let stamp = utcTimestamp(at)
    let id = try docID(draft.slug, metadata: metadata, old: find(draft.slug), stamp: stamp)
    let revision = try nextRevision(id, slug: draft.slug)
    try db.execute(
      sql: """
        INSERT INTO doc_rev(uid,doc_id,rev,base_rev,body_md,state,actor,message,created_at,
          title,kind,about_refs,source_task_id,triaged_at,triaged_by)
        VALUES(?,?,?,?,CAST(? AS TEXT),'proposed',?,?,?,?,?,?,?,NULL,NULL)
        """,
      arguments: [
        try ids.next(at: at), id, revision, base, Data(draft.body.utf8), actor.description,
        draft.message,
        stamp,
        metadata.title, metadata.kind, try WorkspaceConfig.json(metadata.refs), source,
      ])
    try transaction.recordChange(kind: "doc", rowID: id)
    return try Self.revision(draft.slug, revision: revision, workspace: workspace, in: db)
  }
}
