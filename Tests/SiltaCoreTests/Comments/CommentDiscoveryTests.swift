import Foundation
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct CommentDiscoveryTests {
  @Test func olderHandoffRepliesRemainDiscoverable() async throws {
    try await withScratchDirectory { home in
      let env = try await CommentTests.setup(home)
      let service = TaskService(environment: env)
      _ = try service.comment("AC-1", CommentDraft(body: "Earlier context", kind: "handoff"))
      _ = try service.comment("AC-1", CommentDraft(body: "Latest context", kind: "handoff"))
      let reviewer = TaskService(
        environment: try TaskServiceTests.environment(
          home, actor: .agent(tool: "claude", session: "reviewer")))
      _ = try reviewer.updateComments(["AC-1/1"], action: .resolve, explanation: "Reviewer finding")
      _ = try reviewer.updateComments(["AC-1/1"], action: .reopen)
      let shown = try #require(service.show("AC-1").comments)
      #expect(shown.map(\.ref) == ["AC-1/2", "AC-1/1", "AC-1/3"])
      #expect(shown.contains { $0.body == "Reviewer finding" })
      #expect(try service.show("AC-1", timeline: true).comments?.count == 3)
    }
  }
}
