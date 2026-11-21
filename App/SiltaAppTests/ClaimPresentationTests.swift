#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct ClaimPresentationTests {
    @Test func liveAndExpiredClaimsAgeFromTheHeartbeatNotTheLastUpdate() throws {
      try fixture { reader, _ in
        let live = try reader.task("AC-12", workspace: "acme")
        #expect(TaskPresentation.claim(live, now: AppV2Fixture.now) == .live(age: "6 min ago"))
        let expired = try reader.task("AC-14", workspace: "acme")
        #expect(expired.updatedAt != expired.claimedAt)
        #expect(TaskPresentation.claim(expired, now: AppV2Fixture.now) == .expired(idle: "3 h"))
        #expect(SidebarContent.claimTitle(expired, now: AppV2Fixture.now) == "AC-14 · expired")
        #expect(
          SidebarContent.claimSubtitle(expired, now: AppV2Fixture.now)
            == "Codex · claim expired · idle 3 h")
        #expect(TaskPresentation.claim(try reader.task("AC-15", workspace: "acme"), now: .now) == nil)
      }
    }

    @Test func expiryFollowsCoresTwoHourBoundary() throws {
      try fixture { reader, _ in
        let task = try reader.task("AC-12", workspace: "acme")
        let stamp = try Date(
          try #require(task.claimedAt),
          strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let before = stamp.addingTimeInterval(AppTask.claimDuration - 1)
        let at = stamp.addingTimeInterval(AppTask.claimDuration)
        #expect(TaskPresentation.claim(task, now: before) == .live(age: "1 h ago"))
        #expect(TaskPresentation.claim(task, now: at) == .expired(idle: "2 h"))
        #expect(
          TaskPresentation.cardMetadata(task, asked: false, now: at)
            == "Claude · claim expired · idle 2 h")
        #expect(
          TaskPresentation.cardMetadata(task, asked: false, now: before) == "Claude · active 1 h ago")
      }
    }

    @Test func expiredClaimBannerSaysWhereTheNextAgentStarts() throws {
      try fixture { reader, _ in
        let task = try reader.task("AC-14", workspace: "acme")
        let banner = try #require(TaskPresentation.claimBanner(task, now: AppV2Fixture.now))
        #expect(banner.title == "Claim expired 1 h ago")
        #expect(
          banner.body
            == "Codex last wrote 3 h ago (step 3 of 4). No handoff was written, so the next "
            + "agent starts from the plan.")
        #expect(
          TaskPresentation.claimBanner(try reader.task("AC-12", workspace: "acme"), now: AppV2Fixture.now)
            == nil)
      }
    }

    @Test func releasedClaimReadsAsHandedOff() throws {
      try fixture { reader, home in
        try AppTestCLI.run(["--ws", "acme", "task", "start", "AC-16"], home: home)
        try AppTestCLI.run(
          [
            "--ws", "acme", "comment", "AC-16", "--kind", "handoff", "-m",
            "Pagination cursor done; next the page size limit.",
          ], home: home, seed: 152)
        let board = try reader.snapshot(workspace: "acme").board
        let card = try #require(board.doing.first { $0.ref == "AC-16" })
        #expect(TaskPresentation.claim(card, now: AppV2Fixture.now) == .handedOff)
        #expect(
          TaskPresentation.cardMetadata(card, asked: false, now: AppV2Fixture.now)
            == "Handed off · ready to resume")
        let detail = try reader.task("AC-16", workspace: "acme")
        #expect(TaskFacts.handoff(detail)?.hasPrefix("Handed off in AC-16/") == true)
        #expect(TaskPresentation.claimBanner(detail, now: AppV2Fixture.now) == nil)
      }
    }

    @Test func expiredClaimsAreCountedForTheSidebar() throws {
      try fixture { reader, _ in
        let doing = try reader.snapshot(workspace: "acme").board.doing
        #expect(SidebarContent.claimHeading(doing, now: AppV2Fixture.now) == "Claimed now · 1 expired")
        #expect(
          SidebarContent.claimHeading(doing, now: AppV2Fixture.now.addingTimeInterval(-3 * 3600))
            == "Claimed now")
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
