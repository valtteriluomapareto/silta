#if DEBUG
  import Foundation
  @testable import SiltaAppSupport
  import SiltaTestSupport
  import Testing

  @Suite(.blockingTestWork)
  struct AppMapLayoutTests {
    @Test func acmeSeedLaysOutCallersBeforeProvidersAndServicesLast() throws {
      try withScratchDirectory { scratch in
        try AppFixtures.seed(in: scratch)
        let reader = try AppReaderTests.reader(scratch)
        do {
          let layout = AppMapLayout(map: try reader.workspaceMap(workspace: "acme"))

          #expect(layout.columnCount == 3)
          #expect(
            place(layout) == [
              "acme-mobile 0/0", "acme-web 0/1", "acme-backend 1/0", "service:payments 2/0",
              "service:push 2/1",
            ])
          #expect(layout.backEdges.isEmpty)
          #expect(layout.node("service:push")?.attachment == "service:push")
          #expect(layout.node("acme-web")?.attachment == "app:acme-web")
        }
      }
    }

    @Test func twelveAppsOrderEachColumnByTheirCallers() {
      let edges = [
        ("android", "bff-mobile"), ("ios", "bff-mobile"), ("storefront", "bff-web"),
        ("support-admin", "gateway"), ("vendor-portal", "gateway"), ("bff-mobile", "orders"),
        ("bff-mobile", "accounts"), ("bff-web", "orders"), ("bff-web", "catalog"),
        ("gateway", "accounts"), ("gateway", "notifications"), ("orders", "service:stripe"),
        ("notifications", "service:apns"),
      ]
      let layout = AppMapLayout(
        map: Self.map(
          apps: [
            "accounts", "android", "bff-mobile", "bff-web", "catalog", "gateway", "ios",
            "notifications", "orders", "storefront", "support-admin", "vendor-portal",
          ], services: ["apns", "stripe"], edges: edges))
      #expect(
        place(layout) == [
          "android 0/0", "ios 0/1", "storefront 0/2", "support-admin 0/3", "vendor-portal 0/4",
          "bff-mobile 1/0", "bff-web 1/1", "gateway 1/2", "orders 2/0", "accounts 2/1",
          "catalog 2/2", "notifications 2/3", "service:stripe 3/0", "service:apns 3/1",
        ])
    }

    @Test func cyclesMarkTheClosingEdgeAndKeepColumns() {
      let layout = AppMapLayout(
        map: Self.map(
          apps: ["alpha", "beta", "client"], services: [],
          edges: [("alpha", "beta"), ("beta", "alpha"), ("client", "alpha")]))
      #expect(layout.backEdges == ["edge:beta/alpha/http-api"])
      #expect(place(layout) == ["client 0/0", "alpha 1/0", "beta 2/0"])

      let ring = AppMapLayout(
        map: Self.map(apps: ["one", "two"], services: [], edges: [("one", "two"), ("two", "one")]))
      #expect(ring.backEdges == ["edge:two/one/http-api"])
      #expect(place(ring) == ["one 0/0", "two 1/0"])
    }

    @Test func arrowsFollowConnectionsAndStayInColumns() {
      let map = Self.map(
        apps: ["api", "mobile", "web"], services: ["push"],
        edges: [("mobile", "api"), ("web", "api"), ("mobile", "service:push")])
      let layout = AppMapLayout(map: map)
      let edges = map.connections
      #expect(layout.neighbour(of: nil, .right, connections: edges) == "app:mobile")
      #expect(layout.neighbour(of: "app:mobile", .right, connections: edges) == "app:api")
      #expect(layout.neighbour(of: "app:mobile", .down, connections: edges) == "app:web")
      #expect(layout.neighbour(of: "app:mobile", .up, connections: edges) == nil)
      #expect(layout.neighbour(of: "app:api", .left, connections: edges) == "app:mobile")
      #expect(layout.neighbour(of: "service:push", .left, connections: edges) == "app:mobile")
      #expect(layout.neighbour(of: "service:push", .right, connections: edges) == nil)
    }

    @Test func emptyAndUncalledNodesStillPlace() {
      #expect(AppMapLayout(map: Self.map(apps: [], services: [], edges: [])).columnCount == 0)
      let layout = AppMapLayout(map: Self.map(apps: ["web", "api"], services: ["mail"], edges: []))
      #expect(place(layout) == ["api 0/0", "web 0/1", "service:mail 1/0"])
    }

    private func place(_ layout: AppMapLayout) -> [String] {
      layout.nodes.map { "\($0.key) \($0.column)/\($0.row)" }
    }

    private static func map(apps: [String], services: [String], edges: [(String, String)])
      -> AppWorkspaceMap
    {
      AppWorkspaceMap(
        apps: apps.sorted().map {
          AppMapApp(
            slug: $0, name: $0, repo: $0, ref: "origin/main", productionRef: nil, subpath: nil,
            summary: nil, lifecycle: "active", attachment: "app:" + $0)
        },
        services: services.sorted().map {
          AppMapService(slug: $0, name: $0, summary: nil, attachment: "service:" + $0)
        },
        connections: edges.map {
          AppConnection(
            attachment: "edge:\($0.0)/\($0.1)/http-api", source: $0.0, target: $0.1,
            kind: "http-api", summary: "", codeReferences: [])
        })
    }
  }
#endif
