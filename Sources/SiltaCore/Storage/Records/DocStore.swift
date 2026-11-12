import Foundation
import GRDB

/// Owns document rows and their current attachment projection in the caller's transaction.
struct DocStore {
  let workspace: Int64
  let transaction: StorageTransaction
  let actor: ActorID
  let ids: any IDGenerator
  let at: Date

  var db: Database { transaction.database }

  func accept(_ draft: DocDraft) throws -> DocRevision {
    let old = try find(draft.slug)
    let metadata = try metadata(draft, old: old)
    let stamp = utcTimestamp(at)
    let id = try docID(draft, metadata: metadata, old: old, stamp: stamp)
    let number = try nextRevision(id)
    let base: Int? = old?["current_rev"]
    try db.execute(
      sql: """
        INSERT INTO doc_rev(
          uid,doc_id,rev,base_rev,body_md,state,actor,message,created_at,title,kind,about_refs)
        VALUES(?,?,?,?,?,'accepted',?,?,?,?,?,?)
        """,
      arguments: [
        try ids.next(at: at), id, number, base, draft.body,
        actor.description, draft.message, stamp, metadata.title, metadata.kind,
        try WorkspaceConfig.json(metadata.refs),
      ])
    let revisionID = db.lastInsertedRowID
    try replaceAttachments(metadata.targets, doc: id, stamp: stamp)
    try db.execute(
      sql: """
        UPDATE doc SET title=?,kind=?,current_rev=?,verified_at=?,archived=0,updated_at=? WHERE id=?
        """, arguments: [metadata.title, metadata.kind, number, stamp, stamp, id])
    try db.execute(
      sql: """
        INSERT INTO doc_verification(uid,doc_rev_id,actor,message,app_shas,created_at)
        VALUES(?,?,?,?,'[]',?)
        """,
      arguments: [
        try ids.next(at: at), revisionID, actor.description,
        draft.message ?? "Accepted revision.", stamp,
      ])
    try transaction.recordChange(kind: "doc", rowID: id)
    return try Self.revision(draft.slug, revision: number, workspace: workspace, in: db)
  }

  func archive(_ slug: String) throws -> Bool {
    guard let doc = try find(slug) else { throw DocError.notFound(slug) }
    let id: Int64 = doc["id"]
    let archived: Bool = doc["archived"]
    if archived, try attachments(id).isEmpty { return false }
    try db.execute(
      sql: """
        DELETE FROM link WHERE workspace_id=? AND from_kind='doc' AND from_id=? AND rel='about'
        """, arguments: [workspace, id])
    try db.execute(
      sql: "UPDATE doc SET archived=1,updated_at=? WHERE id=?",
      arguments: [utcTimestamp(at), id])
    try transaction.recordChange(kind: "doc", rowID: id)
    return true
  }

  func find(_ slug: String) throws -> Row? {
    try Row.fetchOne(
      db, sql: "SELECT * FROM doc WHERE workspace_id=? AND slug=?",
      arguments: [workspace, slug])
  }

  private func nextRevision(_ doc: Int64) throws -> Int {
    let previous =
      try Int.fetchOne(
        db, sql: "SELECT MAX(rev) FROM doc_rev WHERE doc_id=?",
        arguments: [doc]) ?? 0
    let (number, overflow) = previous.addingReportingOverflow(1)
    guard !overflow else { throw StorageError.resourceExhausted }
    return number
  }

  private func docID(_ draft: DocDraft, metadata: Metadata, old: Row?, stamp: String) throws
    -> Int64
  {
    if let old { return old["id"] }
    try db.execute(
      sql: """
        INSERT INTO doc(uid,workspace_id,slug,title,kind,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?)
        """,
      arguments: [
        try ids.next(at: at), workspace, draft.slug,
        metadata.title, metadata.kind, stamp, stamp,
      ])
    return db.lastInsertedRowID
  }
}
