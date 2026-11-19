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
      withKnownIssue("#261: a successful backup leaves old manual staging in place") {
        #expect(!FileManager.default.fileExists(atPath: stale.path))
      }
      #expect(try Data(contentsOf: unrelated.appending(path: "notes.txt")) == note)
    }
  }
}
