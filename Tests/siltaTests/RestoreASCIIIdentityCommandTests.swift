import Foundation
import GRDB
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RestoreASCIIIdentityCommandTests {
  @Test(arguments: [false, true], [false, true])
  func unsupportedStoredUIDOffersBackupWithoutMutation(json: Bool, dryRun: Bool) throws {
    try withScratchDirectory { scratch in
      try RestoreDocumentCommandFixture.seed(scratch)
      _ = try RestoreDocumentCommandTests.export(scratch)
      let queue = try DatabaseQueue(path: scratch.appending(path: "silta-home/silta.db").path)
      let bytes = Data("policy-doc\u{0}private-suffix".utf8)
      try queue.write {
        try $0.execute(sql: "UPDATE doc SET uid=CAST(? AS TEXT)", arguments: [bytes])
      }
      let before = try RestoreDocumentCommandFixture.dump(queue)
      let arguments =
        ["restore", "out/acme"]
        + (dryRun ? ["--dry-run"] : ["--approved", "Restore the Acme docs"])
        + (json ? ["--json"] : [])
      let result = try SiltaBinary.run(
        arguments, in: scratch, environment: RestoreCommandTests.agent)
      let shown = result.stdout + result.stderr
      let after = try RestoreDocumentCommandFixture.dump(queue)
      let afterUID = try queue.read {
        try Data.fetchOne($0, sql: "SELECT CAST(uid AS BLOB) FROM doc")
      }
      withKnownIssue("SI-133: stored unsupported UIDs need backup recovery before replacement") {
        #expect(result.termination == .exit(9), "\(shown)")
        #expect(shown.contains("ASCII") && shown.contains("silta backup"))
        #expect(!shown.contains("private-suffix") && !shown.contains("update silta"))
        #expect(after == before && afterUID == bytes)
        if json {
          #expect(shown.contains(#""code":"env""#))
          #expect(shown.contains(#""next":["silta backup"],"next_by":"human""#))
        }
      }
    }
  }
}
