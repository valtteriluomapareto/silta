import Darwin
import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct BackupServiceTests {
  @Test func heldBackupLockPreventsPublicationAndPruning() throws {
    try withScratchDirectory { home in
      let store = try ExportFixture.make(home)
      let clock = FakeClock(now: StorageSchemaTests.instant)
      for _ in 0..<7 { _ = try BackupService.backup(store: store, home: home, clock: clock) }
      let directory = home.appending(path: "backups")
      let before = try ExportServiceTests.tree(directory)
      let descriptor = open(home.appending(path: "backup.lock").path, O_CREAT | O_RDWR, 0o600)
      try #require(descriptor >= 0)
      defer { close(descriptor) }
      try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
      #expect(throws: StorageError.busy) {
        try BackupService.backup(store: store, home: home, clock: clock)
      }
      #expect(abs(clock.now().timeIntervalSince(StorageSchemaTests.instant) - 5) < 0.00001)
      #expect(try ExportServiceTests.tree(directory) == before)
    }
  }

  @Test func retentionKeepsTheSnapshotWhosePathIsReturned() throws {
    try withScratchDirectory { home in
      let store = try ExportFixture.make(home)
      let backup = StorageBackup(home: home)
      for index in 1...7 {
        _ = try backup.snapshot(name: "silta-2023-11-14-manual-1700000001000-AAAAA\(index).db")
      }
      let result = try BackupService.backup(
        store: store, home: home, clock: FakeClock(now: StorageSchemaTests.instant))
      #expect(FileManager.default.fileExists(atPath: result.path))
      let names = try FileManager.default.contentsOfDirectory(
        atPath: home.appending(path: "backups").path)
      #expect(names.filter { $0.contains("-manual-") }.count == 7)
    }
  }

  @Test func fixedTimeSnapshotsAreUniqueAndDailyPruningPreservesThem() throws {
    try withScratchDirectory { home in
      let store = try ExportFixture.make(home)
      let clock = FakeClock(now: StorageSchemaTests.instant)
      try store.write { tx in
        try tx.database.execute(sql: "UPDATE task SET title='Committed WAL sentinel' WHERE seq=2")
      }
      let pending = ["daily.pending", "migration.pending", "restore.pending"]
      for name in pending {
        try Data("Acme pending".utf8).write(to: home.appending(path: "backups/" + name))
      }
      let before = try store.read {
        try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='last_backup_day'")
      }
      var paths: Set<String> = []
      for _ in 0..<7 {
        let path = try BackupService.backup(store: store, home: home, clock: clock).path
        paths.insert(path)
        let snapshot = try DatabaseQueue(path: path)
        let values = try snapshot.read { db in
          (
            try Int.fetchOne(db, sql: "SELECT count(*) FROM workspace"),
            try String.fetchOne(db, sql: "SELECT title FROM task WHERE seq=2")
          )
        }
        #expect(values.0 == 2)
        #expect(values.1 == "Committed WAL sentinel")
      }
      #expect(paths.count == 7)
      for name in pending {
        #expect(
          try Data(contentsOf: home.appending(path: "backups/" + name)) == Data("Acme pending".utf8)
        )
      }
      let backup = StorageBackup(home: home)
      for day in 1...9 {
        _ = try backup.snapshot(name: String(format: "silta-2023-12-%02d.db", day))
      }
      try backup.prune()
      for path in paths { #expect(FileManager.default.fileExists(atPath: path)) }
      let after = try store.read {
        try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='last_backup_day'")
      }
      #expect(before == after)

    }
  }

  @Test func manualEvidenceDoesNotCoverAMissingDailySnapshot() throws {
    try withScratchDirectory { home in
      let directory = home.appending(path: "backups")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("Acme".utf8).write(
        to: directory.appending(path: "silta-2023-11-14-manual-1700000000000-ABC123.db"))
      let evidence = DoctorBackups(home: home, at: StorageSchemaTests.instant)
      #expect(evidence.count == 1)
      #expect(evidence.days.isEmpty)
      #expect(!evidence.isKnownEmpty)
      #expect(evidence.check(expectedDay: "2023-11-14").status == .warning)
    }
  }
}
