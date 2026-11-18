import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

/// A store opened `existingOnly` writes to a current store and never creates or migrates.
@Suite(.timeLimit(.minutes(1)))
struct StorageExistingOnlyTests {
  static func make(_ home: URL) -> DatabaseStore {
    DatabaseStore(
      home: home, clock: FakeClock(now: StorageSchemaTests.instant), jitter: { 0 },
      existingOnly: true)
  }

  @Test func refusesAMissingStoreWithoutCreatingItsHome() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "absent")
      #expect(throws: StorageError.cannotOpen) { try Self.make(home).write { _ in () } }
      #expect(!FileManager.default.fileExists(atPath: home.path))
    }
  }

  @Test func refusesAMissingDatabaseInAnExistingHome() throws {
    try withScratchDirectory { home in
      #expect(throws: StorageError.cannotOpen) { try Self.make(home).write { _ in () } }
      #expect(!FileManager.default.fileExists(atPath: home.appending(path: "silta.db").path))
    }
  }

  @Test func refusesAPendingMigrationAndLeavesTheDatabaseUnchanged() throws {
    try withScratchDirectory { home in
      let path = home.appending(path: "silta.db")
      let queue = try DatabaseQueue(path: path.path)
      try StorageSchema.migrator.migrate(queue, upTo: "v1")
      try queue.close()
      let before = try Data(contentsOf: path)
      var body = false
      #expect(throws: StorageError.migrationRequired) {
        try Self.make(home).write { _ in body = true }
      }
      #expect(!body)
      #expect(try Data(contentsOf: path) == before)
    }
  }

  @Test func writesToACurrentStore() throws {
    try withScratchDirectory { home in
      let clock = FakeClock(now: StorageSchemaTests.instant)
      try DatabaseStore(home: home, clock: clock, jitter: { 0 }).write { _ in () }
      let seq = try Self.make(home).write {
        try StorageWriteTests.insert($0, uid: "acme")
      }
      #expect(seq == 1)
    }
  }

  @Test func migrationRequiredIsAnEnvironmentRefusalForTheHuman() {
    #expect(StorageError.migrationRequired.code == .env)
    #expect(StorageError.migrationRequired.next == ["silta init"])
    #expect(StorageError.migrationRequired.nextBy == .human)
  }
}
