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

  /// Requires pre-write evidence; changed bindings refuse before any row mutation.
  func accept(_ draft: DocDraft, verification: DocVerification) throws -> DocRevision {
    let old = try find(draft.slug)
    let metadata: DocMetadata
    do {
      metadata = try DocMetadata.resolve(draft, workspace: workspace, in: db)
    } catch let error as any CodedError where [.usage, .invalid, .notFound].contains(error.code) {
      throw DocError.changed(workspace: verification.binding.workspace)
    }
    let current = try DocVerification.binding(metadata, workspace: workspace, in: db)
    guard verification.matches(current) else {
      throw DocError.changed(workspace: verification.binding.workspace)
    }
    let targets = try DocTargetIdentity.encoded(
      current.targets.map { DocTargetIdentity(kind: $0.kind, uid: $0.uid) })
    let stamp = utcTimestamp(at)
    let verifiedAt = verification.snapshots.count == current.apps.count ? stamp : nil
    let id = try docID(draft.slug, metadata: metadata, old: old, stamp: stamp)
    let number = try nextRevision(id, slug: draft.slug)
    let base: Int? = old?["current_rev"]
    try db.execute(
      sql: """
        INSERT INTO doc_rev(
          uid,doc_id,rev,base_rev,body_md,state,actor,message,created_at,
          title,kind,about_refs,about_targets)
        VALUES(?,?,?,?,CAST(? AS TEXT),'accepted',?,?,?,CAST(? AS TEXT),CAST(? AS TEXT),?,?)
        """,
      arguments: [
        try ids.next(at: at), id, number, base, Data(draft.body.utf8),
        actor.description, draft.message, stamp, Data(metadata.title.utf8),
        Data(metadata.kind.utf8),
        try WorkspaceConfig.json(metadata.refs), targets,
      ])
    let revisionID = db.lastInsertedRowID
    try updateCurrent(metadata, doc: id, revision: number, verifiedAt: verifiedAt, stamp: stamp)
    try db.execute(
      sql: """
        INSERT INTO doc_verification(uid,doc_rev_id,actor,message,app_shas,created_at)
        VALUES(?,?,?,?,?,?)
        """,
      arguments: [
        try ids.next(at: at), revisionID, actor.description,
        draft.message ?? "Accepted revision.", try verification.encodedSnapshots(), stamp,
      ])
    try transaction.recordChange(kind: "doc", rowID: id)
    return try Self.revision(draft.slug, revision: number, workspace: workspace, in: db)
  }

  func updateCurrent(
    _ metadata: DocMetadata, doc: Int64, revision: Int, verifiedAt: String?, stamp: String
  ) throws {
    try replaceAttachments(metadata.targets, doc: doc, stamp: stamp)
    try db.execute(
      sql: """
        UPDATE doc SET title=CAST(? AS TEXT),kind=CAST(? AS TEXT),current_rev=?,verified_at=?,
          archived=0,updated_at=? WHERE id=?
        """,
      arguments: [
        Data(metadata.title.utf8), Data(metadata.kind.utf8), revision, verifiedAt, stamp, doc,
      ])
  }

  func archive(_ slug: String) throws -> Bool {
    guard let doc = try find(slug) else { throw DocError.notFound(slug) }
    let id: Int64 = doc["id"]
    guard
      try String.fetchOne(
        db, sql: "SELECT state FROM doc_rev WHERE doc_id=? AND rev=?",
        arguments: [id, doc["current_rev"] as Int?]) == "accepted"
    else {
      throw DocError.invalid("Only a doc with an accepted current revision can be archived.")
    }
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

  func nextRevision(_ doc: Int64, slug: String) throws -> Int {
    let previous =
      try Int64.fetchOne(
        db, sql: "SELECT MAX(rev) FROM doc_rev WHERE doc_id=?", arguments: [doc]) ?? 0
    let (floor, overflow) = previous.addingReportingOverflow(1)
    guard !overflow else { throw StorageError.resourceExhausted }
    let scope = "doc_rev:\(workspace):\(slug)"
    try db.execute(
      sql: """
        INSERT INTO seq_counter(scope,next) VALUES(?,?)
        ON CONFLICT(scope) DO UPDATE SET next=MAX(next,excluded.next)
        """, arguments: [scope, floor])
    guard
      let next = try Int64.fetchOne(
        db, sql: "SELECT next FROM seq_counter WHERE scope=?", arguments: [scope]),
      next > 0, next < Int64.max
    else { throw StorageError.resourceExhausted }
    return Int(try transaction.nextSequence(scope: scope))
  }

  func docID(_ slug: String, metadata: DocMetadata, old: Row?, stamp: String) throws
    -> Int64
  {
    if let old { return old["id"] }
    try db.execute(
      sql: """
        INSERT INTO doc(uid,workspace_id,slug,title,kind,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?)
        """,
      arguments: [
        try ids.next(at: at), workspace, slug,
        metadata.title, metadata.kind, stamp, stamp,
      ])
    return db.lastInsertedRowID
  }
}
