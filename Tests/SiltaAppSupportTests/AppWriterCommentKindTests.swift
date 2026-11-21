#if DEBUG
  import Foundation
  @testable import SiltaAppSupport
  @testable import SiltaCore
  import SiltaTestSupport
  import Testing

  /// Comments that steer agents, and resolving threads, through the app's writer.
  @Suite(.blockingTestWork)
  struct AppWriterCommentKindTests {
    @Test func aDecisionLandsAsADecisionFromTheHuman() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        try AppWriter(reader: reader).perform(
          .comment(task: "AC-14", body: "Keep the queue on logout.", kind: "decision"),
          workspace: "acme")
        let posted = try #require(try reader.task("AC-14", workspace: "acme").comments.last)
        #expect(posted.kind == "decision" && posted.actor == "human:acme")
      }
    }

    @Test func aQuestionToAnAgentWaitsInThatAgentsInbox() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        try AppWriter(reader: reader).perform(
          .comment(
            task: "AC-14", body: "Does the queue clear when notifications are off?",
            kind: "question", to: ["agent:codex:fixture"]),
          workspace: "acme")
        let posted = try #require(try reader.task("AC-14", workspace: "acme").comments.last)
        #expect(posted.kind == "question" && posted.mentions.contains("agent:codex:fixture"))
        let codex = AppWriterTests.agent(reader, .agent(tool: "codex", session: "fixture"))
        #expect(try codex.inbox().items.contains { $0.kind == "question" && $0.ref == posted.ref })
      }
    }

    @Test func resolvingAndReopeningAThreadLogsEach() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        let open = try #require(
          try reader.task("AC-9", workspace: "acme").comments.first { $0.resolvedAt == nil })
        try AppWriter(reader: reader).perform(.resolveThreads(refs: [open.ref]), workspace: "acme")
        let resolved = try reader.task("AC-9", workspace: "acme")
        #expect(resolved.resolvedComments.contains { $0.ref == open.ref })
        #expect(!resolved.comments.contains { $0.ref == open.ref && $0.resolvedAt == nil })
        try AppWriter(reader: reader).perform(.reopenThreads(refs: [open.ref]), workspace: "acme")
        let reopened = try reader.task("AC-9", workspace: "acme")
        #expect(reopened.comments.contains { $0.ref == open.ref && $0.resolvedAt == nil })
        let log = try String(
          contentsOf: scratch.appending(path: "silta-home/log/2026-11-16.jsonl"), encoding: .utf8)
        #expect(log.contains("\"command\":\"app resolve\""))
        #expect(log.contains("\"command\":\"app reopen\""))
      }
    }
  }
#endif
