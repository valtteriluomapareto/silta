#if DEBUG
  import Foundation
  import GRDB
  @testable import SiltaAppSupport
  @testable import SiltaCore
  import SiltaTestSupport
  import Testing

  /// The viewer's claim state agrees with what Core lets another agent do.
  @Suite(.blockingTestWork)
  struct AppClaimTests {
    @Test func expiryMatchesWhenCoreLetsAnotherAgentStart() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppReaderTests.reader(scratch)
        let other = TaskService(
          environment: Self.writer(reader.environment, actor: .agent(tool: "claude", session: "x")),
          workspace: "acme")
        for ref in ["AC-12", "AC-14"] {
          let task = try reader.task(ref, workspace: "acme")
          let core = try other.show(ref)
          let expiry = try #require(task.claimExpiresAt)
          for at in [
            AppV2Fixture.now, expiry.addingTimeInterval(-0.001), expiry,
            expiry.addingTimeInterval(60),
          ] {
            let coreAllows = try other.foreignClaim(core, at: at) == nil
            #expect(task.claimExpired(at: at) == coreAllows, "\(ref) at \(at)")
          }
        }
        #expect(try reader.task("AC-14", workspace: "acme").claimExpired(at: AppV2Fixture.now))
        #expect(!(try reader.task("AC-12", workspace: "acme").claimExpired(at: AppV2Fixture.now)))
        #expect(
          try reader.task("AC-14", workspace: "acme").claimAge(at: AppV2Fixture.now) == 3 * 3600)
        let unclaimed = try reader.task("AC-15", workspace: "acme")
        #expect(unclaimed.claimAge(at: AppV2Fixture.now) == nil)
        #expect(!unclaimed.claimExpired(at: AppV2Fixture.now))
      }
    }

    @Test func anUnreadableHeartbeatReadsAsStale() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppReaderTests.reader(scratch)
        try Self.writer(reader.environment).db.write { tx in
          try tx.database.execute(sql: "UPDATE task SET claimed_at='yesterday' WHERE seq=12")
        }
        let doing = try reader.snapshot(workspace: "acme").board.doing
        let task = try #require(doing.first { $0.ref == "AC-12" })
        #expect(task.claimExpiresAt == nil && task.claimAge(at: AppV2Fixture.now) == nil)
        #expect(task.claimExpired(at: AppV2Fixture.now))
      }
    }

    @Test func boardRowsCarryCoresResumeState() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppReaderTests.reader(scratch)
        let owner = TaskService(
          environment: Self.writer(
            reader.environment, actor: .agent(tool: "codex", session: "fixture")),
          workspace: "acme")
        let handoff = try owner.comment(
          "AC-14", CommentDraft(body: "Queue done; next drop old tokens.", kind: "handoff"))
        try Self.writer(reader.environment).db.write { tx in
          // A promoted Doing task loses its claim too, but belongs to its tracker: the board
          // leaves it out and Core can't resume it.
          try tx.database.execute(
            sql: """
              UPDATE task SET claimed_by=NULL,claimed_at=NULL,external_ref='github:acme/m#3'
              WHERE seq=12
              """)
        }
        var doing = try reader.snapshot(workspace: "acme").board.doing
        #expect(doing.first { $0.ref == "AC-14" }?.resumeAvailable == true)
        #expect(doing.first { $0.ref == "AC-14" }?.handedOff == handoff.comment.ref)
        #expect(!doing.contains { $0.ref == "AC-12" })
        #expect(!(try reader.task("AC-12", workspace: "acme").resumeAvailable))

        _ = try owner.updateComments([handoff.comment.ref], action: .delete)
        doing = try reader.snapshot(workspace: "acme").board.doing
        #expect(doing.first { $0.ref == "AC-14" }?.resumeAvailable == true)
        #expect(doing.first { $0.ref == "AC-14" }?.handedOff == nil)
      }
    }

    private static func writer(_ env: SiltaEnvironment, actor: ActorID? = nil) -> SiltaEnvironment {
      let clock = FakeClock(now: AppV2Fixture.now)
      return SiltaEnvironment(
        clock: clock, ids: SeededIDGenerator(seed: 961), git: ScriptedGitRunner(script: []),
        home: env.home,
        db: DatabaseStore(home: env.home.url, clock: clock, jitter: { 0 }, readBusyTimeout: 0),
        log: FakeLog(), actor: actor ?? env.actor, human: env.human)
    }
  }
#endif
