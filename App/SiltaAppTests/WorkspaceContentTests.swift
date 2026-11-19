#if DEBUG
  import Foundation
  @testable import SiltaApp
  @testable import SiltaAppSupport
  import Testing

  @MainActor struct WorkspaceContentTests {
    @Test func appsFollowCallOrderAndCarryTheirConnections() throws {
      try fixture { map in
        let all = WorkspaceContent(map: map, search: "")
        #expect(all.apps.map(\.id) == ["acme-mobile", "acme-web", "acme-backend"])
        let mobile = try #require(all.apps.first)
        #expect(mobile.calls.map(\.target) == ["acme-backend"])
        #expect(mobile.calledBy.isEmpty && mobile.services == ["push"])
        let backend = try #require(all.apps.last)
        #expect(backend.calledBy.map(\.source) == ["acme-mobile", "acme-web"])
        #expect(backend.calls.isEmpty && backend.uses.map(\.target) == ["service:payments"])
        #expect(all.shared.map(\.id) == ["payments", "push"] && all.folded.isEmpty)
        #expect(
          all.related(to: "acme-backend") == ["acme-mobile", "acme-web", "service:payments"])
        #expect(all.related(to: nil).isEmpty)
      }
    }

    @Test func searchKeepsAppsAndServicesTouchingAMatch() throws {
      try fixture { map in
        let filtered = WorkspaceContent(map: map, search: "PAYMENTS")
        #expect(filtered.apps.map(\.id) == ["acme-backend"])
        #expect(filtered.shared.map(\.id) == ["payments"])
        let sdk = try #require(map.connections.first { $0.kind == "sdk" })
        let byRef = WorkspaceContent(map: map, search: sdk.attachment)
        #expect(byRef.apps.map(\.id) == ["acme-mobile"] && byRef.shared.map(\.id) == ["push"])
        #expect(byRef.connection(sdk.attachment) == sdk)
        #expect(byRef.connection("edge:missing/missing/sdk") == nil)
        let hidden = WorkspaceContent(map: map, search: "unrelated")
        #expect(hidden.apps.isEmpty && hidden.shared.isEmpty)
        #expect(hidden.connection(sdk.attachment) == sdk)
      }
    }

    @Test func sharedServicesComeFirstAndTheRestFold() {
      let content = WorkspaceContent(map: Self.foldMap, search: "")
      #expect(content.shared.map(\.id) == ["s0", "s1"])
      #expect(content.folded.map(\.id) == ["s2", "s3"])
      #expect(content.apps.first?.services == ["s0", "s1", "s2"])
      #expect(content.shared.first?.users.map(\.source) == ["a", "b"])
    }

    private static var foldMap: AppWorkspaceMap {
      let edges = [
        ("a", "service:s1"), ("b", "service:s1"), ("a", "service:s2"), ("b", "service:s0"),
        ("a", "service:s0"),
      ]
      return AppWorkspaceMap(
        apps: ["a", "b"].map {
          AppMapApp(
            slug: $0, name: $0, repo: $0, ref: "origin/main", productionRef: nil, subpath: nil,
            summary: nil, lifecycle: "active", attachment: "app:" + $0)
        },
        services: ["s0", "s1", "s2", "s3"].map {
          AppMapService(slug: $0, name: $0, summary: nil, attachment: "service:" + $0)
        },
        connections: edges.map {
          AppConnection(
            attachment: "edge:\($0.0)/\($0.1)/sdk", source: $0.0, target: $0.1, kind: "sdk",
            summary: "", codeReferences: [])
        })
    }

    @Test func servicesMatchTheirConnectionsByRawSlug() {
      let map = AppWorkspaceMap(
        apps: [
          AppMapApp(
            slug: "api", name: "api", repo: "api", ref: "origin/main", productionRef: nil,
            subpath: nil, summary: nil, lifecycle: "active", attachment: "app:api")
        ],
        services: [
          AppMapService(slug: "aws.s3", name: "S3", summary: nil, attachment: "service:aws%2Es3")
        ],
        connections: [
          AppConnection(
            attachment: "edge:api/service:aws.s3/sdk", source: "api", target: "service:aws.s3",
            kind: "sdk", summary: "", codeReferences: [])
        ])
      let content = WorkspaceContent(map: map, search: "")
      #expect(content.shared.first?.apps == 1 && content.apps.first?.services == ["aws.s3"])
      #expect(map.nodeKey(for: "service:aws%2Es3") == "service:aws.s3")
      #expect(map.nodeKey(for: "app:api") == "api" && map.nodeKey(for: "app:missing") == nil)
      #expect(content.related(to: "service:aws.s3") == ["api"])
      #expect(WorkspaceContent(map: map, search: "S3").shared.map(\.id) == ["aws.s3"])
    }

    @Test func foldedServicesSayWhetherAnyHasNoApp() {
      let content = WorkspaceContent(map: Self.foldMap, search: "")
      #expect(WorkspaceList.foldedTitle(content.folded) == "2 more used by one app or none")
      #expect(
        WorkspaceList.foldedTitle(Array(content.folded.prefix(1))) == "1 more used by one app")
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
