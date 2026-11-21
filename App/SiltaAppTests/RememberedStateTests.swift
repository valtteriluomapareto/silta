#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct RememberedStateTests {
    @Test func reopensTheLastWorkspaceAndScreen() async throws {
      try await fixture { reader, session, defaults in
        let first = model(reader, session, defaults)
        await first.refresh().value
        first.navigate(to: .docs)
        await first.selectWorkspace("acme").value

        let requested = Requests()
        let next = AppModel(
          reader: reader, now: { AppV2Fixture.now }, stateDefaults: defaults,
          load: { previous, workspace, force in
            await requested.add(workspace)
            return try session.load(previous: previous, workspace: workspace, force: force)
          })
        #expect(next.route == .docs)
        await next.refresh().value
        #expect(await requested.all.first == "acme")
        #expect(next.visibleData?.workspace == "acme")
      }
    }

    @Test func fixtureRunsNeverTouchTheHumansRememberedState() {
      #expect(AppModel.stateDefaults(fixture: true) == nil)
      #expect(AppModel.stateDefaults(fixture: false) == .standard)
    }

    @Test func aDraftThatLooksLikeASecretStaysInMemory() {
      let defaults = Self.defaults()
      let target = ActionTarget(workspace: "acme", ref: "AC-14")
      let actions = ActionModel(defaults: defaults)
      let token = "ghp_" + String(repeating: "a1B2", count: 9)
      actions.setDraft("Use " + token, for: target)
      #expect(actions.draft(target) == "Use " + token)
      #expect(ActionModel(defaults: defaults).draft(target) == "")
      actions.setDraft("   \n", for: target)
      #expect(actions.draft(target) == "")
    }

    @Test func aRemovedWorkspaceFallsBackToTheFirst() async throws {
      try await fixture { reader, session, defaults in
        defaults.set("gone", forKey: AppModel.lastWorkspaceKey)
        defaults.set("not-a-route", forKey: AppModel.lastRouteKey)
        let model = model(reader, session, defaults)
        #expect(model.route == .mywork)
        model.inspect(task: "AC-15")
        await model.refresh().value
        #expect(model.workspace == "acme")
        #expect(model.visibleData?.workspace == "acme")
        #expect(model.failure == nil)
        #expect(model.boardSelection == nil)
        #expect(defaults.string(forKey: AppModel.lastWorkspaceKey) == "acme")
      }
    }

    @Test func automatedRunsNeitherReadNorStoreTheScreen() async throws {
      try await fixture { reader, session, defaults in
        defaults.set("board", forKey: AppModel.lastRouteKey)
        let automated = model(reader, session, nil)
        #expect(automated.route == .mywork)
        automated.navigate(to: .workspace)
        #expect(defaults.string(forKey: AppModel.lastRouteKey) == "board")
        #expect(AppModel.stateDefaults(fixture: true) == nil)
      }
    }

    @Test func unsentDraftsSurviveARelaunchAndClearOnSuccess() {
      let defaults = Self.defaults()
      let answer = ActionTarget(workspace: "acme", ref: "AC-12/1")
      let comment = ActionTarget(workspace: "acme", ref: "AC-14")
      let first = ActionModel(defaults: defaults)
      first.setDraft("Show them under Other.", for: answer)
      first.setDraft("Draft comment", for: comment)
      first.setDraft("", for: comment)

      let relaunched = ActionModel(defaults: defaults)
      #expect(relaunched.draft(answer) == "Show them under Other.")
      #expect(relaunched.draft(comment) == "")
      #expect(relaunched.begin(answer))
      relaunched.finish(answer, failure: nil)
      #expect(ActionModel(defaults: defaults).draft(answer) == "")

      let memoryOnly = ActionModel()
      memoryOnly.setDraft("Kept in memory", for: answer)
      #expect(ActionModel(defaults: defaults).draft(answer) == "")
    }

    @Test func aFailedSendKeepsTheStoredDraft() {
      let defaults = Self.defaults()
      let target = ActionTarget(workspace: "acme", ref: "AC-14")
      let actions = ActionModel(defaults: defaults)
      actions.setDraft("Still here", for: target)
      #expect(actions.begin(target))
      actions.finish(
        target, failure: ActionFailure(AppLoadFailure(message: "busy", commands: [])))
      #expect(ActionModel(defaults: defaults).draft(target) == "Still here")
    }

    private func model(_ reader: AppReader, _ session: AppReadSession, _ defaults: UserDefaults?)
      -> AppModel
    {
      AppModel(
        reader: reader, now: { AppV2Fixture.now }, stateDefaults: defaults,
        load: { previous, workspace, force in
          try session.load(previous: previous, workspace: workspace, force: force)
        })
    }

    private actor Requests {
      private(set) var all: [String?] = []
      func add(_ workspace: String?) { all.append(workspace) }
    }

    private static func defaults() -> UserDefaults {
      let name = "silta-tests-" + UUID().uuidString
      let defaults = UserDefaults(suiteName: name)
      defaults?.removePersistentDomain(forName: name)
      return defaults ?? .standard
    }

    private func fixture(
      _ body: (AppReader, AppReadSession, UserDefaults) async throws -> Void
    ) async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let defaults = Self.defaults()
      try await body(reader, AppReadSession(reader: reader, now: { AppV2Fixture.now }), defaults)
    }
  }
#endif
