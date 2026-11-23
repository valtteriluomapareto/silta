#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct DropProposalTests {
    @Test func droppingSendsTheVisibleTickedProposalsWithAnOptionalReason() async throws {
      try await fixtureModel { model, reader in
        let all = ["AC-21", "AC-22", "AC-23"]
        let reason = try #require(model.target(AppModel.dropReasonTarget))
        #expect(model.dropSelectedProposals(among: all) == nil)
        model.actions.selectedProposals = ["AC-21", "AC-23"]
        model.droppingProposals = true
        model.actions.setDraft("  Not now.  ", for: reason)
        await model.dropSelectedProposals(among: ["AC-21"])?.value
        let dropped = try reader.task("AC-21", workspace: "acme")
        #expect(dropped.status == "dropped" && dropped.result == "Not now.")
        let kept = try reader.task("AC-23", workspace: "acme")
        #expect(kept.status == "proposed")
        #expect(model.actions.selectedProposals == ["AC-23"])
        #expect(model.actions.draft(reason) == "" && !model.droppingProposals)
        await model.dropSelectedProposals(among: all)?.value
        let defaulted = try reader.task("AC-23", workspace: "acme")
        #expect(defaulted.result == "Dropped in triage.")
        #expect(model.proposalRefs == ["AC-22"])
      }
    }

    @Test func aRefusedDropKeepsTheReasonTheSelectionAndTheField() async throws {
      try await fixtureModel { model, reader in
        let reason = try #require(model.target(AppModel.dropReasonTarget))
        model.actions.selectedProposals = ["AC-21"]
        model.droppingProposals = true
        let token = "ghp_" + String(repeating: "a1B2", count: 9)
        model.actions.setDraft("Superseded by " + token, for: reason)
        await model.dropSelectedProposals(among: ["AC-21"])?.value
        let proposals = try #require(model.target(AppModel.proposalsTarget))
        #expect(model.actions.failures[proposals]?.code == "invalid")
        #expect(model.actions.draft(reason) == "Superseded by " + token)
        #expect(model.droppingProposals)
        #expect(model.actions.selectedProposals == ["AC-21"])
        #expect(try reader.task("AC-21", workspace: "acme").status == "proposed")
      }
    }

    private func fixtureModel(_ body: (AppModel, AppReader) async throws -> Void) async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let session = AppReadSession(reader: reader, now: { AppV2Fixture.now })
      let writer = AppWriter(reader: reader)
      let model = AppModel(
        reader: reader, now: { AppV2Fixture.now },
        writer: { write, workspace in try writer.perform(write, workspace: workspace) },
        load: { previous, workspace, force in
          try session.load(previous: previous, workspace: workspace, force: force)
        })
      await model.refresh().value
      try await body(model, reader)
    }
  }
#endif
