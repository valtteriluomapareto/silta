#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct SharedPresentationTests {
    @Test func actorsHaveDistinctLabelsWithoutInventingIdentities() {
      #expect(ActorPresentation("agent:claude:fixture").name == "Claude")
      #expect(ActorPresentation("agent:codex:fixture").name == "Codex")
      #expect(ActorPresentation("human:acme").name == "You")
      #expect(
        ActorPresentation("agent:claude:fixture").symbol
          != ActorPresentation("agent:codex:fixture").symbol)
      #expect(ActorPresentation("external:Acme").name == "external:Acme")
    }

    @Test func onlyStandaloneUnquotedPlaceholdersGetWarningFormatting() {
      let text =
        #"SILTA_HOME='/tmp/REFS and MERGE_SHA' silta task done 'AC-9' --sha MERGE_SHA -m """#
      let parts = CommandPresentation.parts(text)
      #expect(parts.map(\.text).joined() == text)
      #expect(parts.filter(\.warning).map(\.text) == ["MERGE_SHA", #""""#])
      #expect(
        CommandPresentation.parts("silta task triage --accept REFS").filter(\.warning).map(\.text)
          == ["REFS"])
      #expect(CommandPresentation.parts("silta task show 'REFS' PREFS").allSatisfy { !$0.warning })
    }

    @Test func headerUsesActionableCountsAndPreservesRouteSelection() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let data = AppLoadedData(
        workspaces: try reader.workspaces(), workspace: "acme",
        snapshot: try reader.snapshot(workspace: "acme"),
        map: try reader.workspaceMap(workspace: "acme"), version: 1, checkedAt: AppV2Fixture.now)
      let model = AppModel(reader: reader, load: { _, _, _ in data })
      await model.refresh().value
      #expect(model.screenSummary == "7 waiting on you · 2 tasks claimed by agents")
      model.inspect(task: "AC-12")
      #expect(model.screenSummary == "7 open · 3 proposed · 3 done this week")
      #expect(model.boardSelection?.ref == "AC-12" && model.boardInspectorPresented)
      model.navigate(to: .mywork)
      #expect(model.screenSummary == "7 waiting on you · 2 tasks claimed by agents")
    }
  }
#endif
