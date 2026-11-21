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
        #expect(blocked.followUpAt != nil)
        #expect(blocked.related("AC-19")?.title == "Round order totals")
        #expect(blocked.related("AC-19")?.status == "done")
        #expect(try reader.task("AC-15", workspace: "acme").waiting == nil)

        let done = try reader.task("AC-8", workspace: "acme")
        #expect(done.result?.hasSuffix("rounding was checked by hand.") == true)
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
              UPDATE task SET parent_id=(SELECT id FROM task WHERE seq=15) WHERE seq IN (16,18)
              """)
        }
        let parent = try reader.task("AC-15", workspace: "acme")
        #expect(parent.subtasks.map(\.ref) == ["AC-16", "AC-18"])
        let child = try reader.task("AC-16", workspace: "acme")
        #expect(child.parent == "AC-15")
        #expect(child.related("AC-15")?.title == "Order history page")
        #expect(child.subtasks.isEmpty)

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
        #expect(
          try reader.snapshot(workspace: "acme").board.doing.allSatisfy { $0.related.isEmpty })
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
