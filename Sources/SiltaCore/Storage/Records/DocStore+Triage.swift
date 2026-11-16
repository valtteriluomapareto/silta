import Foundation
import GRDB

extension DocStore {
  func decide(_ member: DocTriageMember, verification: DocVerification?) throws {
    let stamp = utcTimestamp(at)
    let revision: Int64 = member.raw["id"]
    let document: Int64 = member.raw["doc_id"]
    try db.execute(
      sql: "UPDATE doc_rev SET state=?,triaged_at=?,triaged_by=? WHERE id=?",
      arguments: [
        verification == nil ? "rejected" : "accepted", stamp, actor.description, revision,
      ])
    if let verification, let metadata = member.metadata {
      try replaceAttachments(metadata.targets, doc: document, stamp: stamp)
      try db.execute(
        sql: """
          UPDATE doc SET title=CAST(? AS TEXT),kind=?,current_rev=?,verified_at=?,archived=0,updated_at=?
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
          try ids.next(at: at), revision, actor.description,
          "Accepted proposal.", try verification.encodedSnapshots(), stamp,
        ])
    }
    try transaction.recordChange(kind: "doc", rowID: document)
  }
}
