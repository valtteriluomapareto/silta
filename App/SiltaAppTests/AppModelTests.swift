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
        let retry = model.focused()
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
      model.search = "unrelated"
      #expect(!model.matches(["AC-12", "Full question body"]))
    }

    private func makeModel(_ driver: ControlledLoads) -> AppModel {
      AppModel(
        load: { previous, workspace, force in
          try await driver.load(previous, workspace, force)
        }, now: { AppV2Fixture.now })
    }

    private func value(_ version: Int) -> AppLoadedData {
      AppLoadedData(
        workspaces: [], workspace: "acme", snapshot: nil, map: nil,
        version: version, checkedAt: AppV2Fixture.now)
    }
  }
#endif
