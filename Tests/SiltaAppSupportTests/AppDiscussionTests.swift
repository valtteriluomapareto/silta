#if DEBUG
  import Foundation
  @testable import SiltaAppSupport
  @testable import SiltaCore
  import SiltaTestSupport
  import Testing

  /// Threads the inspector draws: open threads from Core's normal read, resolved ones
  /// from the timeline, and replies posted into a thread.
  @Suite(.blockingTestWork)
  struct AppDiscussionTests {
    @Test func openThreadsKeepRepliesAndResolvedThreadsComeSeparately() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let task = try AppWriterTests.reader(scratch).task("AC-9", workspace: "acme")
        #expect(task.comments.map(\.ref) == ["AC-9/1", "AC-9/2"])
        #expect(task.comments[1].replyTo == "AC-9/1")
        #expect(task.comments.allSatisfy { $0.resolvedAt == nil })
        #expect(task.resolvedComments.map(\.ref) == ["AC-9/3", "AC-9/4"])
        let resolved = try #require(task.resolvedComments.first)
        #expect(resolved.resolvedAt != nil && resolved.resolvedBy == "agent:claude:review")
        #expect(task.resolvedComments[1].replyTo == "AC-9/3")
      }
    }

    @Test func aTaskWithoutResolvedThreadsHasNone() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let task = try AppWriterTests.reader(scratch).task("AC-12", workspace: "acme")
        #expect(task.resolvedComments.isEmpty)
        #expect(task.comments.first?.mentions == ["human:acme"])
      }
    }

    @Test func anEmptyDeletedResolvedRootStaysHidden() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        let reviewer = AppWriterTests.agent(reader, .agent(tool: "claude", session: "review"))
        let note = try reviewer.comment("AC-9", CommentDraft(body: "Scratch note."))
        _ = try reviewer.updateComments([note.comment.ref], action: .resolve)
        _ = try reviewer.updateComments([note.comment.ref], action: .delete)
        let task = try reader.task("AC-9", workspace: "acme")
        #expect(task.resolvedComments.map(\.ref) == ["AC-9/3", "AC-9/4"])
      }
    }

    @Test func acceptingAnAnswerMovesItsThreadToResolved() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        #expect(try reader.task("AC-14", workspace: "acme").comments.last?.accepted == false)
        try AppWriter(reader: reader).perform(.acceptAnswer(ref: "AC-14/2"), workspace: "acme")
        let task = try reader.task("AC-14", workspace: "acme")
        #expect(task.comments.isEmpty)
        #expect(task.resolvedComments.map(\.ref) == ["AC-14/1", "AC-14/2"])
        #expect(task.resolvedComments.last?.accepted == true)
      }
    }

    @Test func aReplyLandsInItsThreadAsTheHuman() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppWriterTests.reader(scratch)
        try AppWriter(reader: reader).perform(
          .comment(task: "AC-9", body: "Thanks, merging.", replyTo: "AC-9/1"), workspace: "acme")
        let comments = try reader.task("AC-9", workspace: "acme").comments
        #expect(comments.map(\.ref) == ["AC-9/1", "AC-9/2", "AC-9/5"])
        #expect(comments.last?.replyTo == "AC-9/1" && comments.last?.actor == "human:acme")
      }
    }
  }
#endif
