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
      }
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
