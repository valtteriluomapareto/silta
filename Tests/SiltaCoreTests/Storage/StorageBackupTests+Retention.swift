import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

extension StorageBackupTests {
  static func seedFutureNames(in directory: URL) throws {
    for day in 1...7 {
      let name = String(format: "silta-2030-01-%02d.db", day)
      try Data("Acme".utf8).write(to: directory.appending(path: name))
    }
  }

  @Test func dailyBackupSurvivesFutureDatedNames() throws {
    try withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      let directory = home.appending(path: "backups")
      try Self.seedFutureNames(in: directory)
      let migration = "silta-2023-11-14-before-v1-1700000000000.db"
      let older = (8...12).map { String(format: "silta-2023-11-%02d.db", $0) }
      for name in older {
        try FileManager.default.copyItem(
          at: directory.appending(path: migration), to: directory.appending(path: name))
      }
      try store.write { _ in () }
      let daily = "silta-2023-11-14.db"
      let names = try RestoreSupport.backups(home)
      withKnownIssue("#261: retention ranks future names above the daily snapshot") {
        #expect(names == Set(older + [migration, daily]))
      }
    }
  }
}
