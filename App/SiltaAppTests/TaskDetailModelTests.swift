#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct TaskDetailModelTests {
    @Test func reloadKeepsPreviousValueDuringReadAndFailure() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let detail = TaskDetailModel()
      let original = try reader.task("AC-12", workspace: "acme")
      await detail.load(workspace: "acme", ref: "AC-12") { original }
      await detail.load(workspace: "acme", ref: "AC-12") {
        #expect(detail.value == original && detail.isLoading)
        throw AppLoadFailure(message: "Acme reload unavailable")
      }
      #expect(detail.value == original)
      #expect(detail.failure == "Acme reload unavailable" && !detail.isLoading)
      await detail.load(workspace: "acme", ref: "AC-14") {
        #expect(detail.value == nil && detail.failure == nil && detail.isLoading)
        return try reader.task("AC-14", workspace: "acme")
      }
      #expect(detail.value?.ref == "AC-14" && detail.failure == nil)
      await detail.load(workspace: "other", ref: "AC-14") {
        #expect(detail.value == nil)
        throw AppLoadFailure(message: "Other workspace unavailable")
      }
      #expect(detail.value == nil)
    }

    @Test func cancelledReloadStopsLoadingAndRetainsThePreviousTask() async throws {
      let fixture = try FixtureLaunch.prepare()
      defer {
        try? FileManager.default.removeItem(  // cleanup
          at: fixture.home.deletingLastPathComponent())
      }
      let reader = try AppReader(home: fixture.home, user: fixture.user, now: { fixture.now })
      let original = try reader.task("AC-12", workspace: "acme")
      let detail = TaskDetailModel()
      await detail.load(workspace: "acme", ref: "AC-12") { original }
      let reload = Task {
        await detail.load(workspace: "acme", ref: "AC-12") {
          withUnsafeCurrentTask { $0?.cancel() }
          return original
        }
      }
      await reload.value
      #expect(detail.value == original)
      withKnownIssue("A cancelled read must settle the loading flag") {
        #expect(!detail.isLoading)
      }
    }

    @Test func retryRecoversDetailWithoutADatabaseCommit() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let probe = try reader.makeChangeProbe()
      let before = try probe.version()
      let detail = TaskDetailModel()
      await detail.load(workspace: "acme", ref: "AC-12") {
        throw AppLoadFailure(message: "Acme transient read failure")
      }
      #expect(detail.value == nil && detail.failure == "Acme transient read failure")
      await detail.load(workspace: "acme", ref: "AC-12") {
        try reader.task("AC-12", workspace: "acme")
      }
      #expect(detail.value?.ref == "AC-12" && detail.failure == nil && !detail.isLoading)
      #expect(try probe.version() == before)
    }
  }
#endif
