import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocStoredIdentityCommandTests {
  @Test(arguments: ["workspace", "doc_rev", "app"], [false, true])
  func readsRemainAvailableAndDoctorDiagnosesLaterUIDDamage(table: String, json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try AcmeDocAttachments.attach("rules", to: "service", in: store)
      let queue = try DatabaseQueue(path: store.path)
      let bytes = Data("owned-uid\u{0}private-suffix".utf8)
      try queue.write {
        try $0.execute(sql: "UPDATE \(table) SET uid=CAST(? AS TEXT)", arguments: [bytes])
      }
      let before = try RestoreDocumentCommandFixture.dump(queue)
      let read = try SiltaBinary.run(
        ["--ws", "acme", "doc", "show", "rules", "--json"],
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(read.termination == .exit(0))
      let result = try SiltaBinary.run(
        ["doctor"] + (json ? ["--json"] : []),
        in: scratch, environment: TaskCommandTests.fixed)
      let shown = result.stdout + result.stderr
      #expect(result.termination == .exit(9))
      #expect(shown.contains("Stored IDs must be nonempty ASCII text without NUL"))
      #expect(!shown.contains("private-suffix") && !shown.contains("silta init"))
      if json {
        let checks = try #require(try GuideContractTests.data(result)["checks"] as? [[String: Any]])
        let integrity = try #require(checks.first { $0["id"] as? String == "database.integrity" })
        let contract = integrity.filter { ["id", "status", "message", "next_by"].contains($0.key) }
        let data = try JSONSerialization.data(withJSONObject: contract, options: [.sortedKeys])
        Golden.forTests().check(
          try #require(String(data: data, encoding: .utf8)) + "\n", "stored-uid-doctor.json")
      }
      #expect(try RestoreDocumentCommandFixture.dump(queue) == before)
      #expect(
        try queue.read { try Data.fetchOne($0, sql: "SELECT CAST(uid AS BLOB) FROM \(table)") }
          == bytes)
    }
  }
}
