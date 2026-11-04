import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct CommentEventTests {
  @Test(arguments: ["comment", "decision", "handoff", "redacted"])
  func ownPostsNameEventsAndSignalTaskChanges(kind: String) async throws {
    await withKnownIssue("#13: Comment effects must identify their post and signal task writes") {
      try await withScratchDirectory { home in
        let clock = FakeClock(now: TaskServiceTests.now)
        let env = try await CommentTests.setup(home, clock: clock)
        let service = TaskService(environment: env)
        _ = try await service.start("AC-1", directory: home)
        let before = try env.db.read {
          try #require(
            try Int.fetchOne($0, sql: "SELECT count(*) FROM change_log WHERE kind='task'"))
        }
        clock.advance(milliseconds: 1000)
        _ = try service.comment(
          "AC-1",
          CommentDraft(
            body: kind == "redacted" ? "Pwd=" + "acme-value" : "Acme context",
            kind: kind == "redacted" ? "comment" : kind))
        let shown = try service.show("AC-1", timeline: true)
        #expect(
          try env.db.read {
            try #require(
              try Int.fetchOne($0, sql: "SELECT count(*) FROM change_log WHERE kind='task'"))
          } > before)
        if kind == "handoff" {
          #expect(
            shown.timeline?.filter { $0.kind == "claim" }.map(\.body) == [nil, "released AC-1/1"])
        }
        if kind == "redacted" {
          #expect(shown.timeline?.last { $0.kind == "secret_redacted" }?.body == "AC-1/1")
        }
      }
    }
  }
}
