import GRDB

extension DocStore {
  /// Stores a complete pending snapshot without changing accepted state or attachments.
  func propose(
    _ slug: String, metadata: DocMetadata, body: String, why: String, base: Int?, source: Int64?
  ) throws -> DocRevision {
    let stamp = utcTimestamp(at)
    let id = try docID(slug, metadata: metadata, old: find(slug), stamp: stamp)
    let revision = try nextRevision(id, slug: slug)
    try db.execute(
      sql: """
        INSERT INTO doc_rev(uid,doc_id,rev,base_rev,body_md,state,actor,message,created_at,
          title,kind,about_refs,source_task_id,triaged_at,triaged_by)
        VALUES(?,?,?,?,?,'proposed',?,?,?,?,?,?,?,NULL,NULL)
        """,
      arguments: [
        try ids.next(at: at), id, revision, base, body, actor.description, why, stamp,
        metadata.title, metadata.kind, try WorkspaceConfig.json(metadata.refs), source,
      ])
    try transaction.recordChange(kind: "doc", rowID: id)
    return try Self.revision(slug, revision: revision, workspace: workspace, in: db)
  }
}
