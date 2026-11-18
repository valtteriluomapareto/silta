#if DEBUG
  import Foundation
  @testable import SiltaApp
  @testable import SiltaAppSupport
  import Testing

  @MainActor struct WorkspaceMapTests {
    @Test func geometryCentresColumnsAndRoutesSkipEdgesAroundNodes() throws {
      try fixture { reader in
        let map = try reader.workspaceMap(workspace: "acme")
        let layout = AppMapLayout(map: map)
        let geometry = WorkspaceMapGeometry(layout: layout)
        let backend = try #require(geometry.frames["acme-backend"])
        let mobile = try #require(geometry.frames["acme-mobile"])
        let web = try #require(geometry.frames["acme-web"])
        #expect(backend.midY == (mobile.midY + web.midY) / 2)
        #expect(geometry.size.width == 32 * 2 + 3 * 176 + 2 * 136)
        let skip = geometry.route(from: "acme-mobile", to: "service:push", back: false)
        #expect(skip.count == 3)
        let run = skip[1]
        #expect(!(backend.minY < run.start.y && run.start.y < backend.maxY))
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

        let searched = WorkspaceMapContent(
          map: map, layout: layout, node: nil, connection: nil, search: "web shop")
        #expect(!searched.isFaded("app:acme-web") && searched.isFaded("app:acme-mobile"))

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
#endif
