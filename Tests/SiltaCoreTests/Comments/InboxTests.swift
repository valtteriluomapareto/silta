import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct InboxTests {
  @Test(arguments: ["human:acme", "agent:claude:recipient", "agent:codex:outsider"])
  func sharedAnsweredAndAcceptanceFollowLiveState(answerer: String) async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try await CommentTests.setup(home, clock: clock)
      let owner = TaskService(environment: env)
      var question = CommentDraft(body: "Which API?", kind: "question")
      question.recipients = ["human:acme", "agent:claude:recipient"]
      _ = try owner.comment("AC-1", question)
      let responder = TaskService(
        environment: try TaskServiceTests.environment(
          home, actor: #require(ActorID.parse(answerer)), clock: clock))
      clock.advance(milliseconds: 1)
      var answer = CommentDraft(body: "v2", kind: "answer")
      answer.replyTo = "AC-1/1"
      _ = try responder.comment("AC-1", answer)
      let qualifies = answerer != "agent:codex:outsider"
      #expect(try owner.show("AC-1").comments?.first?.answered == qualifies)
      #expect(try owner.inbox(for: "human:acme").items.map(\.ref) == (qualifies ? [] : ["AC-1/1"]))
      #expect(try owner.inbox().items.map(\.kind) == ["answer"])
      _ = try owner.comment("AC-1", CommentDraft(body: "Resume", kind: "handoff"))
      let successor = TaskService(
        environment: try TaskServiceTests.environment(
          home, actor: .agent(tool: "codex", session: "successor"), clock: clock))
      _ = try await successor.start("AC-1", directory: home)
      #expect(try successor.inbox().items.map(\.ref) == ["AC-1/2"])
      #expect(try owner.inbox().items.map(\.ref) == ["AC-1/2"])
      _ = try successor.acceptComment("AC-1/2")
      #expect(try successor.inbox().items.isEmpty)
      _ = try successor.updateComments(["AC-1/1"], action: .reopen)
      #expect(try successor.inbox().items.map(\.ref) == ["AC-1/2"])
      _ = try responder.updateComments(["AC-1/2"], action: .delete)
      #expect(try owner.show("AC-1").comments?.first?.answered == false)
      #expect(try owner.inbox(for: "human:acme").items.map(\.ref) == ["AC-1/1"])
      _ = try owner.updateComments(["AC-1/1"], action: .delete)
      #expect(try owner.inbox(for: "human:acme").items.isEmpty)
    }
  }

  @Test func claimedDiscussionUsesStrictOwnWriteBoundaryAndReadsNeverWrite() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try await CommentTests.setup(home, clock: clock), owner = TaskService(environment: env)
      let other = TaskService(
        environment: try TaskServiceTests.environment(
          home, actor: .agent(tool: "codex", session: "other"), clock: clock))
      clock.advance(milliseconds: -1)
      _ = try other.comment("AC-1", CommentDraft(body: "Before"))
      clock.advance(milliseconds: 1)
      _ = try other.comment("AC-1", CommentDraft(body: "Equal"))
      clock.advance(milliseconds: 1)
      _ = try other.comment("AC-1", CommentDraft(body: "After"))
      clock.advance(milliseconds: 1)
      _ = try other.updateComments(["AC-1/3"], action: .resolve)
      clock.advance(milliseconds: 7_200_000)
      _ = try other.link("AC-1", target: "url:https://example.com/acme")
      #expect(try owner.inbox().items.map(\.ref) == ["AC-1/3"])
      let stable = try CommentLifecycleTests.snapshot(env)
      for _ in 0..<2 {
        #expect(try owner.inbox().items.map(\.ref) == ["AC-1/3"])
      }
      #expect(try CommentLifecycleTests.snapshot(env) == stable)
      _ = try owner.plan("AC-1", text: "Work")
      #expect(try owner.inbox().items.isEmpty)
      clock.advance(milliseconds: 1)
      _ = try owner.comment("AC-1", CommentDraft(body: "Own"))
      #expect(try owner.inbox().items.isEmpty)
      _ = try other.updateComments(["AC-1/3"], action: .delete)
      #expect(try owner.inbox().items.isEmpty)
    }
  }

  @Test func categoryOrderCapAllAndWorkspacePromotedIsolation() async throws {
    try await withScratchDirectory { home in
      let env = try await CommentTests.setup(home), owner = TaskService(environment: env)
      let other = TaskService(
        environment: try TaskServiceTests.environment(home, actor: .human(name: "acme")))
      var question = CommentDraft(body: "Self", kind: "question")
      question.recipients = [env.actor.description]
      _ = try owner.comment("AC-1", question)
      var answer = CommentDraft(body: "v2", kind: "answer")
      answer.replyTo = "AC-1/1"
      _ = try other.comment("AC-1", answer)
      for _ in 0..<13 { _ = try other.comment("AC-1", question) }
      let result = try owner.inbox()
      #expect(result.items.map(\.ref) == (3...14).map { "AC-1/\($0)" })
      #expect(result.remaining == 2 && result.more == "silta --ws 'acme' inbox --for 'agent:codex:acme' --all")
      let all = try owner.inbox(all: true)
      #expect(all.items.map(\.ref) == (3...15).map { "AC-1/\($0)" } + ["AC-1/2"])
      #expect(all.remaining == 0 && all.more == nil)
      #expect(try owner.inbox(for: "agent:codex:another").items.isEmpty)
      try env.db.write {
        try $0.database.execute(sql: "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('other','other','Other','OT')")
      }
      #expect(try TaskService(environment: env, workspace: "other").inbox().items.isEmpty)
      try env.db.write { try $0.database.execute(sql: "UPDATE task SET external_ref='ado:42'") }
      #expect(try owner.inbox().items.isEmpty)
    }
  }

  @Test func closedFencePreservesFollowingMentionAndResolvedHandoffCounts() async throws {
    try await withScratchDirectory { home in
      let owner = TaskService(environment: try await CommentTests.setup(home))
      let draft = CommentDraft(body: "```\n@human:hidden\n```\nAsk @agent:claude:reader", kind: "question")
      #expect(try owner.comment("AC-1", draft).comment.mentions == ["agent:claude:reader"])
      _ = try owner.comment("AC-1", CommentDraft(body: "Resume", kind: "handoff"))
      _ = try owner.updateComments(["AC-1/2"], action: .resolve)
      let shown = try owner.show("AC-1")
      #expect(shown.comments?.first?.ref == "AC-1/2" && shown.resolvedThreads == 1)
    }
  }
}
