#if DEBUG
  import Foundation
  import GRDB
  @testable import SiltaAppSupport
  @testable import SiltaCore
  import SiltaTestSupport
  import Testing

  /// "Show all" reads the whole human inbox, old proposals included, past the cap.
  @Suite(.blockingTestWork)
  struct AppFullInboxTests {
    @Test func fullInboxHasEveryItemWhileTheSnapshotKeepsItsCap() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppReaderTests.reader(scratch)
        let clock = FakeClock(now: AppV2Fixture.now)
        let env = reader.environment
        let writer = SiltaEnvironment(
          clock: clock, ids: SeededIDGenerator(seed: 971), git: ScriptedGitRunner(script: []),
          home: env.home,
          db: DatabaseStore(home: env.home.url, clock: clock, jitter: { 0 }, readBusyTimeout: 0),
          log: FakeLog(), actor: .agent(tool: "codex", session: "asker"), human: env.human)
        try writer.db.write { tx in
          let old = AppV2Fixture.now.addingTimeInterval(-15 * 86_400)
          try tx.database.execute(
            sql: "UPDATE task SET created_at=? WHERE seq=21",
            arguments: [TaskService.timestamp(old)])
        }
        let asker = TaskService(environment: writer, workspace: "acme")
        for _ in 0..<13 {
          var draft = CommentDraft(body: "Which Acme API version?", kind: "question")
          draft.recipients = ["human:acme"]
          _ = try asker.comment("AC-12", draft)
        }
        let work = try reader.snapshot(workspace: "acme").work
        #expect(work.items.count == 12 && work.remaining > 0)
        let all = try reader.fullInbox(workspace: "acme")
        #expect(all.count > work.items.count + work.remaining - 1)
        #expect(all.filter { $0.kind == "question" }.count == 14)
        #expect(all.contains { $0.kind == "proposal" && $0.refs.contains("AC-21") })
        #expect(!work.items.contains { $0.refs.contains("AC-21") })
        #expect(Set(work.items.map(\.stableID)).isSubset(of: Set(all.map(\.stableID))))
      }
    }
  }
#endif
