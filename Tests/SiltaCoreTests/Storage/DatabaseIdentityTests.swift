import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DatabaseIdentityTests {
  @Test(arguments: [false, true])
  func linkedDatabaseUsesTheTargetForWritesAndSnapshots(sameDay: Bool) throws {
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
      if !sameDay { clock.advance(milliseconds: 86_400_000) }
      let write = Result {
        try store.write { tx in
          try tx.database.execute(sql: "UPDATE task SET title='Acme linked save' WHERE seq=2")
        }
      }
      let manual = Result { try BackupService.backup(store: store, home: home, clock: clock) }
      if case .failure(let error) = write { Issue.record("Linked write refused: \(error)") }
      if case .failure(let error) = manual { Issue.record("Linked backup refused: \(error)") }
      if case .success(let receipt) = manual {
        let day = utcDay(clock.now())
        let daily = home.appending(path: "backups/silta-\(day).db")
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
      #expect(!entered)
      if case .failure(let error as any CodedError) = attempt {
        #expect(error.message.contains("Database file changed while this connection was open"))
      } else {
        Issue.record("The replaced writer accepted a write.")
      }
    }
  }

  @Test func aNewAttemptReopensARetargetedLinkAfterRefusingTheCachedWriter() throws {
    try withScratchDirectory { scratch in
      let original = try ExportFixture.make(scratch.appending(path: "original"))
      let replacement = try ExportFixture.make(scratch.appending(path: "replacement"))
      let home = scratch.appending(path: "logical")
      let fm = FileManager.default
      try fm.createDirectory(at: home, withIntermediateDirectories: false)
      let store = DatabaseStore(
        home: home, clock: FakeClock(now: StorageSchemaTests.instant),
        jitter: { 0 }, existingOnly: true)
      try fm.createSymbolicLink(atPath: store.path, withDestinationPath: original.path)
      try store.write { _ in () }
      let oldTitle = try Self.title(original)
      try fm.removeItem(atPath: store.path)
      try fm.createSymbolicLink(atPath: store.path, withDestinationPath: replacement.path)
      var called = false
      #expect(throws: StorageError.databaseReplaced) { try store.write { _ in called = true } }
      #expect(!called)
      try store.write { tx in
        try tx.database.execute(
          sql: "UPDATE task SET title='Acme after explicit retry' WHERE seq=2")
      }
      #expect(try Self.title(original) == oldTitle)
      #expect(try Self.title(replacement) == "Acme after explicit retry")
    }
  }

  @Test func migrationAndBeforeRestoreSnapshotsUseTheLinkedTarget() throws {
    try withScratchDirectory { scratch in
      let fm = FileManager.default
      let target = scratch.appending(path: "acme-target")
      let home = scratch.appending(path: "acme-home")
      for directory in [target, home] {
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
      }
      let path = target.appending(path: "acme-data.db").path
      let link = home.appending(path: "silta.db").path
      try fm.createSymbolicLink(atPath: link, withDestinationPath: path)
      let old = try DatabaseQueue(path: path)
      try StorageSchema.migrator.migrate(old, upTo: "v1")
      try old.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA journal_mode=WAL")
        try db.execute(sql: "PRAGMA wal_autocheckpoint=0")
        try db.execute(
          sql: "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('acme','acme','Acme','AC')")
      }
      let clock = FakeClock(now: StorageSchemaTests.instant)
      let viewer = DatabaseStore(home: home, clock: clock, jitter: { 0 }, existingOnly: true)
      #expect(throws: StorageError.migrationRequired) { try viewer.write { _ in () } }
      let store = DatabaseStore(home: home, clock: clock, jitter: { 0 })
      try store.initialize()
      let backups = home.appending(path: "backups")
      let migration = try #require(
        fm.contentsOfDirectory(atPath: backups.path).first { $0.contains("-before-v") })
      #expect(try Self.workspaceName(backups.appending(path: migration).path) == "Acme")
      let tree = try RestoreSupport.exportTree(store, to: scratch.appending(path: "tree"))
      try old.write { db in
        try db.execute(sql: "UPDATE workspace SET name='Acme WAL newer'")
      }
      let restored = try RestoreSupport.restore(tree, into: store, home: home)
      #expect(try Self.workspaceName(try #require(restored.snapshot)) == "Acme WAL newer")
      #expect(try Self.workspaceName(path) == "Acme")
      #expect(try fm.destinationOfSymbolicLink(atPath: link) == path)
      #expect(!fm.fileExists(atPath: link + "-wal"))
    }
  }

  private static func workspaceName(_ path: String) throws -> String? {
    try DatabaseQueue(path: path).read {
      try String.fetchOne($0, sql: "SELECT name FROM workspace WHERE slug='acme'")
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
