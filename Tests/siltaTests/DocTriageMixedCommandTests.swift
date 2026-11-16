import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocTriageMixedCommandTests {
  @Test(arguments: ["text", "json", "quiet"])
  func staleOriginalsCanBeRejectedWithTheirAcceptedReplacement(mode: String) throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let file = try DocEditCommandTests.input(scratch)
      try #require(
        try DocEditCommandTests.run(
          ["rules"] + DocEditCommandTests.creation + ["-F", file.path], scratch
        ).termination == .exit(0))
      #expect(try DocTriageCommandTests.propose(scratch) == "doc:rules@2")
      try AcmeDocAttachments.copyLatestRulesProposal(in: store)
      try #require(
        try DocEditCommandTests.run(
          ["rules", "-F", file.path], scratch
        ).termination == .exit(0))
      #expect(try DocTriageCommandTests.propose(scratch) == "doc:rules@5")
      try store.write { try $0.database.execute(sql: "DELETE FROM approval") }
      let result = try DocTriageCommandTests.run(
        ["--accept", "doc:rules@5", "--reject", "doc:rules@2", "doc:rules@3"]
          + (mode == "text" ? [] : ["--" + mode]), scratch)
      #expect(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
      if result.termination == .exit(0) {
        Golden.forTests().check(
          result.stdout, "doc-triage-mixed-" + mode + (mode == "json" ? ".json" : ".txt"))
        #expect(!result.stdout.contains("Shared proposal"))
        if mode == "json" { try DocTriageCommandTests.checkSchema(result, scratch) }
        try store.read { (db: Database) throws in
          #expect(try Int.fetchOne(db, sql: "SELECT current_rev FROM doc") == 5)
          #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_rev") == 5)
          #expect(
            try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_rev WHERE state='rejected'") == 2)
          #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM approval") == 1)
          #expect(
            try Int.fetchOne(
              db,
              sql: """
                SELECT count(*) FROM doc_rev WHERE rev IN (2,3,5)
                  AND actor='agent:codex:acme' AND triaged_by='agent:codex:acme'
                  AND triaged_at IS NOT NULL
                """) == 3)
          #expect(try Int.fetchOne(db, sql: "SELECT count(DISTINCT triaged_at) FROM doc_rev") == 1)
          #expect(
            try String.fetchOne(db, sql: "SELECT body_md FROM doc_rev WHERE rev=5")
              == "Shared proposal.")
        }
      }
    }
  }

}
