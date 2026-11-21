#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct TaskFactsTests {
    @Test func readyBlockerNamesTheDoneTaskAndOffersUnblock() throws {
      try fixture { reader, _ in
        let task = try reader.task("AC-17", workspace: "acme")
        #expect(TaskFacts.otherLinks(task).isEmpty)
        let waiting = try #require(TaskFacts.waiting(task))
        #expect(
          waiting.blockers == [
            TaskFacts.Blocker(
              ref: "AC-19", detail: "Round order totals · done", state: .done)
          ])
        #expect(waiting.heading == "Waiting on · 1 of 1 done")
        #expect(waiting.why == "Needs the rounded totals first.")
        #expect(waiting.footer == "Blocked today. Ready to unblock.")
        #expect(waiting.followUp == "Follow up Mon 23 Nov")
        #expect(TaskFacts.waiting(try reader.task("AC-15", workspace: "acme")) == nil)
      }
    }

    @Test func openPartiesAndDroppedTasksExplainWhyUnblockWaits() throws {
      try fixture { reader, home in
        try AppTestCLI.run(
          [
            "--ws", "acme", "task", "block", "AC-16", "--on", "ext:design-team", "--on", "AC-18",
            "-m", "Needs the final copy.",
          ], home: home)
        let open = try #require(TaskFacts.waiting(try reader.task("AC-16", workspace: "acme")))
        #expect(open.blockers.map(\.ref) == ["ext:design-team", "AC-18"])
        #expect(open.blockers.map(\.state) == [.open, .open])
        #expect(open.blockers[1].detail == "Error code cleanup · todo")
        #expect(open.why == "Needs the final copy.")
        #expect(open.blockers[0].detail == nil)
        #expect(open.heading == "Waiting on · 0 of 2 done")
        #expect(open.footer == "Blocked today. Unblock is offered when every blocker is done.")

        try AppTestCLI.run(
          ["--ws", "acme", "task", "drop", "AC-18", "-m", "Superseded."], home: home, seed: 152)
        let dropped = try #require(
          TaskFacts.waiting(try reader.task("AC-16", workspace: "acme")))
        #expect(dropped.blockers.map(\.state) == [.open, .dropped])
        #expect(dropped.footer == "Blocked today. A blocker was dropped: re-plan the task.")
        let result = try #require(TaskFacts.result(try reader.task("AC-18", workspace: "acme")))
        #expect(result.body == "Superseded." && result.friction == nil)
      }
    }

    @Test func aBlockWithoutBlockersWaitsOnAnAnswerAndAgesInDays() throws {
      try fixture { _, home in
        try AppTestCLI.run(
          ["--ws", "acme", "task", "block", "AC-16", "-m", "Which page size?"], home: home)
        let later = try AppReader(
          home: home, user: "acme", now: { AppV2Fixture.now.addingTimeInterval(3.5 * 86_400) })
        let waiting = try #require(TaskFacts.waiting(try later.task("AC-16", workspace: "acme")))
        #expect(waiting.blockers.isEmpty)
        #expect(waiting.heading == "Waiting on an answer")
        #expect(waiting.footer == "Blocked 3 days. Unblock when the answer arrives.")
        let next = try AppReader(
          home: home, user: "acme", now: { AppV2Fixture.now.addingTimeInterval(1.5 * 86_400) })
        #expect(
          TaskFacts.waiting(try next.task("AC-16", workspace: "acme"))?.footer
            == "Blocked 1 day. Unblock when the answer arrives.")
      }
    }

    @Test func aBlockerPullRequestIsNotTheTasksOwn() throws {
      try fixture { reader, home in
        try AppTestCLI.run(
          [
            "--ws", "acme", "task", "block", "AC-16", "--on",
            "url:https://github.com/acme/web/pull/5", "-m", "Needs the web change.",
          ], home: home)
        let task = try reader.task("AC-16", workspace: "acme")
        #expect(TaskFacts.pullRequests(task).isEmpty)
        #expect(TaskFacts.otherLinks(task).isEmpty)
        let waiting = try #require(TaskFacts.waiting(task))
        #expect(
          waiting.blockers == [
            TaskFacts.Blocker(
              ref: "url:https://github.com/acme/web/pull/5", detail: nil, state: .open)
          ])
      }
    }

    @Test func doneTaskShowsResultFrictionCommitAndDirtyWorktree() throws {
      try fixture { reader, _ in
        let task = try reader.task("AC-8", workspace: "acme")
        let result = try #require(TaskFacts.result(task))
        #expect(result.body.hasPrefix("Order totals are stored"))
        #expect(!result.body.contains("Friction"))
        #expect(
          result.friction
            == "The fixture had no multi-currency orders, so rounding was checked by hand.")
        #expect(TaskFacts.commit(task) == "1111111 · main")
        #expect(task.doneDirty == true)
        #expect(
          TaskFacts.pullRequests(task)
            == [
              TaskFacts.PullRequest(title: "PR #38", url: "https://github.com/acme/example/pull/38")
            ])
        #expect(TaskFacts.otherLinks(task).isEmpty)
        #expect(TaskFacts.result(try reader.task("AC-15", workspace: "acme")) == nil)
      }
    }

    @Test func onlyTheFinalFrictionLineIsSplitOff() {
      #expect(TaskFacts.splitResult("Done.\n\nFriction: none") == ("Done.", "none"))
      #expect(
        TaskFacts.splitResult("Done.\nMerged in #4 (abc).\nFriction: none\n")
          == ("Done.\nMerged in #4 (abc).", "none"))
      #expect(TaskFacts.splitResult("Done.\r\nFriction: slow CI") == ("Done.", "slow CI"))
      #expect(
        TaskFacts.splitResult("Friction: early\nDone.\nFriction: late")
          == ("Friction: early\nDone.", "late"))
      #expect(TaskFacts.splitResult("Done and verified.") == ("Done and verified.", nil))
      #expect(
        TaskFacts.splitResult("A\n\nFriction: x\n\nMore text.")
          == ("A\n\nFriction: x\n\nMore text.", nil))
    }

    @Test func linksSeparatePullRequestsFromOtherTargets() throws {
      try fixture { reader, _ in
        let review = try reader.task("AC-9", workspace: "acme")
        #expect(TaskFacts.pullRequests(review).map(\.title) == ["PR #41"])
        let ordinary = try reader.task("AC-14", workspace: "acme")
        #expect(TaskFacts.pullRequests(ordinary).isEmpty)
      }
      #expect(
        TaskFacts.pullRequest("url:https://gitlab.example/acme/web/-/merge_requests/7")
          == TaskFacts.PullRequest(
            title: "MR !7", url: "https://gitlab.example/acme/web/-/merge_requests/7"))
      #expect(
        TaskFacts.pullRequest("url:https://acme.example/pull")
          == nil)
      #expect(TaskFacts.pullRequest("doc:push") == nil)
    }

    @Test func createdLineNamesTheCreatorAndDay() throws {
      try fixture { reader, _ in
        let task = try reader.task("AC-14", workspace: "acme")
        #expect(TaskFacts.created(task) == "Codex · 16 Nov")
      }
    }

    @Test func handoffAndRelationsComeFromTheDetailRead() throws {
      try fixture { reader, home in
        try AppTestCLI.run(
          ["--ws", "acme", "task", "add", "Order history filters", "--parent", "AC-15"],
          home: home)
        let parent = try reader.task("AC-15", workspace: "acme")
        #expect(
          TaskFacts.subtasks(parent) == [
            TaskFacts.Related(ref: "AC-24", title: "Order history filters · proposed")
          ])
        let child = try reader.task("AC-24", workspace: "acme")
        #expect(
          TaskFacts.parent(child) == TaskFacts.Related(ref: "AC-15", title: "Order history page"))
        #expect(TaskFacts.handoff(child) == nil)
      }
    }

    private func fixture(_ body: (AppReader, URL) throws -> Void) throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      try body(AppReader(home: home, user: "acme", now: { AppV2Fixture.now }), home)
    }
  }
#endif
