import Darwin
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
      #expect(throws: BackupFailure.destination) {
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
  @Test func onlyTheOpenedDirectoryMatchesTheSnapshotPath() throws {
    try withScratchDirectory { scratch in
      let expected = scratch.appending(path: "acme-stage")
      let unrelated = scratch.appending(path: "other-directory")
      for directory in [expected, unrelated] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      }
      let opened = try DirectoryPath.open(expected)
      defer { close(opened) }
      try StorageBackup.requireAttached(opened, path: expected)
      #expect(throws: BackupFailure.detached) {
        try StorageBackup.requireAttached(opened, path: unrelated)
      }
    }
  }

  @Test func snapshotsRefuseAnUnrelatedStagingDescriptorWithoutCleanup() throws {
    try withScratchDirectory { home in
      let store = try ExportFixture.make(home)
      let fm = FileManager.default
      let named = home.appending(path: ".manual-AAAAAA")
      let other = home.appending(path: "other-directory")
      for directory in [named, other] {
        try fm.createDirectory(
          at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      }
      let sentinel = other.appending(path: "snapshot.pending")
      let label = Data("Acme harmless fixture".utf8)
      try label.write(to: sentinel)
      let descriptor = try DirectoryPath.open(other)
      defer { close(descriptor) }
      let backups = try RestoreSupport.backups(home)
      let connection = try store.preparedWriter()
      let backup = StorageBackup(home: home, file: connection.file)
      #expect(throws: BackupFailure.detached) {
        try backup.snapshot(
          name: "silta-2023-11-14-manual-1700000000000-AAAAAA.db",
          staging: named.lastPathComponent, source: connection.queue, openedStage: descriptor)
      }
      #expect(try fm.contentsOfDirectory(atPath: named.path).isEmpty)
      #expect(try Data(contentsOf: sentinel) == label)
      #expect(try RestoreSupport.backups(home) == backups)
    }
  }

  @Test func sourceRemovedDuringBackupIsNotRecreated() throws {
    try withScratchDirectory { home in
      let store = try ExportFixture.make(home)
      let path = URL(filePath: store.path)
      let moved = home.appending(path: "moved.db")
      let clock = BackupMoveClock(path: path, moved: moved)
      let before = try RestoreSupport.backups(home)
      #expect(throws: StorageError.databaseReplaced) {
        try BackupService.backup(store: store, home: home, clock: clock)
      }
      #expect(try RestoreSupport.backups(home) == before)
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
