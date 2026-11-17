#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct ControlStateTests {
    @Test func projectionUsesNavigationAndFilteredCountsAndWritesAtomicJSON() async throws {
      let fixture = try FixtureLaunch.prepare()
      defer {
        try? FileManager.default.removeItem(  // cleanup
          at: fixture.home.deletingLastPathComponent())
      }
      let reader = try AppReader(home: fixture.home, user: fixture.user, now: { fixture.now })
      let session = AppReadSession(reader: reader, now: { fixture.now })
      let model = AppModel(
        reader: reader,
        load: { previous, workspace, force in
          try session.load(previous: previous, workspace: workspace, force: force)
        })
      let starting = ControlState(model: model, run: "acme", revision: 1, dark: false)
      #expect(!starting.idle && starting.refresh.phase == "starting")
      #expect(starting.counts.lanes == nil && starting.counts.sidebar == nil)
      await model.refresh().value
      try ControlLaunch.Route("board:AC-12").apply(to: model)
      let pending = ControlState(model: model, run: "acme", revision: 2, dark: false)
      #expect(!pending.idle)
      await model.loadTaskDetail()
      let first = ControlState(model: model, run: "acme", revision: 2, dark: false)
      #expect(first.snapshotVersion == 1 && first.screen == "board" && first.route == "board:AC-12")
      #expect(first.selection?.kind == "task" && first.selection?.ref == "AC-12")
      #expect(first.inspectorOpen && first.idle && first.refresh.phase == "ready")
      #expect(first.counts.lanes == ["Todo": 4, "Doing": 2, "Review": 1, "Done this week": 3])
      #expect(first.counts.sidebar?.waiting == 7 && first.counts.sidebar?.claimed == 2)
      #expect(first.counts.sidebar?.apps == ["acme-mobile": 3, "acme-backend": 3, "acme-web": 1])
      model.showProposed = true
      #expect(
        ControlState(model: model, run: "acme", revision: 3, dark: true).counts.lanes?["Todo"] == 7)
      model.navigate(to: .workspace)
      let workspace = ControlState(model: model, run: "acme", revision: 4, dark: true)
      #expect(workspace.selection == nil && !workspace.inspectorOpen)
      let connection = try #require(model.visibleData?.map?.connections.first)
      model.select(connection: connection.attachment)
      let selected = ControlState(model: model, run: "acme", revision: 5, dark: true)
      #expect(
        selected.selection?.kind == "connection" && selected.selection?.ref == connection.attachment
      )
      #expect(selected.inspectorOpen && selected.appearance == "dark")
      let url = fixture.home.deletingLastPathComponent().appending(path: "state.json")
      try starting.write(to: url)
      try selected.write(to: url)
      let object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
      #expect(object["revision"] as? Int == 5)
      let encoded = try String(contentsOf: url, encoding: .utf8)
      #expect(!encoded.contains(fixture.home.path) && !encoded.contains("Which API"))
    }

    @Test func docsRouteProjectsSelectionAndWaitsForCurrentView() async throws {
      let fixture = try FixtureLaunch.prepare()
      defer {
        try? FileManager.default.removeItem(  // cleanup
          at: fixture.home.deletingLastPathComponent())
      }
      let reader = try AppReader(home: fixture.home, user: fixture.user, now: { fixture.now })
      let session = AppReadSession(reader: reader, now: { fixture.now })
      let model = AppModel(
        reader: reader,
        load: { previous, workspace, force in
          try session.load(previous: previous, workspace: workspace, force: force)
        })
      await model.refresh().value
      try ControlLaunch.Route("docs:doc:order-contract@3:changes").apply(to: model)
      withKnownIssue("Docs routes must select their immutable revision and view.") {
        #expect(model.route == .docs && model.documentSelection?.ref == "doc:order-contract@3")
        #expect(model.documentSelection?.view == .changes)
        #expect(!ControlState(model: model, run: "acme", revision: 1, dark: false).idle)
      }
      await model.loadDocuments()
      let state = ControlState(model: model, run: "acme", revision: 2, dark: false)
      let data = try JSONEncoder().encode(state)
      let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      let selected = object["selection"] as? [String: String] ?? [:]
      withKnownIssue("Docs state must project model-owned selection and its current view.") {
        #expect(state.screen == "docs" && state.route == "docs:doc:order-contract@3:changes")
        #expect(selected == ["kind": "document", "ref": "doc:order-contract@3", "view": "changes"])
      }
      #expect(state.idle && state.refresh.phase == "ready" && !state.inspectorOpen)
      #expect(state.counts.sidebar?.waiting == 7)
      model.select(documentView: .comments)
      withKnownIssue("A selected Docs view is pending until its content arrives.") {
        #expect(!ControlState(model: model, run: "acme", revision: 3, dark: false).idle)
      }
      await model.loadDocuments()
      #expect(ControlState(model: model, run: "acme", revision: 4, dark: false).idle)
      model.select(document: "doc:missing@1")
      await model.loadDocuments()
      let failed = ControlState(model: model, run: "acme", revision: 5, dark: false)
      #expect(failed.idle)
      withKnownIssue("Docs read failures must appear in the refresh phase.") {
        #expect(failed.refresh.phase == "failed")
      }
    }

    @Test func failedRefreshIsIdleWithoutPublishingPrivateErrorText() async {
      let model = AppModel(load: { _, _, _ in
        throw AppLoadFailure(message: "/Users/Acme/private-body")
      })
      await model.refresh().value
      for route in [AppRoute.mywork, .docs] {
        model.navigate(to: route)
        let state = ControlState(model: model, run: "acme", revision: 1, dark: false)
        #expect(state.idle && state.refresh.phase == "failed")
        #expect(state.counts.lanes == nil && state.selection == nil)
      }
    }
  }
#endif
