#if DEBUG
  import Foundation
  @testable import SiltaApp
  @testable import SiltaAppSupport
  import Testing

  @MainActor struct BoardFilterTests {
    @Test func hidingBlockedLeavesTodoAndCountsWhatAppAndSearchWouldShow() throws {
      try fixture { snapshot, _ in
        func content(_ filter: BoardFilter, search: String = "") -> BoardContent {
          BoardContent(snapshot: snapshot, apps: [], filter: filter, search: search)
        }
        let shown = content(BoardFilter())
        #expect(shown.lanes[0].tasks.map(\.ref) == ["AC-15", "AC-16", "AC-17", "AC-18"])
        #expect(shown.hiddenBlocked == 0 && shown.counts.blocked == 1)
        let hidden = content(BoardFilter(blocked: false))
        #expect(hidden.lanes[0].tasks.map(\.ref) == ["AC-15", "AC-16", "AC-18"])
        #expect(hidden.hiddenBlocked == 1 && hidden.counts.blocked == 1)
        #expect(content(BoardFilter(app: "acme-mobile", blocked: false)).hiddenBlocked == 1)
        #expect(content(BoardFilter(app: "acme-backend", blocked: false)).hiddenBlocked == 0)
        #expect(content(BoardFilter(blocked: false), search: "offline").hiddenBlocked == 1)
        #expect(content(BoardFilter(blocked: false), search: "order history").hiddenBlocked == 0)
        #expect(content(BoardFilter(app: "acme-backend")).counts.blocked == 0)
      }
    }

    @Test func aBlockedTaskThatAsksYouStaysOnTheBoard() throws {
      let ask: (URL) throws -> Void = { home in
        try AppTestCLI.run(
          [
            "--ws", "acme", "comment", "AC-17", "--kind", "question",
            "--to", "human:acme", "-m", "Ship the banner before the totals land?",
          ], home: home, seed: 300)
      }
      try fixture(prepare: ask) { snapshot, _ in
        let content = BoardContent(
          snapshot: snapshot, apps: [], filter: BoardFilter(blocked: false), search: "")
        #expect(content.lanes[0].tasks.map(\.ref).contains("AC-17"))
        #expect(content.hiddenBlocked == 0 && content.counts.blocked == 0)
        #expect(content.questions.contains("AC-17"))
      }
    }

    @Test func hidingDoneLeavesOutTheDoneLaneAndCountsFollowAppAndSearch() throws {
      try fixture { snapshot, _ in
        func content(_ filter: BoardFilter, search: String = "") -> BoardContent {
          BoardContent(snapshot: snapshot, apps: [], filter: filter, search: search)
        }
        let all = content(BoardFilter(done: false))
        #expect(all.lanes.map(\.title) == ["Todo", "Doing", "Review"])
        #expect(all.counts == BoardContent.Counts(blocked: 1, proposed: 3, done: 4))
        #expect(content(BoardFilter()).lanes.map(\.title).last == "Done this week")
        #expect(
          content(BoardFilter(app: "acme-mobile")).counts
            == BoardContent.Counts(blocked: 1, proposed: 1, done: 2))
        #expect(
          content(BoardFilter(), search: "ac-19").counts
            == BoardContent.Counts(blocked: 0, proposed: 0, done: 1))
        let proposals = content(BoardFilter(proposals: true, blocked: false))
        #expect(proposals.lanes[0].tasks.map(\.ref).contains("AC-22"))
        #expect(!proposals.lanes[0].tasks.map(\.ref).contains("AC-17"))
      }
    }

    @Test func cardLabelsUseTheMapNameAndTheSidebarColour() throws {
      try fixture { snapshot, map in
        let web = try #require(snapshot.board.todo.first { $0.ref == "AC-15" })
        let content = BoardContent(
          snapshot: snapshot, apps: map.apps, filter: BoardFilter(), search: "")
        #expect(
          content.appLabel(for: web) == BoardContent.AppLabel(name: "acme-web", color: "AppBlue"))
        #expect(
          SidebarContent.appColor(slug: "acme-web", apps: map.apps, chosen: [:])
            == AppPalette.automatic("acme-web"))
        #expect(
          SidebarContent.appColor(slug: "acme-mobile", apps: map.apps, chosen: [:])
            == AppPalette.automatic("acme-mobile"))
        #expect(SidebarContent.appColor(slug: "gone", apps: map.apps, chosen: [:]) == nil)
        #expect(BoardContent.appLabel(nil, apps: map.apps, colours: [:]) == nil)
        #expect(BoardContent.appLabel("gone", apps: map.apps, colours: [:]) == .init(name: "gone", color: nil))
        let named = [
          AppMapApp(
            slug: "acme-web", name: "Acme web shop", repo: "web", ref: "origin/main",
            productionRef: nil, subpath: nil, summary: nil, lifecycle: "active",
            attachment: "app:acme-web")
        ]
        let renamed = BoardContent(
          snapshot: snapshot, apps: named, filter: BoardFilter(), search: "web shop")
        #expect(renamed.lanes.flatMap(\.tasks).map(\.ref) == ["AC-15"])
        #expect(renamed.appLabel(for: web) == .init(name: "Acme web shop", color: "AppBlue"))
        #expect(
          renamed.accessibilityLabel(for: web, asked: false)
            == "AC-15: Order history page, Acme web shop, todo")
      }
    }

    @Test func filterTitleCountsOnlyNarrowingFilters() throws {
      try fixture { _, map in
        let apps = map.apps
        #expect(BoardFilter().isDefault && BoardFilter().narrowingCount == 0)
        #expect(!BoardFilter(proposals: true).isDefault)
        #expect(BoardFilter(proposals: true).narrowingCount == 0)
        #expect(BoardFilter().title(apps: apps) == "Filter")
        #expect(BoardFilter(proposals: true).title(apps: apps) == "Filter")
        #expect(BoardFilter(app: "acme-mobile").title(apps: apps) == "acme-mobile")
        #expect(
          BoardFilter(app: "acme-mobile", blocked: false).title(apps: apps) == "acme-mobile · 2")
        #expect(BoardFilter(blocked: false, done: false).title(apps: apps) == "Filtered · 2")
        #expect(BoardFilter(app: "gone").title(apps: apps) == "gone")
        let named = [
          AppMapApp(
            slug: "acme-web", name: "Acme web shop", repo: "web", ref: "origin/main",
            productionRef: nil, subpath: nil, summary: nil, lifecycle: "active",
            attachment: "app:acme-web")
        ]
        #expect(
          BoardFilter(app: "acme-web", done: false).title(apps: named) == "Acme web shop · 2")
      }
    }

    @Test func showTogglesPersistAndAWorkspaceSwitchClearsOnlyTheApp() async throws {
      let suite = "silta.tests.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }  // cleanup
      let model = AppModel(defaults: defaults, load: { _, _, _ in nil })
      #expect(model.boardFilter == BoardFilter())
      model.boardFilter.blocked = false
      model.boardFilter.done = false
      model.boardFilter.proposals = true
      model.showApp("acme-mobile")
      #expect(model.boardFilter.app == "acme-mobile")
      await model.selectWorkspace("other").value
      #expect(model.boardFilter == BoardFilter(proposals: true, blocked: false, done: false))
      let reopened = AppModel(defaults: defaults, load: { _, _, _ in nil })
      #expect(reopened.boardFilter == BoardFilter(blocked: false, done: false))
      reopened.search = "push"
      reopened.boardFilter.app = "acme-web"
      reopened.resetBoardFilter()
      #expect(reopened.boardFilter == BoardFilter() && reopened.search == "push")
      #expect(AppModel(defaults: defaults, load: { _, _, _ in nil }).boardFilter == BoardFilter())
      #expect(AppModel.filterDefaults(automated: true) == nil)
      #expect(AppModel.filterDefaults(automated: false) === UserDefaults.standard)
    }

    @Test func hiddenTaskKeepsItsInspectorAndTheHeaderCountsHiddenBlocked() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let snapshot = try reader.snapshot(workspace: "acme")
      let model = AppModel(
        reader: reader,
        load: { _, _, _ in
          AppLoadedData(
            workspaces: [], workspace: "acme", snapshot: snapshot, map: nil, version: 1,
            checkedAt: AppV2Fixture.now)
        })
      await model.refresh().value
      model.inspect(task: "AC-17")
      #expect(model.screenSummary == "7 open · 3 proposed · 4 done this week")
      model.boardFilter.blocked = false
      #expect(model.screenSummary == "7 open · 1 blocked hidden · 3 proposed · 4 done this week")
      #expect(model.boardSelection == BoardSelection(taskRef: "AC-17"))
      #expect(model.boardInspectorPresented)
      model.boardFilter.app = "acme-backend"
      model.search = "order history"
      #expect(model.screenSummary == "7 open · 1 blocked hidden · 3 proposed · 4 done this week")
    }

    @Test func onlyQuestionsToTheHumanKeepBlockedTasksAndTheFootnoteCountsTheRest() throws {
      let block: (URL) throws -> Void = { home in
        for (index, ref) in ["AC-16", "AC-18"].enumerated() {
          try AppTestCLI.run(
            ["--ws", "acme", "task", "block", ref, "-m", "Waiting on the API."],
            home: home, seed: 310 + index)
        }
        try AppTestCLI.run(
          [
            "--ws", "acme", "comment", "AC-18", "--kind", "question",
            "--to", "agent:codex:fixture", "-m", "Which error codes stay?",
          ], home: home, seed: 320)
      }
      try fixture(prepare: block) { snapshot, _ in
        func content(_ filter: BoardFilter, search: String = "") -> BoardContent {
          BoardContent(snapshot: snapshot, apps: [], filter: filter, search: search)
        }
        let hidden = content(BoardFilter(blocked: false))
        #expect(hidden.lanes[0].tasks.map(\.ref) == ["AC-15"])
        #expect(hidden.hiddenBlocked == 3 && hidden.counts.blocked == 3)
        #expect(hidden.hiddenBlockedText == "3 blocked tasks hidden")
        #expect(content(BoardFilter()).hiddenBlockedText == nil)
        let one = content(BoardFilter(app: "acme-mobile", blocked: false), search: "offline")
        #expect(one.lanes[0].tasks.isEmpty && one.hiddenBlockedText == "1 blocked task hidden")
      }
    }

    private func fixture(
      prepare: (URL) throws -> Void = { _ in },
      _ body: (AppSnapshot, AppWorkspaceMap) throws -> Void
    ) throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      try prepare(home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      try body(reader.snapshot(workspace: "acme"), reader.workspaceMap(workspace: "acme"))
    }
  }
#endif
