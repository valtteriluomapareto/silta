#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct TaskDetailModelTests {
    @Test func retryRecoversDetailWithoutADatabaseCommit() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let probe = try reader.makeChangeProbe()
      let before = try probe.version()
      let detail = TaskDetailModel()
      await detail.load { throw AppLoadFailure(message: "Acme transient read failure") }
      #expect(detail.value == nil && detail.failure == "Acme transient read failure")
      await detail.load { try reader.task("AC-12", workspace: "acme") }
      #expect(detail.value?.ref == "AC-12" && detail.failure == nil && !detail.isLoading)
      #expect(try probe.version() == before)
    }
  }
#endif
