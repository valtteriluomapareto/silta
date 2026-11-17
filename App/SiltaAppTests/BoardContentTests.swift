#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SiltaAppSupport
  import Testing

  @MainActor struct BoardContentTests {
    @Test func lanesFilterAppsAndKeepProposalsOptional() throws {
      try fixture { snapshot in
        let ordinary = BoardContent(snapshot: snapshot, app: nil, search: "", proposals: false)
        #expect(ordinary.lanes.map { $0.tasks.count } == [4, 2, 1, 3])
        let mobile = BoardContent(
          snapshot: snapshot, app: "acme-mobile", search: "", proposals: true)
        #expect(mobile.lanes.map { $0.tasks.count } == [2, 2, 0, 2])
        #expect(mobile.lanes[0].tasks.contains { $0.ref == "AC-22" && $0.status == "proposed" })
        #expect(mobile.lanes.flatMap(\.tasks).allSatisfy { $0.app == "acme-mobile" })
      }
    }

    @Test func searchFindsCanonicalRefsAndTitlesAndQuestionMarkers() throws {
      try fixture { snapshot in
        let content = BoardContent(snapshot: snapshot, app: nil, search: "ac-12", proposals: true)
        #expect(content.lanes.flatMap(\.tasks).map(\.ref) == ["AC-12"])
        #expect(content.questions == ["AC-12"])
        let title = BoardContent(
          snapshot: snapshot, app: nil, search: "ORDER HISTORY", proposals: false)
        #expect(title.lanes.flatMap(\.tasks).map(\.ref) == ["AC-15"])
      }
    }

    private func fixture(_ body: (AppSnapshot) throws -> Void) throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppV2Fixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      try body(reader.snapshot(workspace: "acme"))
    }
  }
#endif
