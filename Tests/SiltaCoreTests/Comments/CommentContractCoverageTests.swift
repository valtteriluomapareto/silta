import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct CommentContractCoverageTests {
  @Test func nonAnswerReplyCannotBeAccepted() async throws {
    try await withScratchDirectory { home in
      let env = try await CommentTests.setup(home), service = TaskService(environment: env)
      _ = try CommentQuestionTests.post(service, kind: "question")
      _ = try CommentQuestionTests.post(service, reply: "AC-1/1")
      let stable = try CommentLifecycleTests.snapshot(env)
      #expect(throws: CommentError.self) { _ = try service.acceptComment("AC-1/2") }
      #expect(try CommentLifecycleTests.snapshot(env) == stable)
    }
  }

  @Test func emailsSecretsAndFourPartActorsStayOutOfRecipients() async throws {
    try await withScratchDirectory { home in
      let env = try await CommentTests.setup(home), service = TaskService(environment: env)
      #expect(try CommentQuestionTests.post(service, body: "x@me.com").mentions.isEmpty)
      let secret = "AKIA" + String(repeating: "A", count: 16)
      do {
        _ = try CommentQuestionTests.post(service, to: ["human:" + secret])
        Issue.record("Secret-shaped recipient accepted")
      } catch let error as CommentError { #expect(!error.message.contains(secret)) }
      #expect(ActorID.parse("agent:codex:s:x") == nil)
      #expect(throws: CommentError.self) {
        _ = try CommentQuestionTests.post(service, to: ["agent:codex:s:x"])
      }
      #expect(throws: CommentError.self) {
        _ = try CommentQuestionTests.post(service, body: "Ask @agent:codex:s:x")
      }
    }
  }

  @Test func acceptAndReopenRecordChangedRowsAndOwnHeartbeat() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try await CommentTests.setup(home, clock: clock),
        service = TaskService(environment: env)
      _ = try CommentQuestionTests.post(service, kind: "question")
      _ = try CommentQuestionTests.post(service, kind: "answer", reply: "AC-1/1")
      func changes() throws -> [Int64] {
        try env.db.read {
          try Int64.fetchAll(
            $0, sql: "SELECT row_id FROM change_log WHERE kind='comment' ORDER BY seq")
        }
      }
      let ids = try env.db.read {
        try Int64.fetchAll($0, sql: "SELECT id FROM comment ORDER BY seq")
      }
      try #require(ids.count == 2)
      let before = try changes().count
      clock.advance(milliseconds: 1000)
      _ = try service.acceptComment("AC-1/2")
      #expect(Array(try changes().dropFirst(before)) == [ids[1], ids[0]])
      #expect(try service.show("AC-1").claimedAt == TaskService.timestamp(clock.now()))
      let accepted = try changes().count
      clock.advance(milliseconds: 1000)
      _ = try service.updateComments(["AC-1/1"], action: .reopen)
      #expect(Array(try changes().dropFirst(accepted)) == [ids[1], ids[0]])
    }
  }

  @Test func deletedAnswerStopsCounting() async throws {
    try await withScratchDirectory { home in
      let env = try await CommentTests.setup(home), service = TaskService(environment: env)
      _ = try CommentQuestionTests.post(service, kind: "question", to: [env.actor.description])
      _ = try CommentQuestionTests.post(service, kind: "answer", reply: "AC-1/1")
      #expect(try service.show("AC-1").comments?.first?.answered == true)
      _ = try service.updateComments(["AC-1/2"], action: .delete)
      #expect(try service.show("AC-1").comments?.first?.answered == false)
    }
  }
}
