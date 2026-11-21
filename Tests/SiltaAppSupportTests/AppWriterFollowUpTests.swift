#if DEBUG
  import Foundation
  @testable import SiltaAppSupport
  @testable import SiltaCore
  import SiltaTestSupport
  import Testing

  /// Snoozing, unblocking anyway and dropping blocked tasks through the app's writer.
  @Suite(.blockingTestWork)
  struct AppWriterFollowUpTests {
    @Test func snoozeMovesTheFollowUpAndKeepsBlockersAndReason() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        let before = try reader.task("AC-17", workspace: "acme")
        try AppWriter(reader: reader).perform(.snooze(ref: "AC-17", days: 14), workspace: "acme")
        let after = try reader.task("AC-17", workspace: "acme")
        #expect(after.status == "blocked" && after.followUpAt == "2026-11-30")
        #expect(after.waiting?.on == before.waiting?.on)
        #expect(after.waiting?.why == before.waiting?.why)
        let refused = try AppWriterTests.failure {
          try AppWriter(reader: reader).perform(.snooze(ref: "AC-15", days: 7), workspace: "acme")
        }
        #expect(try reader.task("AC-15", workspace: "acme").status == "todo")
        _ = refused
      }
    }

    @Test func unblockAnywayReturnsATaskWithAnOpenBlockerToTodo() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        var block = TaskBlock(why: "Needs the final copy.")
        block.on = ["ext:design-team"]
        _ = try AppWriterTests.agent(reader, .human(name: "acme")).block("AC-16", block)
        try AppWriter(reader: reader).perform(.unblockAnyway(ref: "AC-16"), workspace: "acme")
        let task = try reader.task("AC-16", workspace: "acme")
        #expect(task.status == "todo" && task.waiting == nil)
        #expect(!task.links.contains { $0.rel == "blocked_by" })
      }
    }

    @Test func droppingATaskRecordsTheReasonAndLogsIt() async throws {
      try await withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        try await AppWriter(reader: reader).send(
          .dropTask(ref: "AC-17", why: "The banner moved to the web shop."), workspace: "acme")
        let task = try reader.task("AC-17", workspace: "acme")
        #expect(task.status == "dropped" && task.result == "The banner moved to the web shop.")
        let log = try String(
          contentsOf: scratch.appending(path: "silta-home/log/2026-11-16.jsonl"), encoding: .utf8)
        #expect(log.contains("\"command\":\"app drop\"") && !log.contains("web shop"))
      }
    }

    @Test func dropNeedsTheAsyncPath() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        let refused = try AppWriterTests.failure {
          try AppWriter(reader: reader).perform(
            .dropTask(ref: "AC-17", why: nil), workspace: "acme")
        }
        _ = refused
        #expect(try reader.task("AC-17", workspace: "acme").status == "blocked")
      }
    }

    @Test func dueAndReplanItemsCarryTheirBlockedTasks() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let later = try AppReader(
          home: scratch.appending(path: "silta-home"), user: AppV2Fixture.user,
          now: { AppV2Fixture.now.addingTimeInterval(8 * 86_400) })
        var block = TaskBlock(why: "Needs the final copy.")
        block.on = ["ext:design-team"]
        _ = try AppWriterTests.agent(later, .human(name: "acme")).block("AC-16", block)
        let due = try #require(
          try later.snapshot(workspace: "acme").work.items.first { $0.kind == "due" })
        #expect(due.blocked.map(\.ref) == ["AC-16"])
        #expect(due.blocked.first?.followUpAt == "2026-11-23")
        #expect(due.blocked.first?.on == ["ext:design-team"])
      }
    }
  }
#endif
