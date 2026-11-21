#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct TaskMenuTests {
    @Test func todoCardOffersEveryActionAndExplainsAMissingWorktree() throws {
      try fixture { reader in
        let task = try reader.task("AC-15", workspace: "acme")
        let items = TaskMenu.items(
          for: task, reader: reader, workspace: "acme", name: "Acme", exists: { _ in true })
        #expect(
          items.map(\.title) == [
            "Open in Inspector", "Copy Ref AC-15", "Copy Agent Prompt", "Copy “task show” Command",
            "Filter Board to acme-web", "Show Docs About acme-web", "Reveal Worktree",
          ])
        #expect(items.first?.action == .inspect("AC-15"))
        #expect(items[1].action == .copy("AC-15"))
        #expect(
          items[2].action
            == .copy(reader.agentPrompt(task: "AC-15", workspace: "acme", name: "Acme")))
        #expect(items[3].action == .copy(reader.readCommand(task: "AC-15", workspace: "acme").text))
        #expect(items[4].action == .filterBoard("acme-web"))
        #expect(items[5].action == .showDocs("app:acme-web"))
        #expect(items[6].action == nil && items[6].reason == "not claimed")
        #expect(items.filter(\.separatorBefore).map(\.title) == ["Filter Board to acme-web"])
      }
    }

    @Test func doingCardRevealsAnExistingWorktreeOnly() throws {
      try fixture { reader in
        let task = try reader.task("AC-14", workspace: "acme")
        let worktree = try #require(task.worktree)
        let present = TaskMenu.items(
          for: task, reader: reader, workspace: "acme", name: "Acme", exists: { $0 == worktree })
        #expect(present.last?.action == .reveal(worktree))
        let gone = TaskMenu.items(
          for: task, reader: reader, workspace: "acme", name: "Acme", exists: { _ in false })
        #expect(gone.last?.action == nil && gone.last?.reason == "not on this Mac")
        #expect(present.contains { $0.title == "Copy Agent Prompt" })
      }
    }

    @Test func doneAndReviewTasksHaveNoAgentPrompt() throws {
      try fixture { reader in
        for ref in ["AC-8", "AC-9", "AC-17", "AC-22"] {
          let task = try reader.task(ref, workspace: "acme")
          let titles = TaskMenu.items(
            for: task, reader: reader, workspace: "acme", name: "Acme", exists: { _ in true }
          ).map(\.title)
          #expect(!titles.contains("Copy Agent Prompt"), "\(ref)")
          #expect(titles.contains("Copy Ref \(ref)"))
        }
      }
    }

    @Test func appMenuFiltersTheBoardAndShowsItsDocs() {
      let items = TaskMenu.items(forApp: "acme-mobile")
      #expect(items.map(\.title) == ["Filter Board to acme-mobile", "Show Docs About acme-mobile"])
      #expect(items.map(\.action) == [.filterBoard("acme-mobile"), .showDocs("app:acme-mobile")])
    }

    @Test func accessibilityActionsAreTheAvailableMenuItems() throws {
      try fixture { reader in
        let task = try reader.task("AC-15", workspace: "acme")
        let items = TaskMenu.items(
          for: task, reader: reader, workspace: "acme", name: "Acme", exists: { _ in true })
        #expect(
          TaskMenu.accessibilityActions(items).map(\.title)
            == items.filter { $0.action != nil }.map(\.title))
      }
    }

    @Test func performingAnActionDrivesTheModel() async throws {
      try fixture { reader in
        let model = AppModel(reader: reader, load: { _, _, _ in nil })
        model.perform(.filterBoard("acme-web"))
        #expect(model.route == .board && model.boardFilter.app == "acme-web")
        model.perform(.inspect("AC-15"))
        #expect(model.boardSelection?.taskRef == "AC-15" && model.boardInspectorPresented)
        model.perform(.showDocs("app:acme-web"))
        #expect(model.route == .docs && model.docsAbout == "app:acme-web")
      }
    }

    private func fixture(_ body: (AppReader) throws -> Void) throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      try body(AppReader(home: home, user: "acme", now: { AppV2Fixture.now }))
    }
  }
#endif
