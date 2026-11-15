import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocEditObservationTests {
  @Test(arguments: [false, true])
  func gitFailureOrTimeoutLeavesEvidenceUnknown(timeout: Bool) async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try DocVerificationPreparationTests.setup(home)
      let git = ScriptedGitRunner(script: [
        (
          DocVerificationPreparationTests.request("origin/api", repo: repo),
          .success(GitResult(termination: timeout ? .timedOut : .signal(9)))
        )
      ])
      let result = try await DocWritePolicyTests.service(home, store, git: git)
        .edit(DocEditRequest(slug: "rules", title: "Rules", about: ["app:api"])) {
          "Complete body"
        }
      #expect(result.ref == "doc:rules@1" && result.warnings.isEmpty && result.approvalUsed)
      let evidence = try DocPartialCloneTests.latest(store)
      #expect(evidence.stamp == "unknown" && evidence.evidence == "[]")
      try store.read { (db: Database) throws in
        let revision = try DocStore.revision("rules", revision: 1, workspace: 1, in: db)
        #expect(
          revision.body == "Complete body" && revision.actor == DocStoreTests.actor.description)
        #expect(
          try String.fetchOne(db, sql: "SELECT actor FROM approval WHERE command LIKE '%doc edit%'")
            == DocStoreTests.actor.description)
        #expect(
          try String.fetchOne(db, sql: "SELECT words FROM approval WHERE command LIKE '%doc edit%'")
            == "Keep the rules")
      }
      #expect(git.isExhausted && git.requests.count == 1)
    }
  }
}
