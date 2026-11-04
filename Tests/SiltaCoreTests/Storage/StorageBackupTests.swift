import Darwin
import Dispatch
import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StorageBackupTests {
  @Test func completeSnapshotsAndRetentionIgnoreUnrelatedFiles() throws {
    try withScratchDirectory { scratch in
      let store = StorageSchemaTests.store(scratch)
      try store.initialize()
      let backups = StorageBackup(home: scratch)
      let folder = scratch.appending(path: "backups")
      let unrelated = folder.appending(path: "acme-notes.txt")
      try Data("Acme".utf8).write(to: unrelated)
      try Data("Acme".utf8).write(to: folder.appending(path: "silta-acme.db"))
      for day in 1...9 {
        let name = String(format: "silta-2023-12-%02d.db", day)
        let file = try backups.snapshot(name: name)
        let queue = try DatabaseQueue(path: file.path)
        #expect(try queue.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") } == "ok")
        try backups.prune()
      }
      let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
      #expect(names.count == 9)
      #expect(names.contains("silta-2023-12-09.db"))
      #expect(!names.contains("silta-2023-12-01.db"))
      #expect(try Data(contentsOf: unrelated) == Data("Acme".utf8))
      let last = folder.appending(path: "silta-2023-12-09.db")
      let previous = try Data(contentsOf: last)
      let writer = try DatabaseQueue(path: store.path)
      try writer.write {
        try $0.execute(
          sql: "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('acme','acme','Acme','AC')")
      }
      _ = try backups.snapshot(
        name: last.lastPathComponent, reuseExisting: true)
      #expect(try Data(contentsOf: last) == previous)
      let collision = folder.appending(path: "silta-2023-12-10.db")
      try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: false)
      #expect(throws: StorageError.backupFailed) {
        try backups.snapshot(
          name: collision.lastPathComponent, reuseExisting: true)
      }
      let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path)
      #expect(!remaining.contains { $0.hasSuffix(".pending") })
      #expect(try Data(contentsOf: last) == previous)
    }
  }

  @Test func writesAcrossDaysKeepSevenDailyBackups() throws {
    try withScratchDirectory { scratch in
      let clock = FakeClock(now: StorageSchemaTests.instant)
      let store = StorageWriteTests.make(scratch, clock: clock)
      for day in 0..<9 {
        _ = try store.write { try StorageWriteTests.insert($0, uid: "acme-\(day)") }
        clock.advance(milliseconds: 86_400_000)
      }
      let names = try FileManager.default.contentsOfDirectory(
        atPath: scratch.appending(path: "backups").path
      ).sorted()
      #expect(names.count == 7)
      #expect(names.first == "silta-2023-11-16.db")
      #expect(names.last == "silta-2023-11-22.db")
    }
  }

  @Test func crashedStagingLeftoverIsReplaced() throws {
    try withScratchDirectory { scratch in
      try StorageSchemaTests.store(scratch).initialize()
      let folder = scratch.appending(path: "backups")
      try Data("Acme".utf8).write(to: folder.appending(path: "daily.pending"))
      let file = try StorageBackup(home: scratch)
        .snapshot(name: "silta-2023-11-15.db", reuseExisting: true)
      let queue = try DatabaseQueue(path: file.path)
      #expect(try queue.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") } == "ok")
      #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "daily.pending").path))
    }
  }

  // Backup names carry migration ids, and retention only recognizes alphanumeric ones.
  @Test func migrationIdsFitBackupNames() {
    for id in StorageSchema.migrator.migrations {
      #expect(id.wholeMatch(of: /[A-Za-z0-9]+/) != nil, "\(id)")
    }
  }

  @Test func migrationSnapshotCollisionIsRefused() throws {
    try withScratchDirectory { scratch in
      let folder = scratch.appending(path: "backups")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let file = folder.appending(path: "silta-2023-11-14-before-v1-1700000000000.db")
      let existing = try DatabaseQueue(path: file.path)
      try existing.write { try $0.execute(sql: "CREATE TABLE acme_note(id INTEGER PRIMARY KEY)") }
      let original = try Data(contentsOf: file)
      #expect(throws: StorageError.backupFailed) {
        try StorageSchemaTests.store(scratch).initialize()
      }
      #expect(try Data(contentsOf: file) == original)
    }
  }

  @Test func retentionPreservesMatchingDirectoriesAndSymlinks() throws {
    try withScratchDirectory { scratch in
      try StorageSchemaTests.store(scratch).initialize()
      let folder = scratch.appending(path: "backups")
      let directory = folder.appending(path: "silta-2000-01-01.db")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      let note = directory.appending(path: "Acme.txt")
      try Data("Acme".utf8).write(to: note)
      let alias = folder.appending(path: "silta-2001-01-01.db")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: note)
      let backup = StorageBackup(home: scratch)
      for day in 1...8 {
        _ = try backup.snapshot(
          name: String(format: "silta-2023-12-%02d.db", day))
      }
      try backup.prune()
      #expect(FileManager.default.fileExists(atPath: note.path))
      #expect(FileManager.default.fileExists(atPath: alias.path))
    }
  }

  @Test func requiredBackupFailurePreventsMigration() throws {
    try withScratchDirectory { scratch in
      try Data("Acme".utf8).write(to: scratch.appending(path: "backups"))
      #expect(throws: StorageError.backupFailed) {
        try StorageSchemaTests.store(scratch).initialize()
      }
      let queue = try DatabaseQueue(path: scratch.appending(path: "silta.db").path)
      #expect(
        try queue.read {
          try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlite_master WHERE type='table'")
        } == 0)
    }
  }

  @Test func snapshotReadsCommittedStateWhileWriterHoldsLock() throws {
    try withScratchDirectory { scratch in
      let store = StorageSchemaTests.store(scratch)
      try store.initialize()
      let queue = try DatabaseQueue(path: store.path)
      try queue.write { db in
        try db.execute(
          sql: "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('acme','acme','Acme','AC')")
        let file = try StorageBackup(home: scratch)
          .snapshot(name: "silta-2023-11-14.db")
        let snapshot = try DatabaseQueue(path: file.path)
        #expect(
          try snapshot.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM workspace") } == 0)
      }
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM workspace") } == 1)
    }
  }

  @Test func concurrentInitializersAllObserveCompleteSchema() throws {
    try withScratchDirectory { scratch in
      let failures = Mutex<[String]>([])
      DispatchQueue.concurrentPerform(iterations: 10) { _ in
        do {
          let store = StorageSchemaTests.store(scratch)
          try store.initialize()
          let count = try store.read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations")
          }
          #expect(count == StorageSchema.migrator.migrations.count)
        } catch {
          failures.withLock { $0.append(String(describing: error)) }
        }
      }
      #expect(failures.withLock { $0.isEmpty }, "\(failures.withLock { $0 })")
    }
  }

  @Test func initializationLockCoversPendingDiscoveryAndMigration() throws {
    try withScratchDirectory { scratch in
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let done = DispatchGroup()
      let failures = Mutex<[String]>([])
      let clock = PausingClock(entered: entered, release: release)
      let store = DatabaseStore(home: scratch, clock: clock, jitter: { 0 })
      done.enter()
      DispatchQueue.global().async {
        defer {
          entered.signal()
          done.leave()
        }
        do { try store.initialize() } catch {
          failures.withLock { $0.append(String(describing: error)) }
        }
      }
      entered.wait()
      let descriptor = open(scratch.appending(path: "migration.lock").path, O_RDWR)
      let result = flock(descriptor, LOCK_EX | LOCK_NB)
      let blocked = result != 0 && errno == EWOULDBLOCK
      if descriptor >= 0 { close(descriptor) }
      release.signal()
      done.wait()
      #expect(blocked)
      #expect(failures.withLock { $0.isEmpty }, "\(failures.withLock { $0 })")
      try StorageSchemaTests.store(scratch).initialize()
      #expect(
        try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations") }
          == StorageSchema.migrator.migrations.count)
    }
  }
}

private struct PausingClock: SiltaCore.Clock {
  let entered: DispatchSemaphore
  let release: DispatchSemaphore

  func now() -> Date {
    entered.signal()
    release.wait()
    return StorageSchemaTests.instant
  }
  func wait(milliseconds: UInt64) {}
}
