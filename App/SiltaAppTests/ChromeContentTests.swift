#if DEBUG
  import Foundation
  @testable import SiltaApp
  @testable import SiltaAppSupport
  import Testing

  @MainActor struct ChromeContentTests {
    @Test func proposedMenuTracksAppAndVisibility() throws {
      try fixture { reader in
        let board = try reader.snapshot(workspace: "acme").board
        let apps = try reader.workspaceMap(workspace: "acme").apps
        let all = BoardMenuContent(app: nil, apps: apps, proposals: board.proposals, showing: false)
        #expect(all.title == "All apps" && all.proposedCount == 3)
        let mobile = BoardMenuContent(
          app: "acme-mobile", apps: apps, proposals: board.proposals, showing: true)
        #expect(mobile.title == "acme-mobile · proposed" && mobile.proposedCount == 1)
      }
    }

    @Test func sidebarUsesRecordedActorsStepsColorsAndQualifiedDocCount() throws {
      try fixture { reader in
        let task = try reader.task("AC-12", workspace: "acme")
        #expect(SidebarContent.claimTitle(task) == "AC-12 · step 2 of 4")
        #expect(
          SidebarContent.claimSubtitle(task, now: AppV2Fixture.now) == "Claude · updated 6 min ago")
        #expect(SidebarContent.appColor(index: 0) == "SecondaryInk")
        #expect(SidebarContent.appColor(index: 1) == "TideText")
        #expect(SidebarContent.appColor(index: 2) == "Warning")
        let docs = try reader.documents(workspace: "acme", archived: true)
        #expect(SidebarContent.documentCount(docs) == "6")
        #expect(SidebarContent.documentCount(docs, stale: true) == "6 (stale)")
        #expect(SidebarContent.documentCount(nil, stale: true) == "Unavailable")
        let partial = AppDocumentList(entries: docs.entries, total: 30, nextOffset: 20)
        #expect(SidebarContent.documentCount(partial) == "6+")
        #expect(SidebarContent.documentCount(nil) == "…")
      }
    }

    @Test func refreshFooterDistinguishesLoadingFreshStaleAndFailure() {
      let now = AppV2Fixture.now
      #expect(
        SidebarContent.refreshText(loading: true, failure: false, checkedAt: now, now: now)
          == "Updating…")
      #expect(
        SidebarContent.refreshText(loading: false, failure: false, checkedAt: now, now: now)
          == "Updated just now")
      #expect(
        SidebarContent.refreshText(
          loading: false, failure: false, checkedAt: now.addingTimeInterval(-720), now: now)
          == "Updated 12 min ago")
      #expect(
        SidebarContent.refreshText(loading: false, failure: true, checkedAt: now, now: now)
          == "Couldn't read the Silta data")
    }

    @Test func archiveFooterAndAboutChipUseTheLoadedScope() async throws {
      try await fixture { reader, _ in
        let docs = DocsModel()
        await docs.refresh(reader, workspace: "acme", about: nil, archived: false)
        #expect(docs.archivedCount == 1)
        #expect(docs.archivedFooter == "1 archived")
        #expect(docs.proposedLabel == "Proposed · 2")
        #expect(docs.groups(search: "").allSatisfy { $0.preferred?.archived == false })
        await docs.refresh(reader, workspace: "acme", about: nil, archived: true)
        #expect(docs.groups(search: "").contains { $0.preferred?.archived == true })
        #expect(
          DocsChromeContent.aboutLabel("edge:acme-mobile/acme-backend/http-api")
            == "About acme-mobile → acme-backend")
        let model = AppModel(load: { _, _, _ in nil })
        model.select(connection: "edge:acme-mobile/acme-backend/http-api")
        model.openDocument(
          "doc:order-contract@2", view: .document, about: model.workspaceSelection?.connectionRef)
        #expect(model.docsAbout == "edge:acme-mobile/acme-backend/http-api")
        model.docsAbout = nil
        #expect(model.documentSelection?.ref == "doc:order-contract@2")
        #expect(model.workspaceInspectorPresented)
      }
    }

    @Test func appDocumentsOpenTheAppScopeWithoutChangingConnectionSelection() async throws {
      try await fixture { reader, _ in
        let model = AppModel(
          reader: reader,
          load: { _, _, _ in
            AppLoadedData(
              workspaces: [], workspace: "acme", snapshot: nil, map: nil,
              version: 1, checkedAt: AppV2Fixture.now)
          })
        await model.refresh().value
        let edge = "edge:acme-mobile/acme-backend/http-api"
        model.select(connection: edge)
        model.openDocument("doc:order-contract@2", about: edge)
        let backend = try #require(
          reader.workspaceMap(workspace: "acme").apps.first { $0.slug == "acme-backend" })
        model.openDocuments(about: backend.attachment)
        #expect(model.route == .docs && model.docsAbout == "app:acme-backend")
        #expect(model.documentSelection == nil)
        await model.loadDocuments()
        let groups = model.documents.groups(search: "")
        #expect(groups.contains { $0.id == "operations" })
        #expect(model.documents.document?.about?.contains("app:acme-backend") == true)
        #expect(model.workspaceSelection?.connectionRef == edge)
        #expect(model.workspaceInspectorPresented)
      }
    }

    @Test func proposedReaderBannerNamesAcceptedRevisionWithoutRepeatingAttribution() throws {
      try fixture { reader in
        let revisions = try reader.documentVersions("order-contract", workspace: "acme")
        let proposed = try #require(revisions.entries.first { $0.state == "proposed" })
        let banner = try #require(
          DocsChromeContent.banner(
            document: proposed, revisions: revisions.entries, partial: false, now: AppV2Fixture.now)
        )
        #expect(banner.text == "Not accepted yet · accepted is @2")
        #expect(banner.accepted?.ref == "doc:order-contract@2")
        #expect(!banner.text.contains("Codex"))
        #expect(DocsContent.attribution(proposed, now: AppV2Fixture.now).contains("Codex"))
        let pending = try #require(
          reader.document("doc:push-categories@1", workspace: "acme").document)
        let alone = DocsChromeContent.banner(
          document: pending, revisions: [pending], partial: false, now: AppV2Fixture.now)
        #expect(alone?.text == "Not accepted yet · no accepted revision")
        #expect(alone?.accepted == nil)
      }
    }

    @Test func documentCatalogCachesByVersionAndForceWithoutOwningTheDocsFilter() async throws {
      try await fixture { reader, home in
        let version = CatalogVersion()
        let model = AppModel(
          reader: reader,
          load: { _, workspace, _ in
            AppLoadedData(
              workspaces: [], workspace: workspace ?? "acme", snapshot: nil, map: nil,
              version: await version.value, checkedAt: AppV2Fixture.now)
          })
        await model.refresh().value
        #expect(SidebarContent.documentCount(model.documentCatalog) == "6")
        model.openDocuments(about: "edge:acme-mobile/acme-backend/http-api")
        await model.loadDocuments()
        #expect(model.documents.groups(search: "").count == 3)
        #expect(SidebarContent.documentCount(model.documentCatalog) == "6")
        await model.selectWorkspace("missing").value
        #expect(model.failure == nil && model.catalogFailure != nil && model.documentCatalog == nil)
        await model.selectWorkspace("acme").value
        #expect(
          model.catalogFailure == nil && SidebarContent.documentCount(model.documentCatalog) == "6")
        model.navigate(to: .mywork)
        try AppTestCLI.run(
          [
            "--ws", "acme", "task", "add", "Catalog read fixture", "--start",
          ], home: home, seed: 35100)
        let task = try #require(
          reader.snapshot(workspace: "acme").board.doing.first {
            $0.title == "Catalog read fixture"
          })
        try proposeCatalog("catalog-cache", task: task.ref, home: home, seed: 35200)
        await model.refresh().value
        #expect(SidebarContent.documentCount(model.documentCatalog) == "6")
        await model.refresh(force: true).value
        #expect(SidebarContent.documentCount(model.documentCatalog) == "7")
        try proposeCatalog("catalog-version", task: task.ref, home: home, seed: 35300)
        version.value = 2
        await model.refresh().value
        #expect(
          model.catalogFailure == nil && SidebarContent.documentCount(model.documentCatalog) == "8")
      }
    }

    private func proposeCatalog(_ slug: String, task: String, home: URL, seed: Int) throws {
      let body = home.deletingLastPathComponent().appending(path: "catalog.md")
      try "# Catalog\n\nSynthetic catalog contents.\n".write(
        to: body, atomically: true, encoding: .utf8)
      try AppTestCLI.run(
        [
          "--ws", "acme", "doc", "propose", slug, "--title", slug,
          "--about", "app:acme-mobile", "--task", task, "-F", body.path, "-m",
          "Test catalog refresh",
        ],
        home: home, seed: seed)
    }

    @MainActor private final class CatalogVersion { var value = 1 }

    private func fixture(_ body: @MainActor (AppReader) throws -> Void) throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      try body(AppReader(home: home, user: "acme", now: { AppV2Fixture.now }))
    }

    private func fixture(_ body: @MainActor (AppReader, URL) async throws -> Void) async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      try await body(AppReader(home: home, user: "acme", now: { AppV2Fixture.now }), home)
    }
  }
#endif
