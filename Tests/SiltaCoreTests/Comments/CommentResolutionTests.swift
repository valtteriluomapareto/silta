import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct CommentResolutionTests {
  @Test func changedRootsAttributeResolutionAndReopening() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try await CommentTests.setup(home, clock: clock)
      let owner = TaskService(environment: env)
      for _ in 0..<2 { _ = try owner.comment("AC-1", CommentDraft(body: "Finding")) }
      let reviewer = TaskService(
        environment: try TaskServiceTests.environment(
          home, actor: .agent(tool: "codex", session: "reviewer"), clock: clock))
      let coordinator = TaskService(
        environment: try TaskServiceTests.environment(
          home, actor: .agent(tool: "claude", session: "coordinator"), clock: clock))
      clock.advance(milliseconds: 1000)
      _ = try reviewer.updateComments(["AC-1/1", "AC-1/2"], action: .resolve, explanation: "Fixed")
      _ = try reviewer.updateComments(["AC-1/1", "AC-1/2"], action: .resolve)
      clock.advance(milliseconds: 1000)
      _ = try coordinator.updateComments(["AC-1/1"], action: .reopen)
      let events =
        try owner.show("AC-1", timeline: true).timeline?.filter { $0.kind == "discussion" } ?? []
      #expect(events.map(\.body) == ["resolved AC-1/1", "resolved AC-1/2", "reopened AC-1/1"])
      #expect(
        events.map(\.actor) == [
          "agent:codex:reviewer", "agent:codex:reviewer", "agent:claude:coordinator",
        ])
      #expect(
        events.map(\.at) == [
          "2023-11-14T22:13:21.000Z", "2023-11-14T22:13:21.000Z", "2023-11-14T22:13:22.000Z",
        ])
    }
  }

  @Test func deletePreservesResolutionAndReopenClearsBothFields() async throws {
    try await withScratchDirectory { home in
      let env = try await CommentTests.setup(home)
      let owner = TaskService(environment: env)
      _ = try owner.comment("AC-1", CommentDraft(body: "Finding"))
      let reviewer = TaskService(
        environment: try TaskServiceTests.environment(
          home, actor: .agent(tool: "codex", session: "reviewer")))
      _ = try reviewer.updateComments(["AC-1/1"], action: .resolve)
      let before = try env.db.read {
        try #require(
          try Row.fetchOne($0, sql: "SELECT resolved_at,resolved_by FROM comment WHERE seq=1"))
      }
      #expect(before["resolved_by"] as String? == "agent:codex:reviewer")
      #expect(before["resolved_at"] as String? != nil)
      _ = try owner.updateComments(["AC-1/1"], action: .delete)
      let deleted = try env.db.read {
        try #require(
          try Row.fetchOne($0, sql: "SELECT resolved_at,resolved_by FROM comment WHERE seq=1"))
      }
      #expect(deleted == before)
      _ = try reviewer.updateComments(["AC-1/1"], action: .reopen)
      let reopened = try env.db.read {
        try #require(
          try Row.fetchOne($0, sql: "SELECT resolved_at,resolved_by FROM comment WHERE seq=1"))
      }
      #expect(
        reopened["resolved_at"] as String? == nil && reopened["resolved_by"] as String? == nil)
    }
  }
}
