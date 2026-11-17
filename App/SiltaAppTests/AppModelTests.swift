#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor @Suite(.timeLimit(.minutes(1)))
  struct AppModelTests {
    @Test func forcedRequestsCoalesceAndAllCallersWait() async {
      do {
        let driver = ControlledLoads()
        let model = makeModel(driver)
        let first = model.refresh()
        let one = await driver.next()
        let second = model.refresh(force: true)
        driver.finish(one, .success(value(1)))
        let two = await driver.next()
        #expect(two.previous?.version == 1 && two.force)
        driver.finish(two, .success(value(2)))
        await first.value
        await second.value
        #expect(model.data?.version == 2 && !model.isLoading)
      }
    }

    @Test(arguments: [false, true]) func selectionGenerationRejectsOldSuccessAndFailure(
      _ fails: Bool
    ) async {
      do {
        let driver = ControlledLoads()
        let model = makeModel(driver)
        let initial = model.refresh()
        driver.finish(await driver.next(), .success(value(1)))
        await initial.value
        let old = model.refresh(force: true)
        let stale = await driver.next()
        let beta = model.selectWorkspace("beta")
        #expect(model.visibleData == nil)
        let acme = model.selectWorkspace("acme")
        if fails {
          driver.finish(stale, .failure(AppLoadFailure(message: "stale")))
        } else {
          driver.finish(stale, .success(value(2)))
        }
        let current = await driver.next()
        #expect(current.workspace == "acme")
        #expect(model.data?.version == 1 && model.failure == nil)
        driver.finish(current, .success(value(3)))
        driver.finishAll(value(3))
        await old.value
        await beta.value
        await acme.value
        #expect(model.data?.version == 3 && model.workspace == "acme")
      }
    }

    @Test func failuresKeepDataAndRetryHydration() async {
      do {
        let driver = ControlledLoads()
        let model = makeModel(driver)
        let initial = model.refresh()
        driver.finish(await driver.next(), .success(value(1)))
        await initial.value
        let failing = model.refresh(force: true)
        driver.finish(await driver.next(), .failure(AppLoadFailure(message: "unavailable")))
        await failing.value
        #expect(model.data?.version == 1 && model.failure?.message == "unavailable")
        let retry = model.refresh()
        let request = await driver.next()
        #expect(request.force)
        driver.finish(request, .success(value(1)))
        await retry.value
        #expect(model.failure == nil && model.data?.version == 1)
      }
    }

    @Test func backgroundTicksDoNotReadAndUnchangedChecksKeepData() async {
      do {
        let driver = ControlledLoads()
        let model = makeModel(driver)
        #expect(model.tick(frontmost: false) == nil)
        let initial = model.refresh()
        driver.finish(await driver.next(), .success(value(1)))
        await initial.value
        let check = model.tick(frontmost: true)
        driver.finish(await driver.next(), .success(nil))
        await check?.value
        #expect(model.data?.version == 1)
      }
    }

    @Test func searchMatchesReferencesAndFullBodiesWithoutCaseSensitivity() {
      let model = makeModel(ControlledLoads())
      #expect(model.matches(["AC-12", "Full question body"]))
      model.search = "ac-12"
      #expect(model.matches(["AC-12", "Full question body"]))
      model.search = "QUESTION"
      #expect(model.matches(["AC-12", "Full question body"]))
      model.search = "AC-1"
      #expect(!model.matches(["AC-10", "AC-12", "AC-19"]))
      #expect(model.matches(["AC-1", "Read task AC-1."]))
      model.search = "unrelated"
      #expect(!model.matches(["AC-12", "Full question body"]))
    }

    @Test func boardNavigationRetainsSelectionFiltersAndInspector() async {
      let model = makeModel(ControlledLoads())
      model.showProposed = true
      model.showApp("acme-mobile")
      model.inspect(task: "AC-12")
      #expect(model.route == .board && model.boardInspectorPresented)
      model.navigate(to: .mywork)
      model.toggleInspector()
      model.navigate(to: .board)
      #expect(model.boardSelection == BoardSelection(taskRef: "AC-12"))
      #expect(model.boardInspectorPresented && model.showProposed)
      #expect(model.appFilter == "acme-mobile")
      model.toggleInspector()
      #expect(!model.boardInspectorPresented)
    }

    @Test func routeInspectorsAndTypedSelectionsRemainIndependent() async {
      let model = AppModel(load: { _, _, _ in nil })
      model.showProposed = true
      model.inspect(task: "AC-12")
      model.navigate(to: .workspace)
      #expect(!model.workspaceInspectorPresented)
      model.select(connection: "conn:acme-mobile->acme-backend")
      #expect(model.workspaceInspectorPresented && model.boardInspectorPresented)
      model.toggleInspector()
      model.navigate(to: .board)
      #expect(model.boardSelection?.taskRef == "AC-12" && model.showProposed)
      #expect(model.boardInspectorPresented)
      model.navigate(to: .workspace)
      #expect(model.workspaceSelection?.connectionRef == "conn:acme-mobile->acme-backend")
      #expect(!model.workspaceInspectorPresented)
      await model.selectWorkspace("other").value
      #expect(model.workspaceSelection == nil && model.boardSelection == nil)
      #expect(!model.boardInspectorPresented && !model.workspaceInspectorPresented)
    }

    @Test func documentNavigationRetainsTypedSelectionAcrossRoutes() {
      let model = AppModel(load: { _, _, _ in nil })
      model.openDocument("doc:order-contract@3")
      #expect(
        model.documentSelection == DocumentSelection(ref: "doc:order-contract@3", view: .changes))
      model.navigate(to: .board)
      model.navigate(to: .docs)
      #expect(model.documentSelection?.ref == "doc:order-contract@3")
      model.select(documentView: .comments)
      #expect(model.documentSelection?.view == .comments)
      model.openDocuments(about: "app:acme-mobile")
      #expect(model.documentSelection == nil && model.docsAbout == "app:acme-mobile")
    }

    @Test func searchMatchesPinnedDocumentReferencesExactly() {
      let model = AppModel(load: { _, _, _ in nil })
      model.search = "doc:order-contract@1"
      #expect(model.matches(["doc:order-contract@1"]))
      #expect(!model.matches(["doc:order-contract@10"]))
      model.search = "doc:order.contract@1"
      #expect(model.matches(["Read doc:order.contract@1."]))
    }

    @Test func selectingAnotherTaskClearsAnObsoleteDetailFailure() async {
      let model = AppModel(load: { _, _, _ in nil })
      model.inspect(task: "AC-12")
      await model.taskDetail.load(workspace: "acme", ref: "AC-12") {
        throw AppLoadFailure(message: "Acme task unavailable")
      }
      #expect(model.taskDetail.failure != nil)
      model.inspect(task: "AC-14")
      #expect(model.taskDetail.failure == nil && model.taskDetail.value == nil)
      #expect(!ControlState(model: model, run: "acme", revision: 1, dark: false).idle)
    }

    private func makeModel(_ driver: ControlledLoads) -> AppModel {
      AppModel(
        load: { previous, workspace, force in
          try await driver.load(previous, workspace, force)
        })
    }

    private func value(_ version: Int) -> AppLoadedData {
      AppLoadedData(
        workspaces: [], workspace: "acme", snapshot: nil, map: nil,
        version: version, checkedAt: AppV2Fixture.now)
    }
  }
#endif
