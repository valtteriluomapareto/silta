#if DEBUG
  import Foundation
  @testable import SiltaAppSupport
  @testable import SiltaCore
  import SiltaTestSupport
  import Testing

  /// Acting on a review through the app's writer: mark done, request changes, drop.
  @Suite(.blockingTestWork)
  struct AppWriterReviewTests {
    @Test func markDoneRecordsTheResultWithoutACommit() async throws {
      try await withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        try await AppWriter(reader: reader).send(
          .markDone(ref: "AC-9", result: "Retries cap at five minutes.\nFriction: none", sha: nil),
          workspace: "acme")
        let task = try reader.task("AC-9", workspace: "acme")
        #expect(task.status == "done" && task.doneSHA == nil)
        #expect(task.result == "Retries cap at five minutes.\nFriction: none")
        let log = try String(
          contentsOf: scratch.appending(path: "silta-home/log/2026-11-16.jsonl"), encoding: .utf8)
        #expect(log.contains("\"command\":\"app done\"") && !log.contains("five minutes"))
      }
    }

    @Test func aMergeCommitWithoutARegisteredCloneIsRefusedAsEnv() async throws {
      try await withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        var failure: AppReadError?
        do {
          try await AppWriter(reader: reader).send(
            .markDone(ref: "AC-9", result: "Done.", sha: "7d03b1f"), workspace: "acme")
        } catch let error as AppReadError {
          failure = error
        }
        #expect(failure?.code == .env)
        #expect(try reader.task("AC-9", workspace: "acme").status == "review")
      }
    }

    @Test func forceDoneCommandRefusesUntilFilled() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppReader(
          home: scratch.appending(path: "silta-home"), user: AppV2Fixture.user,
          now: { AppV2Fixture.now })
        let text = reader.forceDoneCommand(
          task: try reader.task("AC-9", workspace: "acme"), workspace: "acme"
        ).text
        #expect(text.hasSuffix(" task done 'AC-9' --force --sha MERGE_SHA -F RESULT_FILE"))
        #expect(!text.contains("-m"))
      }
    }

    @Test func requestingChangesWaitsInTheSubmittersInbox() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        let submitter = try #require(try reader.task("AC-9", workspace: "acme").submission?.actor)
        try AppWriter(reader: reader).perform(
          .comment(
            task: "AC-9", body: "Changes requested: also cap the queue size.", kind: "question",
            to: [submitter]), workspace: "acme")
        let session = try #require(ActorID.parse(submitter))
        let inbox = try AppWriterTests.agent(reader, session).inbox()
        #expect(inbox.items.contains { $0.kind == "question" && $0.task == "AC-9" })
      }
    }
  }
#endif
