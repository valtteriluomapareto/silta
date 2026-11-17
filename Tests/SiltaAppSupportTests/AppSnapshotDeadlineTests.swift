#if DEBUG
  import Foundation
  import GRDB
  @testable import SiltaAppSupport
  @testable import SiltaCore
  import SiltaTestSupport
  import Testing

  @Suite(.blockingTestWork)
  struct AppSnapshotDeadlineTests {
    @Test func taskProposalExpiresWithoutACommit() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let clock = FakeClock(now: AppV2Fixture.now)
        let reader = try AppReader(home: scratch.appending(path: "silta-home"), user: "acme", now: clock.now)
        try reader.environment.db.write { tx in
          try tx.database.execute(sql: "UPDATE task SET created_at=? WHERE seq=21",
            arguments: [TaskService.timestamp(clock.now().addingTimeInterval(-14 * 86400 + 10))])
        }
        let before = try reader.snapshot(workspace: "acme")
        withKnownIssue("Snapshot task expiry is not projected") {
          #expect(before.validUntil == clock.now().addingTimeInterval(10))
        }
        clock.advance(milliseconds: 10_000)
        #expect(try reader.snapshot(workspace: "acme").work.waitingCount == before.work.waitingCount - 1)
      }
    }

    @Test func utcDayBoundaryRefreshesDueBlocks() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let clock = FakeClock(now: AppV2Fixture.now)
        let reader = try AppReader(home: scratch.appending(path: "silta-home"), user: "acme", now: clock.now)
        var block = TaskBlock(why: "Waiting for the Acme vendor.")
        block.on = ["ext:acme-vendor"]
        block.followUp = "1d"
        _ = try TaskService(environment: reader.environment, workspace: "acme").block("AC-15", block)
        let before = try reader.snapshot(workspace: "acme")
        let midnight = AppV2Fixture.now.addingTimeInterval(12 * 3600)
        withKnownIssue("Snapshot UTC day expiry is not projected") {
          #expect(before.validUntil == midnight)
        }
        clock.advance(milliseconds: 12 * 3600 * 1000)
        #expect(try reader.snapshot(workspace: "acme").work.items.contains { $0.kind == "due" })
      }
    }

    @Test func mondayRolloverRefreshesCompletionWeek() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let clock = FakeClock(now: AppV2Fixture.now.addingTimeInterval(6 * 86400 + 12 * 3600 - 1))
        let reader = try AppReader(home: scratch.appending(path: "silta-home"), user: "acme", now: clock.now)
        let before = try reader.snapshot(workspace: "acme")
        #expect(before.board.doneThisWeek.count == 3)
        withKnownIssue("Snapshot week boundary is not projected") {
          #expect(before.validUntil == clock.now().addingTimeInterval(1))
        }
        clock.advance(milliseconds: 1000)
        #expect(try reader.snapshot(workspace: "acme").board.doneThisWeek.isEmpty)
      }
    }
  }
#endif
