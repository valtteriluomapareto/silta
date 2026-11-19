import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

extension RestoreServiceTests {
  @Test func restoreKeepsBothSnapshotsDespiteFutureDatedNames() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let tree = try RestoreSupport.exportTree(store, to: scratch.appending(path: "tree"))
      try DatabaseQueue(path: store.path).write {
        try $0.execute(sql: "UPDATE task SET title='Acme before restore' WHERE seq=2")
      }
      let directory = home.appending(path: "backups")
      try StorageBackupTests.seedFutureNames(in: directory)
      let report = try RestoreSupport.restore(tree, into: store, home: home)
      let snapshot = try #require(report.snapshot)
      let daily = directory.appending(path: "silta-2023-11-14.db").path

      let titles: [String?] = try [daily, snapshot].map { path in
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let copy = try DatabaseQueue(path: path)
        return try copy.read { try String.fetchOne($0, sql: "SELECT title FROM task WHERE seq=2") }
      }
      withKnownIssue("#261: retention removes both newly published snapshots") {
        #expect(titles == ["Acme before restore", "Acme before restore"])
      }
    }
  }
}
