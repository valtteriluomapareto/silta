import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocPendingVisibilityTests {
  @Test(arguments: [false, true])
  func onlyUnpinnedBodyShowsPendingWithUsableArchivedRecovery(archived: Bool) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try DocWritePolicyTests.seed(store)
      let proposals = try DocProposalServiceTests.service(home, store)
      for body in ["Alternative one.", "Alternative two."] {
        _ = try proposals.propose(DocProposalServiceTests.request(), input: { body })
      }
      if archived {
        try store.write {
          _ = try DocStoreTests.writer($0, ids: SeededIDGenerator(seed: 89)).archive("rules")
        }
      }
      let before = try DocVerificationPreparationTests.truth(store)
      let read = DocService(workspace: "acme", store: store)
      let unpinned = try read.show("rules").output
      let pinned = try read.show("doc:rules@1").output
      let explicit = try read.show("rules", revision: 1).output
      let diff = try read.show("rules", diff: true).output
      let comments = try read.show("rules", comments: true).output
      let suffix = archived ? " --archived" : ""
      let command = "silta --ws 'acme' doc ls\(suffix) --offset 0 --limit 20"

      #expect(unpinned.components(separatedBy: "\n")[0].contains("2 pending: " + command))

      #expect(!pinned.contains("pending:") && explicit == pinned)
      #expect(!diff.contains("pending:") && !comments.contains("pending:"))
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  @Test func noPendingLeavesThePinnedBodyUnchanged() throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try DocWritePolicyTests.seed(store)
      let read = DocService(workspace: "acme", store: store)
      #expect(try read.show("rules").output == read.show("doc:rules@1").output)
    }
  }
}
