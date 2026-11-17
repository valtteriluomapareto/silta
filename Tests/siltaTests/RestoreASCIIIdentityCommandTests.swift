import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct RestoreASCIIIdentityCommandTests {
  @Test(arguments: [false, true])
  func invalidLegacyUIDRefusesInitAndDoctorDoesNotOfferAnInitLoop(json: Bool) throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "silta-home")
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      let fixture = URL(filePath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Fixtures/storage-v6.db")
      let database = home.appending(path: "silta.db")
      try FileManager.default.copyItem(at: fixture, to: database)
      let queue = try DatabaseQueue(path: database.path)
      try StorageSchema.migrator.migrate(queue, upTo: "v8")
      let bytes = Data("policy-doc\u{0}private-suffix".utf8)
      try queue.write {
        try $0.execute(sql: "UPDATE doc SET uid=CAST(? AS TEXT)", arguments: [bytes])
      }
      let before = try RestoreDocumentCommandFixture.dump(queue)
      let initialized = try SiltaBinary.run(
        ["init"] + (json ? ["--json"] : []),
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(initialized.termination == .exit(9))
      #expect((initialized.stdout + initialized.stderr).contains("silta doctor"))
      let diagnosis = try SiltaBinary.run(
        ["doctor"] + (json ? ["--json"] : []),
        in: scratch, environment: TaskCommandTests.fixed)
      let shown = diagnosis.stdout + diagnosis.stderr
      #expect(diagnosis.termination == .exit(9))
      #expect(shown.contains("Stored IDs must be nonempty ASCII text without NUL"))
      #expect(!shown.contains("private-suffix") && !shown.contains("silta init"))
      #expect(try RestoreDocumentCommandFixture.dump(queue) == before)
      #expect(
        try queue.read { try Data.fetchOne($0, sql: "SELECT CAST(uid AS BLOB) FROM doc") }
          == bytes)
      #expect(
        try queue.read {
          try String.fetchOne($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC")
        } == "v8")
    }
  }
}
