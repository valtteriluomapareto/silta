import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocTriageLegacyTitleTests {
  @Test(arguments: ["title", "kind"], [false, true])
  func acceptancePreservesCompleteRetainedMetadataBytes(field: String, embeddedNul: Bool)
    async throws
  {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let env = try DocTriageServiceTests.environment(home, store)
      let ref = try DocTriageServiceTests.propose(env, about: "service:push")
      let bytes = Data((embeddedNul ? "Rules\u{0}retained" : "Ordinary rules").utf8)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET \(field)=CAST(? AS TEXT)", arguments: [bytes])
      }
      let result = try await DocTriageService(
        environment: env, workspace: "acme", approved: "Accept Acme rules"
      ).triage(DocTriage(accept: [ref], reject: []))
      #expect(result.docs.map(\.state) == ["accepted"])
      try store.read { (db: Database) throws in
        #expect(try Data.fetchOne(db, sql: "SELECT CAST(\(field) AS BLOB) FROM doc_rev") == bytes)
        let current = try Data.fetchOne(db, sql: "SELECT CAST(\(field) AS BLOB) FROM doc")
        #expect(current == bytes)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_rev") == 1)
      }
    }
  }
}
