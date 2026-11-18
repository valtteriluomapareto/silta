#if DEBUG
  import Foundation
  @testable import SiltaApp
  @testable import SiltaAppSupport
  import Testing

  @MainActor struct MyWorkContentTests {
    @Test func groupsQuestionsReviewsAndEachProposalOnce() throws {
      try fixture { reader, _ in
        let snapshot = try reader.snapshot(workspace: "acme")
        let content = MyWorkContent(snapshot: snapshot, search: "", now: AppV2Fixture.now)
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
        #expect(content.reviews.first?.metadata.contains("step 4 of 4 · PR #41") == true)
        let order = content.documents.first { $0.ref == "doc:order-contract@3" }
        #expect(order?.metadata.contains("from AC-9") == true)
        #expect(content.hasMatches && content.remaining == 0 && snapshot.work.waitingCount == 7)
      }
    }

    @Test func searchKeepsCanonicalRefsAndDoesNotChangeWaitingCounts() throws {
      try fixture { reader, _ in
        let snapshot = try reader.snapshot(workspace: "acme")
        let selected = MyWorkContent(
          snapshot: snapshot, search: "doc:order-contract@3", now: AppV2Fixture.now)
        #expect(selected.documents.map(\.ref) == ["doc:order-contract@3"])
        #expect(selected.questions.isEmpty && selected.reviews.isEmpty && selected.tasks.isEmpty)
        #expect(
          !MyWorkContent(snapshot: snapshot, search: "AC-1", now: AppV2Fixture.now).hasMatches)
        #expect(snapshot.work.waitingCount == 7)
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

    @Test func pullRequestLinksStayExplicitAndSafe() {
      let safe = "https://github.com/acme/example/pull/41"
      #expect(
        MyWorkContent.pullRequest(
          ["url:https://github.com/acme/example/issues/41", "url:" + safe].map {
            AppTaskLink(rel: "about", target: $0)
          })?
          .absoluteString == safe)
      for link in [
        "url:file:///tmp/pull/41", "url:https://user:password@github.com/acme/example/pull/41",
        "url:" + safe + "?token=secret", "url:https://github.com/acme/example/pull/not-a-number",
      ] {
        #expect(MyWorkContent.pullRequest([AppTaskLink(rel: "about", target: link)]) == nil)
      }
    }

    @Test func citedPullRequestsCannotBecomeTheTasksOwnPR() throws {
      try fixture { reader, home in
        @MainActor func link(_ number: Int, _ relation: String, seed: Int) throws {
          try AppTestCLI.run(
            [
              "--ws", "acme", "task", "link", "AC-21",
              "url:https://github.com/acme/example/pull/\(number)", "--rel", relation,
            ], home: home, seed: seed)
        }
        try link(99, "cites", seed: 401)
        let cited = try reader.task("AC-21", workspace: "acme")
        #expect(
          MyWorkContent.pullRequest(cited.links) == nil)
        try link(41, "about", seed: 402)
        let own = try reader.task("AC-21", workspace: "acme")
        #expect(
          MyWorkContent.pullRequest(own.links)?
            .lastPathComponent == "41")
        try link(42, "about", seed: 403)
        let ambiguous = try reader.task("AC-21", workspace: "acme")
        #expect(
          MyWorkContent.pullRequest(ambiguous.links) == nil)
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
        let content = MyWorkContent(snapshot: snapshot, search: "", now: AppV2Fixture.now)
        #expect(content.questions.count == 12 && content.remaining == 7)
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
