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
      // The scope closes the writer before the files are removed, as a finished client would.
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
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM workspace") } == 1)
      try Self.removeWALFiles(store)
      #expect(throws: StorageError.unavailable) {
        try store.read { db in try db.execute(sql: "DELETE FROM workspace") }
      }
      #expect(try Data(contentsOf: URL(filePath: store.path)) == before)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: scratch.appending(path: "backups").path)
          == backups)
    }
  }

  /// Recreated `-wal`/`-shm` would inherit the read-only mode and make later writes `busy`.
  @Test func readOnlyDatabaseWithoutWALFilesIsUnavailable() throws {
    try withScratchDirectory { scratch in
      do { try StorageSchemaTests.store(scratch).initialize() }
      let store = StorageSchemaTests.store(scratch)
      try Self.removeWALFiles(store)
      try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: store.path)
      #expect(throws: StorageError.unavailable) { try store.read { _ in () } }
      #expect(!FileManager.default.fileExists(atPath: store.path + "-shm"))
      #expect(!FileManager.default.fileExists(atPath: store.path + "-wal"))
    }
  }

  @Test func readOnlyDirectoryWithoutWALFilesIsUnavailable() throws {
    try withScratchDirectory { scratch in
      do { try StorageSchemaTests.store(scratch).initialize() }
      let store = StorageSchemaTests.store(scratch)
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
