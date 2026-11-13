import Foundation
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocEditPreparationFailureTests {
  @Test(arguments: [false, true])
  func gitPreparationRecoveryRetainsCommandsAndOwnership(timeout: Bool) async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try DocVerificationPreparationTests.setup(home)
      let git = ScriptedGitRunner(script: [
        (
          DocVerificationPreparationTests.request("origin/api", repo: repo),
          .success(GitResult(termination: timeout ? .timedOut : .signal(9)))
        )
      ])
      let before = try DocVerificationPreparationTests.truth(store)
      do {
        _ = try await DocWritePolicyTests.service(home, store, git: git)
          .edit(DocEditRequest(slug: "rules", title: "Rules", about: ["app:api"])) {
            "Complete body"
          }
        Issue.record("Failed Git preparation accepted a document")
      } catch let error as any CodedError {
        #expect(error.code == .env)
        withKnownIssue("SI-105/5: Git preparation recovery metadata is replaced by an edit retry") {
          #expect(
            error.next
              == (timeout ? ["silta code ls --help"] : ["silta --ws 'acme' repo fetch 'platform'"]))
          #expect(error.nextBy == (timeout ? .agent : .human))
          #expect(error.retryAfter == nil)
          #expect((error as? any WarnedFailure)?.warnings ?? [] == [])
        }
      }
      #expect(git.isExhausted && git.requests.count == 1)
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }
}
