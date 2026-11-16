import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocTriageLegacyTitleTests {
  @Test(arguments: [false, true])
  func acceptancePreservesCompleteRetainedTitleBytes(embeddedNul: Bool) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let env = try DocTriageServiceTests.environment(home, store)
      let ref = try DocTriageServiceTests.propose(env, about: "service:push")
      let bytes = Data((embeddedNul ? "Rules\u{0}retained" : "Ordinary rules").utf8)
      try store.write {
        try $0.database.execute(sql: "UPDATE doc_rev SET title=CAST(? AS TEXT)", arguments: [bytes])
      }
      let result = try await DocTriageService(
        environment: env, workspace: "acme", approved: "Accept Acme rules"
      ).triage(DocTriage(accept: [ref], reject: []))
      #expect(result.docs.map(\.state) == ["accepted"])
      try store.read { (db: Database) throws in
        #expect(try Data.fetchOne(db, sql: "SELECT CAST(title AS BLOB) FROM doc_rev") == bytes)
        let current = try Data.fetchOne(db, sql: "SELECT CAST(title AS BLOB) FROM doc")
        if embeddedNul {
          withKnownIssue("Accepted legacy title retains complete bytes") {
            #expect(current == bytes)
          }
        } else {
          #expect(current == bytes)
        }
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_rev") == 1)
      }
    }
  }
}
