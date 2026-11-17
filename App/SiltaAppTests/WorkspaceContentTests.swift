#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct WorkspaceContentTests {
    @Test func groupsRetainEveryConnectionIncludingServiceTargets() throws {
      try fixture { map in
        let all = WorkspaceContent(map: map, search: "")
        #expect(all.groups.count == 3)
        #expect(all.groups.flatMap(\.connections).count == 4)
        let filtered = WorkspaceContent(map: map, search: "PAYMENTS")
        #expect(filtered.groups.map { $0.app.slug } == ["acme-backend"])
        #expect(filtered.groups.flatMap(\.connections).map(\.target) == ["service:payments"])
      }
    }

    @Test func canonicalConnectionSelectionSurvivesSearchAndMissingRefsRefuse() throws {
      try fixture { map in
        let sdk = try #require(map.connections.first { $0.kind == "sdk" })
        let filtered = WorkspaceContent(map: map, search: sdk.attachment)
        #expect(filtered.groups.flatMap(\.connections) == [sdk])
        #expect(filtered.connection(sdk.attachment) == sdk)
        #expect(filtered.connection("edge:missing/missing/sdk") == nil)
        let hidden = WorkspaceContent(map: map, search: "unrelated")
        #expect(hidden.groups.isEmpty && hidden.connection(sdk.attachment) == sdk)
      }
    }

    private func fixture(_ body: (AppWorkspaceMap) throws -> Void) throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      try body(reader.workspaceMap(workspace: "acme"))
    }
  }
#endif
