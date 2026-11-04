package import Foundation
import GRDB

extension HumanApproval {
  /// Records one approval in the transaction that performs its authorized mutation.
  /// The command contains paths, refs and flag names, never bodies or approval words.
  package func record(
    command: String, workspace: String?, identity: (ids: any IDGenerator, date: Date),
    in tx: StorageTransaction
  ) throws {
    let (ids, date) = identity
    try tx.database.execute(
      sql: """
        INSERT INTO approval(uid,workspace,actor,command,words,created_at)
        VALUES(?,?,?,?,?,?)
        """,
      arguments: [
        try ids.next(at: date), workspace, actor.description, command, words,
        utcTimestamp(date),
      ])
    try tx.recordChange(kind: "approval", rowID: tx.database.lastInsertedRowID)
  }
}
