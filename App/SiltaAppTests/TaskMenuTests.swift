#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct TaskMenuTests {
    @Test func todoCardOffersEveryActionAndExplainsAMissingWorktree() throws {
      try fixture { reader in
        let items = try menu("AC-15", reader)
        #expect(
          items.map(\.label) == [
            "Open in Inspector", "Copy Ref AC-15", "Copy Agent Prompt", "Copy “task show” Command",
            "Filter Board to acme-web", "Show Docs About acme-web",
            "Reveal Worktree (not claimed)",
          ])
        #expect(items[0].action == .inspect("AC-15"))
        #expect(items[1].action == .copy("AC-15"))
        guard case .copy(let prompt) = items[2].action, case .copy(let show) = items[3].action
        else {
          Issue.record("copy items")
          return
        }
        #expect(prompt.hasPrefix("Work on AC-15 in Acme. Read it with `SILTA_HOME="))
        #expect(show.hasPrefix("SILTA_HOME="))
        #expect(show.hasSuffix(" silta --ws 'acme' task show 'AC-15' --timeline"))
        #expect(items[4].action == .filterBoard("acme-web"))
        #expect(items[5].action == .showDocs("app:acme-web"))
        #expect(items[6].action == nil)
        #expect(items.filter(\.separatorBefore).map(\.title) == ["Filter Board to acme-web"])
        #expect(
          TaskMenu.accessibilityActions(items).map(\.title) == [
            "Open in Inspector", "Copy Ref AC-15", "Copy Agent Prompt", "Copy “task show” Command",
            "Filter Board to acme-web", "Show Docs About acme-web",
          ])
      }
    }

    @Test func revealNeedsARecordedAbsoluteWorktreeOnThisMac() throws {
      try fixture { reader in
        let task = try reader.task("AC-14", workspace: "acme")
        let worktree = try #require(task.worktree)
        #expect(TaskMenu.reveal(task, existing: [worktree]) == .available(.reveal(worktree)))
        #expect(TaskMenu.reveal(task, existing: []) == .unavailable(reason: "not on this Mac"))
        let present = try menu("AC-14", reader, existing: [worktree])
        #expect(TaskMenu.accessibilityActions(present).last?.title == "Reveal Worktree")
        for (ref, reason) in [
          ("AC-12", "no worktree recorded"), ("AC-8", "no worktree recorded"),
          ("AC-9", "no worktree recorded"), ("AC-22", "not claimed"),
        ] {
          #expect(
            TaskMenu.reveal(try reader.task(ref, workspace: "acme"), existing: [worktree])
              == .unavailable(reason: reason), "\(ref)")
        }
      }
    }

    @Test(arguments: [
      ("AC-15", "todo", "Copy Agent Prompt"), ("AC-14", "doing", "Copy Agent Prompt"),
      ("AC-12", "doing", "Copy Agent Prompt (claimed by Claude)"), ("AC-17", "blocked", nil),
      ("AC-22", "proposed", nil), ("AC-9", "review", nil), ("AC-8", "done", nil),
    ])
    func agentPromptFollowsWhetherAnotherAgentMayStart(
      ref: String, status: String, prompt: String?
    ) throws {
      try fixture { reader in
        #expect(try reader.task(ref, workspace: "acme").status == status)
        let labels = try menu(ref, reader).map(\.label)
        #expect(labels.first { $0.hasPrefix("Copy Agent Prompt") } == prompt)
        #expect(labels.contains("Copy Ref \(ref)"))
      }
    }

    @Test func aReleasedClaimOffersTheResumePrompt() throws {
      try fixture { reader, home in
        try AppTestCLI.run(
          ["--ws", "acme", "comment", "AC-12", "--kind", "handoff", "-m", "Parser done."],
          home: home, actor: "agent:claude:fixture")
        let card = try #require(
          try reader.snapshot(workspace: "acme").board.doing.first { $0.ref == "AC-12" })
        let items = TaskMenu.items(
          for: card,
          in: TaskMenu.Context(
            reader: reader, workspace: "acme", name: "Acme", existing: [], now: AppV2Fixture.now))
        #expect(items.contains { $0.label == "Copy Agent Prompt" && $0.action != nil })
      }
    }

    @Test func appMenuFiltersTheBoardAndShowsItsDocs() {
      let items = TaskMenu.items(forApp: "acme-mobile")
      #expect(items.map(\.title) == ["Filter Board to acme-mobile", "Show Docs About acme-mobile"])
      #expect(items.map(\.action) == [.filterBoard("acme-mobile"), .showDocs("app:acme-mobile")])
    }

    @Test func runningAnActionDrivesTheModel() throws {
      try fixture { reader in
        let model = AppModel(reader: reader, load: { _, _, _ in nil })
        model.run(.showDocs("app:acme-web"))
        #expect(model.route == .docs && model.docsAbout == "app:acme-web")
        model.run(.inspect("AC-15"))
        #expect(model.route == .board)
        #expect(model.boardSelection?.taskRef == "AC-15" && model.boardInspectorPresented)
        model.run(.filterBoard("acme-web"))
        #expect(model.route == .board && model.boardFilter.app == "acme-web")
      }
    }

    @Test func loadingRecordsOnlyWorktreesThatExist() throws {
      try fixture { reader in
        let snapshot = try reader.snapshot(workspace: "acme")
        #expect(snapshot.board.doing.contains { $0.worktree != nil })
        #expect(AppReadSession.existingWorktrees(snapshot).isEmpty)
        #expect(AppReadSession.existingWorktrees(nil).isEmpty)
      }
    }

    private func menu(_ ref: String, _ reader: AppReader, existing: Set<String> = [])
      throws -> [TaskMenu.Item]
    {
      TaskMenu.items(
        for: try reader.task(ref, workspace: "acme"),
        in: TaskMenu.Context(
          reader: reader, workspace: "acme", name: "Acme", existing: existing,
          now: AppV2Fixture.now))
    }

    private func fixture(_ body: (AppReader) throws -> Void) throws {
      try fixture { reader, _ in try body(reader) }
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
