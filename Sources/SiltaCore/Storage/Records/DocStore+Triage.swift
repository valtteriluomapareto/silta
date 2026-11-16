import Foundation
import GRDB

extension DocStore {
  static func pending(_ ref: String, workspace: Int64, in db: Database) throws -> Row {
    let (slug, revision) = try DocTriage.selection(ref)
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT r.id,r.doc_id,r.state='proposed' AS proposed FROM doc_rev r
          JOIN doc d ON d.id=r.doc_id WHERE d.workspace_id=? AND d.slug=? AND r.rev=?
          """, arguments: [workspace, slug, revision])
    else { throw DocError.notFound(ref) }
    guard row["proposed"] as Bool else {
      throw DocError.invalid("Only proposed document revisions can be decided.")
    }
    return row
  }

  func reject(_ member: Row) throws { try decide(member, state: "rejected") }

  private func decide(_ member: Row, state: String) throws {
    try db.execute(
      sql: "UPDATE doc_rev SET state=?,triaged_at=?,triaged_by=? WHERE id=?",
      arguments: [state, utcTimestamp(at), actor.description, member["id"]])
    try transaction.recordChange(kind: "doc", rowID: member["doc_id"])
  }

  func acceptProposal(_ member: DocTriageMember, verification: DocVerification) throws {
    guard let metadata = member.metadata else { throw StorageError.internalMisuse }
    let stamp = utcTimestamp(at)
    let document: Int64 = member.raw["doc_id"]
    try replaceAttachments(metadata.targets, doc: document, stamp: stamp)
    try db.execute(
      sql: """
        UPDATE doc SET title=CAST(? AS TEXT),kind=?,current_rev=?,verified_at=?,archived=0,
        updated_at=?
        WHERE id=?
        """,
      arguments: [
        Data(metadata.title.utf8), metadata.kind, member.raw["rev"],
        verification.snapshots.count == verification.binding.apps.count ? stamp : nil, stamp,
        document,
      ])
    try db.execute(
      sql: """
        INSERT INTO doc_verification(uid,doc_rev_id,actor,message,app_shas,created_at)
        VALUES(?,?,?,?,?,?)
        """,
      arguments: [
        try ids.next(at: at), member.raw["id"], actor.description,
        "Accepted proposal.", try verification.encodedSnapshots(), stamp,
      ])
    try decide(member.raw, state: "accepted")
  }
}
