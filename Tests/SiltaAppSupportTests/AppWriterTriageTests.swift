#if DEBUG
  import Foundation
  @testable import SiltaAppSupport
  @testable import SiltaCore
  import SiltaTestSupport
  import Testing

  /// Accepting task proposals and unblocking ready tasks through the app's writer.
  @Suite(.blockingTestWork)
  struct AppWriterTriageTests {
    static func status(_ reader: AppReader, _ ref: String) throws -> String {
      try reader.task(ref, workspace: "acme").status
    }

    @Test func acceptingProposalsAcceptsOnlyTheChosenRefs() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        try AppWriter(reader: reader).perform(
          .acceptProposals(refs: ["AC-21", "AC-22"]), workspace: "acme")
        #expect(try Self.status(reader, "AC-21") == "todo")
        #expect(try Self.status(reader, "AC-22") == "todo")
        #expect(try Self.status(reader, "AC-23") == "proposed")
      }
    }

    @Test func aProposalAcceptedElsewhereFailsTheWholeBatch() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        var batch = TaskTriage()
        batch.accept = ["AC-21"]
        _ = try AppWriterTests.agent(reader, .human(name: "acme")).triage(batch)
        let refused = try AppWriterTests.failure {
          try AppWriter(reader: reader).perform(
            .acceptProposals(refs: ["AC-21", "AC-22"]), workspace: "acme")
        }
        #expect(refused.code == .conflict)
        #expect(try Self.status(reader, "AC-22") == "proposed")
        let log = try String(
          contentsOf: scratch.appending(path: "silta-home/log/2026-11-16.jsonl"), encoding: .utf8)
        #expect(log.contains("\"command\":\"app triage\"") && log.contains("\"conflict\""))
      }
    }

    @Test func aBlockerAddedSinceTheReadKeepsTheTaskBlocked() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        #expect(try reader.snapshot(workspace: "acme").work.items.contains { $0.kind == "ready" })
        var block = TaskBlock(why: "Also needs pagination.")
        block.on = ["AC-16"]
        _ = try AppWriterTests.agent(reader, .agent(tool: "claude", session: "fixture"))
          .block("AC-17", block)
        let refused = try AppWriterTests.failure {
          try AppWriter(reader: reader).perform(.unblock(ref: "AC-17"), workspace: "acme")
        }
        #expect(refused.code == .blocked)
        #expect(try Self.status(reader, "AC-17") == "blocked")
      }
    }

    @Test func unblockingAReadyTaskReturnsItToTodo() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        let ready = try #require(
          try reader.snapshot(workspace: "acme").work.items.first { $0.kind == "ready" })
        #expect(ready.refs == ["AC-17"])
        try AppWriter(reader: reader).perform(.unblock(ref: "AC-17"), workspace: "acme")
        #expect(try Self.status(reader, "AC-17") == "todo")
        #expect(
          !(try reader.snapshot(workspace: "acme").work.items.contains { $0.kind == "ready" }))
        let log = try String(
          contentsOf: scratch.appending(path: "silta-home/log/2026-11-16.jsonl"), encoding: .utf8)
        #expect(log.contains("\"command\":\"app unblock\""))
      }
    }
  }
#endif
