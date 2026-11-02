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
      let backups = StorageBackup(home: scratch, ids: SeededIDGenerator(seed: 1))
      let folder = scratch.appending(path: "backups")
      let unrelated = folder.appending(path: "acme-notes.txt")
      try Data("Acme".utf8).write(to: unrelated)
      for day in 1...9 {
        let name = String(format: "silta-2023-12-%02d.db", day)
        let file = try backups.snapshot(name: name, at: StorageSchemaTests.instant)
        let queue = try DatabaseQueue(path: file.path)
        #expect(try queue.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") } == "ok")
        try backups.prune()
      }
      let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
      #expect(names.count == 8)
      #expect(names.contains("silta-2023-12-09.db"))
      #expect(!names.contains("silta-2023-12-01.db"))
      #expect(try Data(contentsOf: unrelated) == Data("Acme".utf8))
      let last = folder.appending(path: "silta-2023-12-09.db")
      let previous = try Data(contentsOf: last)
      _ = try backups.snapshot(name: last.lastPathComponent, at: StorageSchemaTests.instant)
      #expect(try Data(contentsOf: last) == previous)
      let collision = folder.appending(path: "silta-2023-12-10.db")
      try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: false)
      #expect(throws: StorageError.backupFailed) {
        try backups.snapshot(name: collision.lastPathComponent, at: StorageSchemaTests.instant)
      }
      let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path)
      #expect(!remaining.contains { $0.hasPrefix("pending-") })
      #expect(try Data(contentsOf: last) == previous)
    }
  }

  @Test func snapshotReadsCommittedStateWhileWriterHoldsLock() throws {
    try withScratchDirectory { scratch in
      let store = StorageSchemaTests.store(scratch)
      try store.initialize()
      let queue = try DatabaseQueue(path: store.path)
      try queue.write { db in
        try db.execute(sql: "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('acme','acme','Acme','AC')")
        let file = try StorageBackup(home: scratch, ids: SeededIDGenerator(seed: 2))
          .snapshot(name: "silta-2023-11-14.db", at: StorageSchemaTests.instant)
        let snapshot = try DatabaseQueue(path: file.path)
        #expect(try snapshot.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM workspace") } == 0)
      }
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM workspace") } == 1)
    }
  }

  @Test func concurrentInitializersAllObserveCompleteSchema() throws {
    try withScratchDirectory { scratch in
      let failures = Mutex<[String]>([])
      DispatchQueue.concurrentPerform(iterations: 10) { index in
        do {
          let store = StorageSchemaTests.store(scratch, seed: UInt64(index))
          try store.initialize()
          let count = try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations") }
          #expect(count == 1)
        } catch {
          failures.withLock { $0.append(String(describing: error)) }
        }
      }
      #expect(failures.withLock { $0.isEmpty })
    }
  }

  @Test func stalePendingMigrationRecoversAfterPeerCommit() throws {
    try withScratchDirectory { scratch in
      let path = scratch.appending(path: "acme.db").path
      let first = try DatabaseQueue(path: path)
      try first.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode=WAL") }
      let inside = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let committed = DispatchSemaphore(value: 0)
      let done = DispatchGroup()
      let failures = Mutex<[String]>([])
      var migration = DatabaseMigrator()
      migration.registerMigration("v1") { db in
        try db.execute(sql: "CREATE TABLE acme(id INTEGER PRIMARY KEY)")
        inside.signal()
        release.wait()
      }
      let migrator = migration
      var config = Configuration()
      config.busyMode = .callback { _ in
        release.signal()
        committed.wait()
        return true
      }
      let second = try DatabaseQueue(path: path, configuration: config)
      done.enter()
      DispatchQueue.global().async {
        defer { committed.signal(); done.leave() }
        do { try StorageMigrator.apply(migrator, to: first) }
        catch { failures.withLock { $0.append(String(describing: error)) } }
      }
      inside.wait()
      do { try StorageMigrator.apply(migrator, to: second) }
      catch { failures.withLock { $0.append(String(describing: error)) } }
      done.wait()
      #expect(failures.withLock { $0.isEmpty })
      #expect(try second.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations") } == 1)
    }
  }
}
