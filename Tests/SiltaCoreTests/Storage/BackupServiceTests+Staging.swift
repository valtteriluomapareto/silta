import Foundation
import SiltaTestSupport
import Testing

@testable import SiltaCore

extension BackupServiceTests {
  @Test func clearsOnlyOwnedStagingAfterAcquiringTheManualLock() throws {
    try withScratchDirectory { home in
      let store = try ExportFixture.make(home)
      let backups = home.appending(path: "backups")
      let stale = backups.appending(path: ".manual-ABC123")
      let unrelated = backups.appending(path: ".manual-DEF456")
      for directory in [stale, unrelated] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      }
      try Data("Acme".utf8).write(to: stale.appending(path: "snapshot.pending"))
      let note = Data("Acme notes".utf8)
      try note.write(to: unrelated.appending(path: "notes.txt"))

      _ = try BackupService.backup(
        store: store, home: home, clock: FakeClock(now: StorageSchemaTests.instant))
      #expect(!FileManager.default.fileExists(atPath: stale.path))
      #expect(try Data(contentsOf: unrelated.appending(path: "notes.txt")) == note)
    }
  }
}

extension BackupServiceTests {
  @Test(arguments: [true, false]) func linkedBackupDirectoryIsRefused(manual: Bool) throws {
    try withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      let fm = FileManager.default
      let backups = home.appending(path: "backups")
      let reserved = home.appending(path: "original-backups")
      let other = home.appending(path: "acme-empty")
      try fm.moveItem(at: backups, to: reserved)
      try fm.createDirectory(at: other, withIntermediateDirectories: false)
      try fm.createSymbolicLink(at: backups, withDestinationURL: other)
      #expect(throws: StorageError.backupFailed) {
        if manual {
          _ = try BackupService.backup(
            store: store, home: home, clock: FakeClock(now: StorageSchemaTests.instant))
        } else {
          try store.write { _ in () }
        }
      }
      #expect(try fm.contentsOfDirectory(atPath: other.path).isEmpty)
      let doctor = DoctorBackups(home: home, at: StorageSchemaTests.instant)
      #expect(!doctor.readable)
      #expect(!doctor.isKnownEmpty)
    }
  }
}

extension BackupServiceTests {
  @Test func sourceRemovedDuringBackupIsNotRecreated() throws {
    try withScratchDirectory { home in
      let store = try ExportFixture.make(home)
      let path = URL(filePath: store.path)
      let moved = home.appending(path: "moved.db")
      let clock = BackupMoveClock(path: path, moved: moved)
      _ = try? BackupService.backup(store: store, home: home, clock: clock)  // refusal is valid
      #expect(FileManager.default.fileExists(atPath: moved.path))
      #expect(!FileManager.default.fileExists(atPath: path.path))
    }
  }
}

private struct BackupMoveClock: SiltaCore.Clock {
  let path: URL
  let moved: URL

  func now() -> Date {
    try? FileManager.default.moveItem(at: path, to: moved)  // assertions check the fixture moved
    return StorageSchemaTests.instant
  }

  func wait(milliseconds: UInt64) {}
}
