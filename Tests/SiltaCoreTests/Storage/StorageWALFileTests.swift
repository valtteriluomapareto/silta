import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StorageWALFileTests {
  /// Another SQLite client that closes the database last removes `-wal`/`-shm`. Deleting
  /// them after a truncating checkpoint and a clean close reproduces exactly that state.
  static func removeWALFiles(_ store: DatabaseStore) throws {
    let queue = try DatabaseQueue(path: store.path)
    try queue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
    try queue.close()
    for suffix in ["-wal", "-shm"] {
      try FileManager.default.removeItem(atPath: store.path + suffix)
    }
  }

  @Test func readsSurviveMissingWALFilesWithoutWriting() throws {
    try withScratchDirectory { scratch in
      do {
        try StorageSchemaTests.store(scratch).write { transaction in
          try transaction.database.execute(
            sql:
              "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('acme','acme','Acme','AC')")
        }
      }
      let store = StorageSchemaTests.store(scratch)
      try Self.removeWALFiles(store)
      let before = try Data(contentsOf: URL(filePath: store.path))
      let backups = try FileManager.default.contentsOfDirectory(
        atPath: scratch.appending(path: "backups").path)
      withKnownIssue("Read-only open fails when -wal/-shm are missing") {
        let count = try store.read {
          try Int.fetchOne($0, sql: "SELECT count(*) FROM workspace")
        }
        #expect(count == 1)
        try Self.removeWALFiles(store)
        #expect(throws: StorageError.unavailable) {
          try store.read { db in try db.execute(sql: "DELETE FROM workspace") }
        }
      }
      #expect(try Data(contentsOf: URL(filePath: store.path)) == before)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: scratch.appending(path: "backups").path)
          == backups)
    }
  }

  @Test func readOnlyDirectoryWithoutWALFilesIsUnavailable() throws {
    try withScratchDirectory { scratch in
      let store = StorageSchemaTests.store(scratch)
      try store.initialize()
      try Self.removeWALFiles(store)
      try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scratch.path)
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: scratch.path)  // restores scratch permissions
      }
      #expect(throws: StorageError.unavailable) { try store.read { _ in () } }
      #expect(!FileManager.default.fileExists(atPath: store.path + "-shm"))
    }
  }
}
