package import GRDB

/// Operations sharing the write entry point's transaction and rollback boundary.
package struct StorageTransaction {
  /// Connection confined to the write closure; never retain it beyond that closure.
  package let database: Database

  /// Allocates the next one-based sequence for a scope inside the caller's transaction.
  package func nextSequence(scope: String) throws -> Int64 {
    guard
      let value = try Int64.fetchOne(
        database,
        sql: """
          INSERT INTO seq_counter(scope,next) VALUES(?,2)
          ON CONFLICT(scope) DO UPDATE SET next=next+1 RETURNING next-1
          """, arguments: [scope])
    else { throw StorageError.unavailable }
    return value
  }

  /// Appends a globally sequenced change inside the caller's transaction.
  package func recordChange(kind: String, rowID: Int64) throws {
    guard
      let seq = try Int64.fetchOne(
        database,
        sql: """
          UPDATE meta SET value=CAST(value AS INTEGER)+1 WHERE key='change_seq' RETURNING value
          """)
    else { throw StorageError.unavailable }
    try database.execute(
      sql: "INSERT INTO change_log(seq,kind,row_id) VALUES(?,?,?)", arguments: [seq, kind, rowID])
  }
}
