#if DEBUG
  import Foundation
  @testable import SiltaApp
  @testable import SiltaAppSupport
  import Testing

  @MainActor struct MyWorkContentTests {
    @Test func groupsQuestionsReviewsAndEachProposalOnce() throws {
      try fixture { reader, _ in
        let snapshot = try reader.snapshot(workspace: "acme")
        let content = MyWorkContent(snapshot: snapshot, apps: [], search: "", now: AppV2Fixture.now)
        #expect(content.questions.count == 1 && content.reviews.count == 1)
        #expect(content.documents.count == 2 && content.tasks.count == 3)
        #expect(Set(content.tasks.map(\.ref)) == ["AC-21", "AC-22", "AC-23"])
        #expect(content.questions.first?.ref == "AC-12")
        #expect(
          content.questions.first?.metadata == "Claude asks you · Parse push categories · 6 min ago"
        )
        let question = snapshot.work.items.first { $0.kind == "question" }
        #expect(content.questions.first?.headline == question?.body)
        let command = content.questions.first?.command(reader: reader, workspace: "acme")
        #expect(command?.text.hasSuffix("-m \"\"") == true)
        #expect(content.reviews.first?.metadata.contains("step 4 of 4") == true)
        let order = content.documents.first { $0.ref == "doc:order-contract@3" }
        #expect(order?.metadata.contains("from AC-9") == true)
        #expect(content.hasMatches && content.remaining == 0 && snapshot.work.waitingCount == 9)
      }
    }

    @Test func answersToTheHumanGetTheirOwnAcceptableCard() throws {
      try fixture { reader, _ in
        let snapshot = try reader.snapshot(workspace: "acme")
        let content = MyWorkContent(snapshot: snapshot, apps: [], search: "", now: AppV2Fixture.now)
        let answer = try #require(content.answers.first)
        #expect(content.answers.count == 1 && answer.item.ref == "AC-14/2")
        #expect(answer.metadata.hasPrefix("Codex answered you · Retry push registrations · "))
        #expect(answer.item.body?.hasPrefix("Yes. After an hour") == true)
        #expect(answer.canAccept(reader: reader, workspace: "acme"))
        #expect(!content.other.contains { $0.kind == "answer" })
        let board = BoardContent(snapshot: snapshot, apps: [], filter: BoardFilter(), search: "")
        #expect(
          board.newestQuestion(for: "AC-12", reader: reader, workspace: "acme")?.question
            == "AC-12/1")
        #expect(board.newestQuestion(for: "AC-15", reader: reader, workspace: "acme") == nil)
      }
    }

    @Test func onlyAReadyItemOffersUnblock() {
      func item(_ kind: String, refs: [String]) -> AppAttention {
        AppAttention(
          kind: kind, target: nil, ref: nil, refs: refs, task: nil, title: nil, author: nil,
          body: nil, createdAt: nil, documentRevision: nil, sourceTask: nil, commands: [])
      }
      #expect(MyWorkContent.unblockRef(item("ready", refs: ["AC-17"])) == "AC-17")
      #expect(MyWorkContent.unblockRef(item("replan", refs: ["AC-17"])) == nil)
      #expect(MyWorkContent.unblockRef(item("due", refs: ["AC-17"])) == nil)
      #expect(MyWorkContent.unblockRef(item("ready", refs: ["AC-17", "AC-18"])) == nil)
    }

    @Test func searchKeepsCanonicalRefsAndDoesNotChangeWaitingCounts() throws {
      try fixture { reader, _ in
        let snapshot = try reader.snapshot(workspace: "acme")
        let selected = MyWorkContent(
          snapshot: snapshot, apps: [], search: "doc:order-contract@3", now: AppV2Fixture.now)
        #expect(selected.documents.map(\.ref) == ["doc:order-contract@3"])
        #expect(selected.questions.isEmpty && selected.reviews.isEmpty && selected.tasks.isEmpty)
        #expect(
          !MyWorkContent(snapshot: snapshot, apps: [], search: "AC-1", now: AppV2Fixture.now)
            .hasMatches)
        #expect(snapshot.work.waitingCount == 9)
      }
    }

    @Test func relativeTimesUseTheReadInstantAndRejectMissingDates() {
      let now = AppV2Fixture.now
      func stamp(_ seconds: TimeInterval) -> String {
        now.addingTimeInterval(-seconds).ISO8601Format(
          Date.ISO8601FormatStyle(includingFractionalSeconds: true))
      }
      for (seconds, expected) in [
        (59.0, "just now"), (60.0, "1 min ago"),
        (3540.0, "59 min ago"), (3600.0, "1 h ago"), (82800.0, "23 h ago"),
        (86400.0, "1 d ago"),
      ] {
        #expect(RelativeAge.text(stamp(seconds), now: now) == expected)
      }
      #expect(RelativeAge.text(stamp(30), now: now) == "just now")
      #expect(RelativeAge.text(stamp(360), now: now) == "6 min ago")
      #expect(RelativeAge.text(stamp(359.999), now: now) == "6 min ago")
      #expect(RelativeAge.text(stamp(7200), now: now) == "2 h ago")
      #expect(RelativeAge.text(stamp(259200), now: now) == "3 d ago")
      #expect(RelativeAge.text(stamp(-60), now: now) == "just now")
      #expect(
        RelativeAge.text(nil, now: now) == nil && RelativeAge.text("unknown", now: now) == nil)
    }

    @Test func genericAboutLinksDoNotProvePullRequestOwnership() throws {
      try fixture { reader, _ in
        let content = MyWorkContent(
          snapshot: try reader.snapshot(workspace: "acme"), apps: [], search: "",
          now: AppV2Fixture.now)
        let review = try #require(content.reviews.first)
        #expect(review.task.links.contains { $0.rel == "about" })
        #expect(!review.metadata.contains("PR #"))
      }
    }

    @Test func citedPullRequestsCannotBecomeTheTasksOwnPR() throws {
      try fixture { reader, home in
        try AppTestCLI.run(
          [
            "--ws", "acme", "task", "link", "AC-9",
            "url:https://github.com/acme/example/pull/99", "--rel", "cites",
          ], home: home, seed: 401)
        let content = MyWorkContent(
          snapshot: try reader.snapshot(workspace: "acme"), apps: [], search: "",
          now: AppV2Fixture.now)
        let review = try #require(content.reviews.first)
        #expect(review.task.links.contains { $0.rel == "cites" && $0.target.hasSuffix("/pull/99") })
        #expect(!review.metadata.contains("PR #"))
      }
    }

    @Test func manyQuestionsKeepTheCoreCapAndTheReadMorePath() throws {
      try fixture { reader, home in
        for index in 0..<13 {
          try AppTestCLI.run(
            [
              "--ws", "acme", "comment", "AC-12", "--kind", "question", "--to", "human:acme", "-m",
              "Acme question",
            ], home: home, seed: 300 + index)
        }
        let snapshot = try reader.snapshot(workspace: "acme")
        let content = MyWorkContent(snapshot: snapshot, apps: [], search: "", now: AppV2Fixture.now)
        #expect(content.questions.count == 11 && content.remaining == 9)
        #expect(snapshot.work.items.count == 12 && snapshot.work.items.first?.kind == "ready")
        #expect(reader.inboxCommand(workspace: "acme").text.hasSuffix("inbox --for me --all"))
      }
    }

    private func fixture(_ body: (AppReader, URL) throws -> Void) throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      try body(reader, home)
    }

  }
#endif
