#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct BoardContentTests {
    @Test func lanesFilterAppsAndKeepProposalsOptional() throws {
      try fixture { snapshot in
        let ordinary = BoardContent(snapshot: snapshot, app: nil, search: "", proposals: false)
        #expect(ordinary.lanes.map { $0.tasks.count } == [4, 2, 1, 4])
        let mobile = BoardContent(
          snapshot: snapshot, app: "acme-mobile", search: "", proposals: true)
        #expect(mobile.lanes.map { $0.tasks.count } == [2, 2, 0, 2])
        #expect(mobile.lanes[0].tasks.contains { $0.ref == "AC-22" && $0.status == "proposed" })
        #expect(mobile.lanes.flatMap(\.tasks).allSatisfy { $0.app == "acme-mobile" })
      }
    }

    @Test func searchFindsCanonicalRefsAndTitlesAndQuestionMarkers() throws {
      try fixture { snapshot in
        let content = BoardContent(snapshot: snapshot, app: nil, search: "ac-12", proposals: true)
        #expect(content.lanes.flatMap(\.tasks).map(\.ref) == ["AC-12"])
        #expect(content.questions == ["AC-12"])
        let colliding = BoardContent(snapshot: snapshot, app: nil, search: "AC-1", proposals: true)
        #expect(colliding.lanes.flatMap(\.tasks).isEmpty)
        let title = BoardContent(
          snapshot: snapshot, app: nil, search: "ORDER HISTORY", proposals: false)
        #expect(title.lanes.flatMap(\.tasks).map(\.ref) == ["AC-15"])
      }
    }

    @Test func omittedQuestionsKeepEveryAnswerWithoutExtraReadCommands() throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      for index in 0..<11 {
        try AppTestCLI.run(
          [
            "--ws", "acme", "comment", "AC-12", "--kind", "question",
            "--to", "human:acme", "-m", "Acme question",
          ], home: home, seed: 200 + index)
      }
      try AppTestCLI.run(
        [
          "--ws", "acme", "comment", "AC-14", "--kind", "question",
          "--to", "human:acme", "-m", "Acme omitted question",
        ], home: home, seed: 211)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let snapshot = try reader.snapshot(workspace: "acme")
      #expect(snapshot.work.items.count == 12 && snapshot.work.remaining > 0)
      #expect(!snapshot.work.items.contains { $0.task == "AC-14" })
      let content = BoardContent(snapshot: snapshot, app: nil, search: "", proposals: false)
      #expect(content.questions.contains("AC-14"))
      #expect(
        content.answers(for: "AC-14", reader: reader, workspace: "acme")
          .contains { $0.command.title == "Answer question" })
      let actions = content.answers(for: "AC-12", reader: reader, workspace: "acme")
      let commands = actions.map(\.command)
      #expect(commands.filter { $0.title == "Answer question" }.count == 12)
      #expect(commands.allSatisfy { $0.title == "Answer question" })
      #expect(Set(commands.map(\.text)).count == commands.count)
    }

    @Test func taskPresentationUsesRecordedActorsProgressAndRelativeTime() throws {
      try fixture { snapshot in
        let question = try #require(snapshot.board.doing.first { $0.ref == "AC-12" })
        let other = try #require(snapshot.board.doing.first { $0.ref == "AC-14" })
        let review = try #require(snapshot.board.review.first)
        #expect(
          TaskPresentation.progress(question.steps, revision: question.planRevision)
            == "step 2 of 4 · revision 1")
        #expect(TaskPresentation.progress([], revision: 3) == "revision 3")
        #expect(TaskPresentation.claimant(question.claimedBy) == "Claude · session fixture")
        #expect(TaskPresentation.claimant("human:acme") == "acme")
        #expect(TaskPresentation.claimant(nil) == "—")
        #expect(TaskPresentation.claimant("agent:other:session") == "agent:other:session")
        #expect(
          TaskPresentation.cardMetadata(question, asked: true, now: AppV2Fixture.now) == "Asked you"
        )
        #expect(
          TaskPresentation.cardMetadata(
            question, asked: true, questionAuthor: "human:reviewer", now: AppV2Fixture.now)
            == "reviewer · asked you")
        #expect(
          TaskPresentation.cardMetadata(
            question, asked: true, questionAuthor: "agent:claude:fixture", now: AppV2Fixture.now)
            == "Claude · asked you")
        #expect(
          TaskPresentation.cardMetadata(other, asked: false, now: AppV2Fixture.now)
            == "Codex · updated 1 h ago")
        #expect(
          TaskPresentation.cardMetadata(review, asked: false, now: AppV2Fixture.now)
            == "Codex · waiting for your review")
      }
    }

    private func fixture(_ body: (AppSnapshot) throws -> Void) throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      try body(reader.snapshot(workspace: "acme"))
    }
  }
#endif
