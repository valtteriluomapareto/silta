#if DEBUG
  import Foundation
  @testable import SiltaApp
  @testable import SiltaAppSupport
  import Testing

  /// Where the app names an app, it shows its display name; the slug stays in actions.
  @MainActor struct AppDisplayNameTests {
    private let apps = [
      AppMapApp(
        slug: "acme-web", name: "Acme web shop", repo: "web", ref: "origin/main",
        productionRef: nil, subpath: nil, summary: nil, lifecycle: "active",
        attachment: "app:acme-web")
    ]

    @Test func aSlugResolvesToItsNameOrStaysWhenTheMapLacksIt() {
      #expect(apps.name(of: "acme-web") == "Acme web shop")
      #expect(apps.name(of: "acme-mobile") == "acme-mobile")
    }

    @Test func appMenusNameTheAppButActOnItsSlug() throws {
      let items = TaskMenu.items(forApp: "acme-web", in: apps)
      #expect(
        items.map(\.title) == ["Filter Board to Acme web shop", "Show Docs About Acme web shop"])
      #expect(items.map(\.action) == [.filterBoard("acme-web"), .showDocs("app:acme-web")])
      try fixture { reader, _ in
        let task = try reader.task("AC-15", workspace: "acme")
        let menu = TaskMenu.items(
          for: task,
          in: TaskMenu.Context(
            reader: reader, workspace: "acme", name: "Acme", apps: apps, existing: [],
            now: AppV2Fixture.now))
        #expect(menu.contains { $0.title == "Filter Board to Acme web shop" })
      }
    }

    @Test func taskProposalsShowAndMatchTheAppName() throws {
      try fixture { reader, _ in
        let snapshot = try reader.snapshot(workspace: "acme")
        let content = MyWorkContent(
          snapshot: snapshot, apps: apps, search: "", now: AppV2Fixture.now)
        let proposal = try #require(content.tasks.first { $0.ref == "AC-23" })
        #expect(proposal.metadata.hasPrefix("Acme web shop"))
        let found = MyWorkContent(
          snapshot: snapshot, apps: apps, search: "web shop", now: AppV2Fixture.now)
        #expect(found.tasks.map(\.ref) == ["AC-23"])
        let bySlug = MyWorkContent(
          snapshot: snapshot, apps: apps, search: "acme-web", now: AppV2Fixture.now)
        #expect(bySlug.tasks.map(\.ref) == ["AC-23"])
      }
    }

    @Test func connectionEndpointsUseTheMapsNames() throws {
      let map = AppWorkspaceMap(
        apps: apps,
        services: [
          AppMapService(
            slug: "push", name: "Push service", summary: nil, attachment: "service:push")
        ],
        connections: [
          AppConnection(
            attachment: "edge:acme-web/service:push/sdk", source: "acme-web",
            target: "service:push", kind: "sdk", summary: "", codeReferences: [])
        ])
      #expect(map.endpointName("acme-web") == "Acme web shop")
      #expect(map.endpointName("service:push") == "Push service")
      #expect(map.endpointName("service:mail") == "mail")
      #expect(map.endpointName("acme-pdf") == "acme-pdf")
      let layout = AppMapLayout(map: map)
      let content = WorkspaceMapContent(
        map: map, layout: layout, node: nil, connection: nil, search: "")
      let web = try #require(layout.nodes.first { $0.key == "acme-web" })
      #expect(content.description(web) == "Acme web shop, app, calls Push service over sdk")
      let edge = try #require(content.edges.first)
      #expect(
        content.description(edge, docs: "1") == "Acme web shop calls Push service over sdk, 1 doc")
      func subtitle(_ about: [String]) -> String {
        let document = AppDocument(
          ref: "doc:a@1", slug: "a", revision: 1, title: nil, kind: "reference", about: about,
          state: "accepted", archived: false)
        return DocsContent.subtitle(DocsModel.Group(id: "a", entries: [document]), map: map)
      }
      #expect(
        subtitle(["edge:acme-web/service:push/sdk"]).hasPrefix("Acme web shop → Push service"))
      #expect(subtitle(["app:acme-web"]).hasPrefix("Acme web shop · "))
    }

    private func fixture(_ body: (AppReader, URL) throws -> Void) throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      try body(reader, home)
    }
  }
#endif
