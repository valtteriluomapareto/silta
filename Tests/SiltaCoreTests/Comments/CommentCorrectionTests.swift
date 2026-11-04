import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct CommentCorrectionTests {
  @Test func currentClaimerCanAcceptAfterAskerHandoff() async throws {
    await withKnownIssue("#13: reproduce SI-29 round 1 finding") {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try await CommentTests.setup(home, clock: clock)
      let asker = TaskService(environment: env)
      _ = try CommentQuestionTests.post(asker, kind: "question")
      _ = try CommentQuestionTests.post(asker, kind: "handoff")
      let resumed = TaskService(environment: try TaskServiceTests.environment(
        home, actor: .agent(tool: "claude", session: "resumed"), clock: clock))
      _ = try await resumed.start("AC-1", directory: home)
      _ = try CommentQuestionTests.post(resumed, kind: "answer", reply: "AC-1/1")
      clock.advance(milliseconds: 1000)
      _ = try resumed.acceptComment("AC-1/3")
      let shown = try resumed.show("AC-1", timeline: true)
      #expect(shown.comments?.first?.resolvedBy == "agent:claude:resumed")
      #expect(shown.timeline?.last?.actor == "agent:claude:resumed")
      #expect(shown.claimedAt == TaskService.timestamp(clock.now()))
    }
  
    }
  }

  @Test(arguments: ["`@agent:<tool>:<session>`", "``@human:acme``", "```text\n@agent:<tool>:<session>\n```", "~~~\n@me-other\n~~~"])
  func codeExamplesAreNotRecipients(body: String) async throws {
    await withKnownIssue("#13: reproduce SI-29 round 1 finding") {

      try await withScratchDirectory { home in
        let service = TaskService(environment: try await CommentTests.setup(home))
        #expect(try CommentQuestionTests.post(service, body: body).mentions.isEmpty)
      }
    
    
  
    }
  }

  @Test func malformedRecipientIdentifiesSafeToken() async throws {
    await withKnownIssue("#13: reproduce SI-29 round 1 finding") {
    try await withScratchDirectory { home in
      let service = TaskService(environment: try await CommentTests.setup(home))
      do {
        _ = try CommentQuestionTests.post(service, body: "Ask @agent:codex")
        Issue.record("Tool-only actor accepted")
      } catch let error as CommentError {
        #expect(error.message.contains("agent:codex"))
      }
    }
  
    }
  }
}
