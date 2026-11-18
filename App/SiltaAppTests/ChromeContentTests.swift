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
      try await fixture { reader in
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

    private func fixture(_ body: @MainActor (AppReader) throws -> Void) throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      try body(AppReader(home: home, user: "acme", now: { AppV2Fixture.now }))
    }

    private func fixture(_ body: @MainActor (AppReader) async throws -> Void) async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      try await body(AppReader(home: home, user: "acme", now: { AppV2Fixture.now }))
    }
  }
#endif
