import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocStoredIdentityCommandTests {
  @Test(arguments: ["workspace", "doc_rev", "app"], [false, true])
  func unsupportedIdentityKeepsHumanBackupRecovery(table: String, json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("rules", to: "service", in: store)
      let queue = try DatabaseQueue(path: store.path)
      let bytes = Data("owned-uid\u{0}private-suffix".utf8)
      try queue.write {
        try $0.execute(sql: "UPDATE \(table) SET uid=CAST(? AS TEXT)", arguments: [bytes])
      }
      let before = try RestoreDocumentCommandFixture.dump(queue)
      let result = try SiltaBinary.run(
        [
          "--ws", "acme", "doc", "edit", "rules", "--keep-body", "--about", "app:api",
          "--approved", "Inspect the Acme identity",
        ] + (json ? ["--json"] : []),
        in: scratch, environment: TaskCommandTests.fixed)
      let shown = result.stdout + result.stderr
      Golden.forTests().check(
        shown, json ? "stored-uid-unsupported.json" : "stored-uid-unsupported.txt")
      #expect(result.termination == .exit(9))
      #expect(!shown.contains("private-suffix") && !shown.contains("doc edit"))
      #expect(try RestoreDocumentCommandFixture.dump(queue) == before)
      #expect(
        try queue.read { try Data.fetchOne($0, sql: "SELECT CAST(uid AS BLOB) FROM \(table)") }
          == bytes)
    }
  }
}
