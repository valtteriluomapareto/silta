#if DEBUG
  import Foundation
  import GRDB
  @testable import SiltaAppSupport
  @testable import SiltaCore
  import SiltaTestSupport
  import Testing

  /// The detail read carries what `task show` returns, for the inspector.
  @Suite(.blockingTestWork)
  struct AppTaskDetailTests {
    @Test func detailCarriesWhatTaskShowReturns() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppReaderTests.reader(scratch)
        let blocked = try reader.task("AC-17", workspace: "acme")
        #expect(
          blocked.waiting
            == AppWaiting(
              on: ["task:AC-19"], ageDays: 0, why: "Needs the rounded totals first.", ready: true,
              dropped: []))
        #expect(blocked.followUpAt == "2026-11-23")
        #expect(
          blocked.detail?.blockers == [
            AppBlocker(
              ref: "AC-19",
              task: AppTaskSummary(
                ref: "AC-19", title: "Round order totals", status: "done", externalRef: nil),
              state: .done)
          ])
        let unblocked = try reader.task("AC-15", workspace: "acme")
        #expect(unblocked.waiting == nil)
        #expect(unblocked.detail == AppTaskDetail(parent: nil, subtasks: [], blockers: []))

        let done = try reader.task("AC-8", workspace: "acme")
        #expect(done.result?.hasSuffix("rounding was checked by hand.") == true)
        #expect(done.result?.contains("\nMerged in #38 (1111111).\nFriction: ") == true)
        #expect(done.doneSHA == "1111111111111111111111111111111111111111")
        #expect(done.doneBranch == "main")
        #expect(done.doneDirty == true)
        #expect(
          done.links.contains {
            $0.rel == "about" && $0.target == "url:https://github.com/acme/example/pull/38"
          })

        let doing = try reader.task("AC-14", workspace: "acme")
        #expect(doing.acceptance.hasPrefix("- A failed registration retries"))
        #expect(doing.createdBy == "agent:codex:fixture")
        #expect(!doing.resumeAvailable && doing.handedOff == nil)
      }
    }

    @Test func detailNamesParentSubtasksAndAHandoff() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppReaderTests.reader(scratch)
        try Self.writer(reader.environment).db.write { tx in
          try tx.database.execute(
            sql: """
              UPDATE task SET parent_id=(SELECT id FROM task WHERE seq=15) WHERE seq IN (18,16);
              UPDATE task SET external_ref='github:acme/web#7' WHERE seq=18;
              """)
        }
        let parent = try reader.task("AC-15", workspace: "acme")
        #expect(parent.detail?.subtasks.map(\.ref) == ["AC-16", "AC-18"])
        #expect(parent.detail?.subtasks.last?.externalRef == "github:acme/web#7")
        let child = try reader.task("AC-16", workspace: "acme")
        #expect(child.parent == "AC-15")
        #expect(child.detail?.parent?.title == "Order history page")
        #expect(child.detail?.subtasks == [])

        let owner = TaskService(
          environment: Self.writer(
            reader.environment, actor: .agent(tool: "codex", session: "fixture")),
          workspace: "acme")
        let handoff = try owner.comment(
          "AC-14", CommentDraft(body: "Retry queue done; next drop old tokens.", kind: "handoff"))
        let resumable = try reader.task("AC-14", workspace: "acme")
        #expect(resumable.claimedBy == nil)
        #expect(resumable.resumeAvailable)
        #expect(resumable.handedOff == handoff.comment.ref)
        #expect(try reader.snapshot(workspace: "acme").board.doing.allSatisfy { $0.detail == nil })
      }
    }

    @Test func blockerStatesFollowCoresReadyRule() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppReaderTests.reader(scratch)
        let human = TaskService(
          environment: Self.writer(reader.environment, actor: .human(name: "acme")),
          workspace: "acme")
        var block = TaskBlock(why: "Needs the new endpoint and the copy.")
        block.on = [
          "AC-21", "AC-15", "AC-16", "ext:design-team", "url:https://github.com/acme/web/pull/5",
        ]
        _ = try human.block("AC-18", block)
        try Self.writer(reader.environment).db.write { tx in
          // AC-15 finished long ago, so a list read would archive it; AC-16 is done but
          // promoted, which Core counts as open; the AC-21 proposal was dropped.
          try tx.database.execute(
            sql: """
              UPDATE task SET status='done',closed_at='2026-09-01T00:00:00.000Z' WHERE seq=15;
              UPDATE task SET status='done',external_ref='github:acme/backend#9',
                closed_at='2026-11-15T00:00:00.000Z' WHERE seq=16;
              UPDATE task SET status='dropped',closed_at='2026-11-15T00:00:00.000Z' WHERE seq=21;
              """)
        }
        let task = try reader.task("AC-18", workspace: "acme")
        let blockers = try #require(task.detail?.blockers)
        #expect(
          Set(blockers.map(\.ref))
            == [
              "AC-15", "AC-16", "AC-21", "ext:design-team",
              "url:https://github.com/acme/web/pull/5",
            ])
        let states = Dictionary(uniqueKeysWithValues: blockers.map { ($0.ref, $0.state) })
        #expect(states["AC-15"] == .done)
        #expect(states["AC-16"] == .open)
        #expect(states["AC-21"] == .dropped)
        #expect(states["ext:design-team"] == .open)
        #expect(states["url:https://github.com/acme/web/pull/5"] == .open)
        #expect(blockers.first { $0.ref == "AC-15" }?.task?.title == "Order history page")
        #expect(blockers.first { $0.ref == "AC-16" }?.task?.externalRef == "github:acme/backend#9")
        #expect(blockers.first { $0.ref == "ext:design-team" }?.task == nil)
        #expect(task.waiting?.ready == false)
      }
    }

    private static func writer(_ env: SiltaEnvironment, actor: ActorID? = nil) -> SiltaEnvironment {
      let clock = FakeClock(now: AppV2Fixture.now)
      return SiltaEnvironment(
        clock: clock, ids: SeededIDGenerator(seed: 951), git: ScriptedGitRunner(script: []),
        home: env.home,
        db: DatabaseStore(home: env.home.url, clock: clock, jitter: { 0 }, readBusyTimeout: 0),
        log: FakeLog(), actor: actor ?? env.actor, human: env.human)
    }
  }
#endif
