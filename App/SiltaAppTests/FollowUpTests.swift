#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct FollowUpTests {
    @Test func dueAndReplanItemsBecomeFollowUpCards() throws {
      try fixture { home in
        try AppTestCLI.run(
          [
            "--ws", "acme", "task", "block", "AC-16", "--on", "ext:design-team", "--on", "AC-18",
            "-m", "Needs the final copy.",
          ], home: home)
        try AppTestCLI.run(
          ["--ws", "acme", "task", "drop", "AC-18", "-m", "Superseded."], home: home, seed: 152)
        let later = try AppReader(
          home: home, user: "acme", now: { AppV2Fixture.now.addingTimeInterval(8.5 * 86_400) })
        let snapshot = try later.snapshot(workspace: "acme")
        let content = MyWorkContent(
          snapshot: snapshot, apps: [], search: "",
          now: AppV2Fixture.now.addingTimeInterval(8.5 * 86_400))
        let replan = try #require(content.followUps.first { $0.task.ref == "AC-16" })
        #expect(replan.replan)
        #expect(replan.title == "Re-plan: Paginate the orders endpoint")
        #expect(replan.subtitle == "A blocker was dropped: AC-18 · blocked 8 days")
        #expect(replan.openBlockers == ["ext:design-team"])
        #expect(
          replan.unblockWarning
            == "Unblocking returns it to Todo and unlinks its open blocker ext:design-team.")
        #expect(!content.other.contains { $0.kind == "replan" || $0.kind == "due" })
        #expect(content.other.contains { $0.kind == "ready" })
      }
    }

    @Test func aDueFollowUpNamesItsDayAndAge() throws {
      try fixture { home in
        try AppTestCLI.run(
          [
            "--ws", "acme", "task", "block", "AC-16", "--on", "ext:design-team", "-m",
            "Needs the final copy.",
          ], home: home)
        let now = AppV2Fixture.now.addingTimeInterval(8.5 * 86_400)
        let later = try AppReader(home: home, user: "acme", now: { now })
        let content = MyWorkContent(
          snapshot: try later.snapshot(workspace: "acme"), apps: [], search: "", now: now)
        let due = try #require(content.followUps.first)
        #expect(!due.replan && due.title == "Follow up: Paginate the orders endpoint")
        #expect(due.subtitle == "Follow-up was due 2 days ago · blocked 8 days")
        #expect(FollowUp.dueDay("2026-11-25", now: now) == "today")
        #expect(FollowUp.dueDay("2026-11-24", now: now) == "yesterday")
        #expect(FollowUp.dueDay("2026-11-26", now: now) == "2026-11-26")
        #expect(
          MyWorkContent(
            snapshot: try later.snapshot(workspace: "acme"), apps: [], search: "design",
            now: now
          ).followUps.count == 1)
      }
    }

    @Test func aTaskWithTwoPartiesGetsOneCardAndDoneBlockersStayLinked() throws {
      try fixture { home in
        try AppTestCLI.run(
          [
            "--ws", "acme", "task", "block", "AC-16", "--on", "ext:design-team", "--on",
            "ext:legal", "--on", "AC-18", "-m", "Needs copy and sign-off.",
          ], home: home)
        try AppTestCLI.run(
          ["--ws", "acme", "task", "done", "AC-18", "--no-sha", "-m", "Done."], home: home,
          seed: 153)
        let now = AppV2Fixture.now.addingTimeInterval(8.5 * 86_400)
        let later = try AppReader(home: home, user: "acme", now: { now })
        let content = MyWorkContent(
          snapshot: try later.snapshot(workspace: "acme"), apps: [], search: "", now: now)
        let cards = content.followUps.filter { $0.task.ref == "AC-16" }
        #expect(cards.count == 1)
        let card = try #require(cards.first)
        #expect(Set(card.openBlockers) == ["ext:design-team", "ext:legal"])
        #expect(card.progress == "AC-18 is done; 2 of 3 blockers still open.")
        #expect(!card.unblockWarning.contains("AC-18"))
      }
    }

    @Test func actionsSendTheirWritesUnderOneTargetPerTask() async throws {
      let writes = ControlledWrites()
      try await fixtureModel(writes) { model in
        let snooze = model.snooze("AC-17", days: 14)
        let first = await writes.next()
        #expect(first.write == .snooze(ref: "AC-17", days: 14))
        #expect(model.unblockAnyway("AC-17", confirmed: []) == nil)
        first.continuation.resume(returning: nil)
        await snooze?.value
        let reason = try #require(model.target(AppModel.dropTaskReasonTarget("AC-17")))
        model.actions.setDraft("  Moved to web.  ", for: reason)
        let drop = model.dropTask("AC-17")
        let second = await writes.next()
        #expect(second.write == .dropTask(ref: "AC-17", why: "Moved to web."))
        second.continuation.resume(throwing: AppLoadFailure(message: "busy", commands: []))
        await drop?.value
        #expect(model.actions.draft(reason) == "  Moved to web.  ")
        let retry = model.dropTask("AC-17")
        let third = await writes.next()
        third.continuation.resume(returning: nil)
        await retry?.value
        #expect(model.actions.draft(reason) == "")
      }
    }

    private func fixture(_ body: (URL) throws -> Void) throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      try body(home)
    }

    private func fixtureModel(
      _ writes: ControlledWrites, _ body: (AppModel) async throws -> Void
    ) async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let session = AppReadSession(reader: reader, now: { AppV2Fixture.now })
      let model = AppModel(
        reader: reader, now: { AppV2Fixture.now },
        writer: { write, workspace in try await writes.write(write, workspace) },
        load: { previous, workspace, force in
          try session.load(previous: previous, workspace: workspace, force: force)
        })
      await model.refresh().value
      try await body(model)
    }
  }
#endif
