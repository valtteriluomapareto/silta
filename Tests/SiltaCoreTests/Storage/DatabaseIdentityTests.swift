import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DatabaseIdentityTests {
  @Test func linkedDatabaseUsesTheTargetForWritesAndSnapshots() throws {
    try withScratchDirectory { scratch in
      let clock = FakeClock(now: StorageSchemaTests.instant)
      let target = try ExportFixture.make(scratch.appending(path: "target"))
      let queue = try DatabaseQueue(path: target.path)
      try queue.writeWithoutTransaction {
        try $0.execute(sql: "PRAGMA wal_autocheckpoint=0")
      }
      try queue.write { db in
        try db.execute(sql: "UPDATE task SET title='Acme WAL only' WHERE seq=2")
      }
      let home = scratch.appending(path: "linked")
      let fm = FileManager.default
      try fm.createDirectory(at: home, withIntermediateDirectories: false)
      let store = DatabaseStore(home: home, clock: clock, jitter: { 0 }, existingOnly: true)
      try fm.createSymbolicLink(atPath: store.path, withDestinationPath: target.path)
      try #require(try Self.title(store) == "Acme WAL only")
      clock.advance(milliseconds: 86_400_000)
      let write = Result {
        try store.write { tx in
          try tx.database.execute(sql: "UPDATE task SET title='Acme linked save' WHERE seq=2")
        }
      }
      let manual = Result { try BackupService.backup(store: store, home: home, clock: clock) }
      withKnownIssue("A regular linked database is refused by writers and backups") {
        if case .failure(let error) = write { Issue.record("Linked write refused: \(error)") }
        if case .failure(let error) = manual { Issue.record("Linked backup refused: \(error)") }
      }
      if case .success(let receipt) = manual {
        let daily = home.appending(path: "backups/silta-2023-11-15.db")
        #expect(try Self.snapshotTitle(daily.path) == "Acme WAL only")
        #expect(try Self.snapshotTitle(receipt.path) == "Acme linked save")
        #expect(try Self.title(target) == "Acme linked save")
        #expect(try fm.destinationOfSymbolicLink(atPath: store.path) == target.path)
        for suffix in ["-wal", "-shm"] {
          #expect(!fm.fileExists(atPath: store.path + suffix))
        }
      }
    }
  }

  @Test func warmedWriterNeverInvokesItsBodyAfterTheFileIsReplaced() throws {
    try withScratchDirectory { scratch in
      let clock = FakeClock(now: StorageSchemaTests.instant)
      let home = scratch.appending(path: "original")
      let source = try ExportFixture.make(home)
      let replacement = try ExportFixture.make(scratch.appending(path: "replacement"))
      let fm = FileManager.default
      let copied = scratch.appending(path: "replacement.db")
      try DatabaseQueue(path: replacement.path).writeWithoutTransaction {
        try $0.execute(sql: "VACUUM INTO ?", arguments: [copied.path])
      }
      let cached = DatabaseStore(home: home, clock: clock, jitter: { 0 }, existingOnly: true)
      try cached.write { _ in () }
      let old = scratch.appending(path: "original.db")
      try fm.moveItem(at: URL(filePath: source.path), to: old)
      try fm.moveItem(at: copied, to: URL(filePath: source.path))
      var entered = false
      let attempt = Result { try cached.write { _ in entered = true } }
      withKnownIssue("A cached writer does not diagnose that its database file changed") {
        #expect(!entered)
        if case .failure(let error as any CodedError) = attempt {
          #expect(error.message.contains("Database file changed while this connection was open"))
        } else {
          Issue.record("The replaced writer accepted a write.")
        }
      }
    }
  }

  private static func title(_ store: DatabaseStore) throws -> String? {
    try store.read { try String.fetchOne($0, sql: "SELECT title FROM task WHERE seq=2") }
  }

  private static func snapshotTitle(_ path: String) throws -> String? {
    try DatabaseQueue(path: path).read {
      try String.fetchOne($0, sql: "SELECT title FROM task WHERE seq=2")
    }
  }
}
