#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct FullInboxTests {
    @Test func showAllReplacesTheCappedItemsAndKeepsTheBadge() async throws {
      try await fixture { model, home in
        for index in 0..<13 {
          try AppTestCLI.run(
            [
              "--ws", "acme", "comment", "AC-12", "--kind", "question", "--to", "human:acme",
              "-m", "Acme question \(index)",
            ], home: home, seed: 300 + index)
        }
        await model.refresh(force: true).value
        let snapshot = try #require(model.visibleData?.snapshot)
        let badge = snapshot.work.waitingCount
        let capped = MyWorkContent(snapshot: snapshot, search: "", now: AppV2Fixture.now)
        #expect(capped.remaining > 0)
        #expect(
          MyWorkContent.footer(remaining: capped.remaining, showingAll: false)
            == "\(capped.remaining) more waiting items, plus any proposals older than 14 days.")

        await model.showAllWaiting().value
        #expect(model.showingAllWaiting)
        let all = MyWorkContent(
          snapshot: snapshot, all: model.allWaiting, search: "", now: AppV2Fixture.now)
        #expect(all.remaining == 0)
        #expect(all.questions.count == 14 && capped.questions.count < 14)
        let allItems = try #require(model.allWaiting)
        #expect(allItems.count == snapshot.work.items.count + snapshot.work.remaining)
        #expect(
          Set(snapshot.work.items.map(\.stableID)).isSubset(of: Set(allItems.map(\.stableID))))
        #expect(model.visibleData?.snapshot?.work.waitingCount == badge)
        #expect(model.screenSummary == "\(badge) waiting on you")
        #expect(
          MyWorkContent.footer(remaining: 0, showingAll: true)
            == "Showing everything waiting, including proposals older than 14 days.")
      }
    }

    @Test func aRefreshRereadsTheFullInboxAndAWorkspaceSwitchDropsIt() async throws {
      try await fixture { model, home in
        await model.showAllWaiting().value
        let before = try #require(model.allWaiting).count
        try AppTestCLI.run(
          [
            "--ws", "acme", "comment", "AC-14", "--kind", "question", "--to", "human:acme", "-m",
            "One more question",
          ], home: home, seed: 330)
        await model.refresh(force: true).value
        #expect(model.allWaiting?.count == before + 1)
        await model.selectWorkspace("other").value
        #expect(!model.showingAllWaiting && model.allWaiting == nil)
      }
    }

    @Test func anOldProposalShownByShowAllCanBeAccepted() async throws {
      // Fifteen days on, the fixture's proposals have aged out of the capped inbox.
      try await fixture(now: AppV2Fixture.now.addingTimeInterval(15 * 86_400)) { model, _ in
        #expect(model.proposalRefs.isEmpty)
        await model.showAllWaiting().value
        let all = try #require(model.allWaiting)
        #expect(model.proposalRefs == ["AC-21", "AC-22", "AC-23"])
        let searched = MyWorkContent(
          snapshot: try #require(model.visibleData?.snapshot), all: all, search: "AC-21",
          now: AppV2Fixture.now)
        #expect(searched.tasks.map(\.ref) == ["AC-21"])
        model.actions.selectedProposals = ["AC-21", "AC-23"]
        await model.acceptSelectedProposals(among: ["AC-21"])?.value
        #expect(model.actions.failures[try #require(model.target(AppModel.proposalsTarget))] == nil)
        #expect(model.actions.selectedProposals == ["AC-23"])
        #expect(model.proposalRefs == ["AC-22", "AC-23"])
        model.showFewerWaiting()
        #expect(!model.showingAllWaiting && model.allWaiting == nil)
        #expect(model.proposalRefs.isEmpty)
        #expect(
          MyWorkContent.footer(remaining: 0, showingAll: true, loaded: false)
            == "Reading every waiting item…")
      }
    }

    @Test func withoutMoreItemsTheFooterStillReachesOldProposals() {
      #expect(
        MyWorkContent.footer(remaining: 0, showingAll: false)
          == "Proposals older than 14 days are hidden.")
      #expect(
        MyWorkContent.footer(remaining: 1, showingAll: false)
          == "1 more waiting item, plus any proposals older than 14 days.")
    }

    private func fixture(
      now: Date = AppV2Fixture.now, _ body: (AppModel, URL) async throws -> Void
    ) async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { now })
      let session = AppReadSession(reader: reader, now: { now })
      let writer = AppWriter(reader: reader)
      let model = AppModel(
        reader: reader, now: { now },
        writer: { write, workspace in try writer.perform(write, workspace: workspace) },
        load: { previous, workspace, force in
          try session.load(previous: previous, workspace: workspace, force: force)
        })
      await model.refresh().value
      try await body(model, home)
    }
  }
#endif
