#if DEBUG
  import Foundation
  import SwiftUI
  @testable import SiltaApp
  @testable import SiltaAppSupport
  import Testing

  @MainActor struct WorkspaceMapTests {
    @Test func geometryCentresColumnsAndDropsServiceLinesIntoTheRowBelow() throws {
      try fixture { reader in
        let map = try reader.workspaceMap(workspace: "acme")
        let layout = AppMapLayout(map: map)
        let geometry = WorkspaceMapGeometry(layout: layout)
        let backend = try #require(geometry.frames["acme-backend"])
        let mobile = try #require(geometry.frames["acme-mobile"])
        let web = try #require(geometry.frames["acme-web"])
        let push = try #require(geometry.frames["service:push"])
        let payments = try #require(geometry.frames["service:payments"])
        #expect(backend.midY == (mobile.midY + web.midY) / 2)
        #expect(abs(geometry.size.width - (32 * 2 + 2 * 176 + 136)) < 0.5)
        #expect(push.minY == payments.minY && push.maxX < payments.minX)
        #expect(push.minY > max(mobile.maxY, web.maxY, backend.maxY))
        #expect(payments.maxY < geometry.size.height)
        let label = try #require(geometry.shelfLabel)
        #expect(label.y > push.maxY && label.x <= push.minX)
        let drop = geometry.route(from: "acme-backend", to: "service:payments", back: false)
        #expect(drop.count == 2)
        #expect(drop[0].start == CGPoint(x: backend.midX, y: backend.maxY))
        #expect(drop[1].end == CGPoint(x: payments.midX, y: payments.minY))
        let around = geometry.route(from: "acme-mobile", to: "service:push", back: false)
        #expect(around.count == 3 && around[0].start.x == mobile.maxX)
        #expect(around.last?.end == CGPoint(x: push.midX, y: push.minY))
        let content = WorkspaceMapContent(
          map: map, layout: layout, node: nil, connection: nil, search: "")
        Self.expectServiceLinesClear(content, geometry)
        #expect(geometry.route(from: "acme-mobile", to: "acme-backend", back: false).count == 1)
        #expect(WorkspaceMapGeometry.fitScale(content: geometry.size, in: geometry.size) == 1)
        #expect(
          WorkspaceMapGeometry.fitScale(
            content: CGSize(width: 1000, height: 400), in: CGSize(width: 800, height: 800)) == 0.8)
        #expect(
          WorkspaceMapGeometry.fitScale(
            content: CGSize(width: 4000, height: 400), in: CGSize(width: 800, height: 800)) == 0.6)
      }
    }

    @Test func backEdgesRunBelowEveryNodeAndParallelEdgesGetTheirOwnLabels() throws {
      let map = Self.map(
        apps: ["r", "t", "x", "y", "z"],
        edges: [
          Link("r", "x", kind: "http-api"), Link("r", "y", kind: "http-api"),
          Link("r", "z", kind: "http-api"),
          Link("x", "t", kind: "http-api"), Link("t", "r", kind: "http-api"),
          Link("t", "r", kind: "graphql"),
          Link("x", "x", kind: "http-api"), Link("r", "t", kind: "sdk"),
          Link("r", "t", kind: "grpc"),
        ])
      let layout = AppMapLayout(map: map)
      let geometry = WorkspaceMapGeometry(layout: layout)
      let content = WorkspaceMapContent(
        map: map, layout: layout, node: nil, connection: nil, search: "")
      for edge in content.edges where edge.back && edge.connection.source != edge.connection.target
      {
        let curves = geometry.route(
          from: edge.connection.source, to: edge.connection.target, back: true, lane: edge.lane)
        for curve in curves {
          for step in 1..<20 {
            let point = Self.point(curve, at: CGFloat(step) / 20)
            let hits = geometry.frames.filter { key, frame in
              key != edge.connection.source && key != edge.connection.target
                && frame.insetBy(dx: 1, dy: 1).contains(point)
            }
            #expect(hits.isEmpty, "\(edge.connection.attachment) crosses \(hits.keys)")
          }
        }
        let depth = curves.map(\.start.y).max() ?? 0
        #expect(depth <= geometry.size.height)
        let forward = geometry.route(
          from: edge.connection.target, to: edge.connection.source, back: false)
        if let stub = curves.first, let line = forward.last {
          #expect(
            stub.start.y != line.end.y, "\(edge.connection.attachment) sits on a forward edge")
        }
      }
      let selfLoop = geometry.route(from: "x", to: "x", back: true)
      #expect(selfLoop.count == 1 && selfLoop[0].start.y < selfLoop[0].end.y)
      let node = try #require(geometry.frames["x"])
      #expect(selfLoop[0].midpoint.x > node.maxX && selfLoop[0].midpoint.x < node.maxX + 68)
      let points = content.edges.compactMap {
        geometry.route(
          from: $0.connection.source, to: $0.connection.target, back: $0.back, lane: $0.lane
        ).labelPoint()
      }
      #expect(Set(points.map { "\($0.x),\($0.y)" }).count == points.count)
    }

    @Test func fitScaleStaysBetweenSixtyAndOneHundredPercent() {
      #expect(
        WorkspaceMapGeometry.fitScale(
          content: CGSize(width: 400, height: 300), in: CGSize(width: 800, height: 600)) == 1)
      #expect(
        WorkspaceMapGeometry.fitScale(
          content: CGSize(width: 400, height: 1000), in: CGSize(width: 800, height: 700)) == 0.7)
      #expect(
        WorkspaceMapGeometry.fitScale(content: .zero, in: CGSize(width: 800, height: 600)) == 1)
    }

    @Test func selectionStrengthensItsEdgesAndFadesTheRest() throws {
      try fixture { reader in
        let map = try reader.workspaceMap(workspace: "acme")
        let layout = AppMapLayout(map: map)
        let selected = WorkspaceMapContent(
          map: map, layout: layout, node: "app:acme-mobile", connection: nil, search: "")
        let style = Dictionary(
          uniqueKeysWithValues: selected.edges.map {
            ($0.connection.attachment, selected.style($0))
          })
        #expect(style["edge:acme-mobile/acme-backend/http-api"] == .strong)
        #expect(style["edge:acme-mobile/service:push/sdk"] == .strong)
        #expect(style["edge:acme-web/acme-backend/graphql"] == .faded)
        #expect(selected.isFaded("app:acme-web") && !selected.isFaded("app:acme-backend"))
        let push = try #require(selected.edges.first { $0.connection.target == "service:push" })
        #expect(selected.showsLabel(push))

        let idle = WorkspaceMapContent(
          map: map, layout: layout, node: nil, connection: nil, search: "")
        let quiet = try #require(idle.edges.first { $0.connection.target == "service:push" })
        let app = try #require(idle.edges.first { $0.connection.target == "acme-backend" })
        #expect(idle.style(quiet) == .quiet && !idle.showsLabel(quiet))
        #expect(idle.style(app) == .normal && idle.showsLabel(app))
        #expect(idle.callers(of: "service:push") == 1)
        let picked = WorkspaceMapContent(
          map: map, layout: layout, node: nil, connection: quiet.connection.attachment, search: "")
        #expect(picked.style(quiet) == .strong && picked.showsLabel(quiet))
        let service = WorkspaceMapContent(
          map: map, layout: layout, node: "service:push", connection: nil, search: "")
        #expect(service.style(quiet) == .strong && service.style(app) == .faded)

        let searched = WorkspaceMapContent(
          map: map, layout: layout, node: nil, connection: nil, search: "web shop")
        #expect(!searched.isFaded("app:acme-web") && searched.isFaded("app:acme-mobile"))
        #expect(searched.style(quiet) == .faded)

        let mobile = try #require(layout.node("acme-mobile"))
        #expect(
          selected.description(mobile)
            == "acme-mobile, app, calls acme-backend over http-api, calls service:push over sdk")
        let edge = try #require(selected.edges.first { $0.connection.source == "acme-web" })
        #expect(
          selected.description(edge, docs: "0")
            == "acme-web calls acme-backend over graphql, 0 docs")
        #expect(WorkspaceMapContent.labelText(kind: "http-api", docs: "3") == "http-api · 3 docs")
        #expect(WorkspaceMapContent.labelText(kind: "sdk", docs: "0") == "sdk")
        #expect(WorkspaceMapContent.labelText(kind: "sdk", docs: "1") == "sdk · 1 doc")
      }
    }

    @Test func nodeAndConnectionSelectionAreExclusiveAndArrowsMove() async throws {
      try await fixture { reader in
        let data = AppLoadedData(
          workspaces: try reader.workspaces(), workspace: "acme",
          snapshot: try reader.snapshot(workspace: "acme"),
          map: try reader.workspaceMap(workspace: "acme"), version: 1,
          checkedAt: AppV2Fixture.now)
        let model = AppModel(reader: reader, load: { _, _, _ in data })
        await model.refresh().value
        #expect(model.workspaceView == .map)
        model.select(connection: "edge:acme-mobile/acme-backend/http-api")
        model.moveMapSelection(.right)
        #expect(model.workspaceNode == "app:acme-backend" && model.workspaceSelection == nil)
        model.moveMapSelection(.left)
        #expect(model.workspaceNode == "app:acme-mobile")
        model.moveMapSelection(.down)
        #expect(model.workspaceNode == "app:acme-web")
        model.moveMapSelection(.down)
        #expect(model.workspaceNode == "app:acme-web")
        model.select(connection: "edge:acme-web/acme-backend/graphql")
        #expect(model.workspaceNode == nil && model.workspaceInspectorPresented)
        model.clearWorkspaceSelection()
        #expect(model.workspaceNode == nil && model.workspaceSelection == nil)
        model.moveMapSelection(.right)
        #expect(model.workspaceNode == "app:acme-mobile")
      }
    }

    fileprivate static func point(_ curve: WorkspaceMapGeometry.Curve, at t: CGFloat) -> CGPoint {
      let u = 1 - t
      let a = u * u * u
      let b = 3 * u * u * t
      let c = 3 * u * t * t
      let d = t * t * t
      return CGPoint(
        x: a * curve.start.x + b * curve.control1.x + c * curve.control2.x + d * curve.end.x,
        y: a * curve.start.y + b * curve.control1.y + c * curve.control2.y + d * curve.end.y)
    }

    struct Link {
      let from: String
      let to: String
      let kind: String

      init(_ from: String, _ to: String, kind: String) {
        self.from = from
        self.to = to
        self.kind = kind
      }
    }

    fileprivate static func map(apps: [String], edges: [Link]) -> AppWorkspaceMap {
      AppWorkspaceMap(
        apps: apps.map {
          AppMapApp(
            slug: $0, name: $0, repo: $0, ref: "origin/main", productionRef: nil, subpath: nil,
            summary: nil, lifecycle: "active", attachment: "app:" + $0)
        }, services: [],
        connections: edges.map {
          AppConnection(
            attachment: "edge:\($0.from)/\($0.to)/\($0.kind)", source: $0.from, target: $0.to,
            kind: $0.kind,
            summary: "", codeReferences: [])
        })
    }

    private func fixture(_ body: @MainActor (AppReader) async throws -> Void) async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      try await body(AppReader(home: home, user: "acme", now: { AppV2Fixture.now }))
    }

    private func fixture(_ body: @MainActor (AppReader) throws -> Void) throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      try body(AppReader(home: home, user: "acme", now: { AppV2Fixture.now }))
    }
  }

  extension WorkspaceMapTests {
    @Test func servicesStayInOneRowWithTheAppsCentredOverIt() throws {
      let services = (1...8).map { "s\($0)" }
      let map = AppWorkspaceMap(
        apps: Self.map(apps: ["api"], edges: []).apps,
        services: services.map {
          AppMapService(slug: $0, name: $0, summary: nil, attachment: "service:" + $0)
        },
        connections: ["s1", "s2", "s3"].map {
          AppConnection(
            attachment: "edge:api/service:\($0)/sdk", source: "api", target: "service:" + $0,
            kind: "sdk", summary: "", codeReferences: [])
        })
      let layout = AppMapLayout(map: map)
      let geometry = WorkspaceMapGeometry(layout: layout)
      let first = try #require(geometry.frames["service:s1"])
      let eighth = try #require(geometry.frames["service:s8"])
      let api = try #require(geometry.frames["api"])
      #expect(services.allSatisfy { geometry.frames["service:" + $0]?.minY == first.minY })
      #expect(abs(api.midX - (first.minX + eighth.maxX) / 2) < 0.5)
      #expect(
        geometry.size.width == eighth.maxX + 32 && geometry.size.height == eighth.maxY + 24 + 32)

      let content = WorkspaceMapContent(
        map: map, layout: layout, node: nil, connection: nil, search: "")
      let starts = content.edges.sorted { $0.lane < $1.lane }.map { edge in
        geometry.route(
          from: edge.connection.source, to: edge.connection.target, back: edge.back,
          lane: edge.lane, lanes: edge.lanes
        )[0].start.x
      }
      #expect(starts.count == 3 && starts == starts.sorted() && Set(starts).count == 3)
      #expect(abs(starts[1] - api.midX) < 0.5)
      #expect(content.edges.allSatisfy { $0.toService && $0.lanes == 3 })
    }

    @Test func stackedAppsBackEdgesAndManyServiceLinesKeepTheirOwnPaths() {
      let links: [(String, String)] = [
        ("a", "x"), ("a", "y"), ("x", "a"),
        ("a", "service:s1"), ("a", "service:s2"), ("a", "service:s3"), ("a", "service:s4"),
        ("a", "service:s5"), ("b", "service:s1"), ("b", "service:s2"), ("c", "service:s3"),
        ("x", "service:s4"), ("y", "service:s5"),
      ]
      let map = AppWorkspaceMap(
        apps: Self.map(apps: ["a", "b", "c", "x", "y"], edges: []).apps,
        services: (1...5).map {
          AppMapService(slug: "s\($0)", name: "s\($0)", summary: nil, attachment: "service:s\($0)")
        },
        connections: links.map {
          AppConnection(
            attachment: "edge:\($0.0)/\($0.1)/http-api", source: $0.0, target: $0.1,
            kind: "http-api", summary: "", codeReferences: [])
        })
      let layout = AppMapLayout(map: map)
      #expect(layout.backEdges == ["edge:x/a/http-api"])
      let geometry = WorkspaceMapGeometry(layout: layout)
      let content = WorkspaceMapContent(
        map: map, layout: layout, node: nil, connection: nil, search: "")
      Self.expectServiceLinesClear(content, geometry)

      var drops: [String: Set<CGFloat>] = [:]
      for edge in content.edges where edge.toService {
        let curves = geometry.route(
          from: edge.connection.source, to: edge.connection.target, back: false,
          lane: edge.lane, lanes: edge.lanes)
        if curves.count == 3 {
          drops[edge.connection.source, default: []].insert(curves[1].start.x)
        }
      }
      #expect(drops["a"]?.count == 5 && drops["b"]?.count == 2 && drops["x"]?.count == 1)
      #expect(drops["c"] == nil && drops["y"] == nil)
      #expect(drops["a"]?.isDisjoint(with: drops["b"] ?? []) == true)
      let x = geometry.frames["x"] ?? .zero
      #expect(drops["x"]?.allSatisfy { $0 < x.minX } == true)
    }

    @Test func servicesWithoutAppsStillPlace() throws {
      let map = AppWorkspaceMap(
        apps: [],
        services: ["a", "b"].map {
          AppMapService(slug: $0, name: $0, summary: nil, attachment: "service:" + $0)
        }, connections: [])
      let geometry = WorkspaceMapGeometry(layout: AppMapLayout(map: map))
      let a = try #require(geometry.frames["service:a"])
      #expect(a.minY == 32 && a.minX == 32 && geometry.shelfLabel != nil)
      #expect(geometry.size.height == a.maxY + 24 + 32)
    }

    /// Every line to a service stays inside the map, crosses no card but its own two
    /// ends, starts where no other edge meets its app, and gets a label point of its own.
    fileprivate static func expectServiceLinesClear(
      _ content: WorkspaceMapContent, _ geometry: WorkspaceMapGeometry
    ) {
      var others: Set<String> = []
      for edge in content.edges where !edge.toService {
        let curves = geometry.route(
          from: edge.connection.source, to: edge.connection.target, back: edge.back,
          lane: edge.lane, lanes: edge.lanes)
        for curve in curves { others.formUnion(["\(curve.start)", "\(curve.end)"]) }
      }
      var starts: Set<String> = []
      var labels: Set<String> = []
      var points: [(AppConnection, CGPoint)] = []
      for edge in content.edges where edge.toService {
        let curves = geometry.route(
          from: edge.connection.source, to: edge.connection.target, back: false,
          lane: edge.lane, lanes: edge.lanes)
        let start = "\(curves[0].start)"
        #expect(
          !others.contains(start) && starts.insert(start).inserted, "\(edge.connection.attachment)")
        if let label = curves.labelPoint(toService: true, lane: edge.lane, lanes: edge.lanes) {
          labels.insert("\(label)")
          points.append((edge.connection, label))
        }
        for curve in curves {
          for step in 0...20 {
            let point = Self.point(curve, at: CGFloat(step) / 20)
            #expect(
              point.x >= 0 && point.x <= geometry.size.width && point.y >= 0
                && point.y <= geometry.size.height)
            let hits = geometry.frames.filter { key, frame in
              key != edge.connection.source && key != edge.connection.target
                && frame.insetBy(dx: 1, dy: 1).contains(point)
            }
            #expect(hits.isEmpty, "\(edge.connection.attachment) crosses \(hits.keys)")
          }
        }
      }
      #expect(labels.count == content.edges.filter(\.toService).count)
      // Labels shown together, for one selected app or one selected service, keep apart.
      for (one, first) in points {
        for (other, second) in points where one.attachment < other.attachment {
          guard one.source == other.source || one.target == other.target else { continue }
          let apart = abs(first.x - second.x) >= 48 || abs(first.y - second.y) >= 18
          #expect(apart, "\(one.attachment) and \(other.attachment) labels overlap")
        }
      }
    }
  }
#endif
