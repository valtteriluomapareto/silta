#if DEBUG
  import Foundation
  @testable import SiltaApp
  @testable import SiltaAppSupport
  import Testing

  @MainActor struct DocsModelTests {
    @Test func failedReloadKeepsTheCurrentDocumentAndBody() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let docs = DocsModel()
      docs.ref = "doc:operations@1"
      await docs.show(reader, workspace: "acme")
      let original = docs.document
      let body = docs.body
      #expect(original != nil && !body.isEmpty)
      let path = home.appending(path: "silta.db").path
      let files = FileManager.default
      let mode = try files.attributesOfItem(atPath: path)[.posixPermissions]
      defer {
        try? files.setAttributes(  // restore the owned fixture database
          [.posixPermissions: mode ?? 0o600], ofItemAtPath: path)
      }
      try files.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
      await docs.show(reader, workspace: "acme", force: true)
      #expect(docs.failure != nil && !docs.loading)
      #expect(docs.document == original && docs.body == body)
    }

    @Test func pendingOnlyArchivedAndLegacyDocumentsRemainReadable() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let docs = DocsModel()
      await docs.refresh(reader, workspace: "acme", about: nil, archived: true)
      let archived = try #require(docs.entries.first { $0.archived })
      docs.ref = "doc:push-categories@1"
      docs.view = .changes
      await docs.show(reader, workspace: "acme")
      #expect(docs.document?.state == "proposed" && !docs.text.isEmpty && docs.failure == nil)
      docs.ref = "doc:legacy-notes@1"
      docs.view = .document
      await docs.show(reader, workspace: "acme")
      #expect(docs.document?.title == nil && docs.document?.about == nil && !docs.body.isEmpty)
      docs.ref = archived.ref
      await docs.show(reader, workspace: "acme")
      #expect(docs.document?.archived == true && !docs.body.isEmpty && docs.failure == nil)
    }

    @Test func oldListCompletionCannotLoadThePreviousWorkspaceIntoTheCurrentReader() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let page = try reader.documents(workspace: "acme")
      let gate = PausedDocumentList()
      var firstAcme = true
      let docs = DocsModel(readList: { _, workspace, _, _, _ in
        if workspace == "acme", firstAcme {
          firstAcme = false
          await gate.pause()
        }
        return page
      })
      let model = AppModel(
        reader: reader, documents: docs,
        load: { _, workspace, _ in
          AppLoadedData(
            workspaces: [], workspace: workspace ?? "acme", snapshot: nil,
            map: nil, version: 1, checkedAt: AppV2Fixture.now)
        })
      await model.refresh().value
      model.navigate(to: .docs)
      let old = Task { await model.loadDocuments() }
      await gate.started()
      await model.selectWorkspace("beta").value
      let betaFailure = try #require(docs.failure)
      #expect(model.workspace == "beta" && docs.document == nil)
      gate.resume()
      await old.value
      #expect(docs.document == nil && docs.body.isEmpty && docs.failure == betaFailure)
    }

    @Test func historyPageRetryKeepsEntriesAndClearsThePreviousFailure() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let full = try reader.documentVersions("order-contract", workspace: "acme")
      let first = try #require(full.entries.first)
      var pages = 0
      let docs = DocsModel(readVersions: { _, _, _, offset in
        if offset == 0 { return AppDocumentList(entries: [first], total: 3, nextOffset: 1) }
        pages += 1
        if pages == 1 { throw AppLoadFailure(message: "Acme history page unavailable") }
        return AppDocumentList(entries: Array(full.entries.dropFirst()), total: 3, nextOffset: nil)
      })
      docs.ref = "doc:order-contract@2"
      await docs.show(reader, workspace: "acme")
      await docs.moreVersions(reader, workspace: "acme")
      #expect(docs.versions == [first] && docs.failure != nil && docs.nextVersions == 1)
      await docs.moreVersions(reader, workspace: "acme")
      #expect(docs.versions == full.entries && docs.nextVersions == nil)
      #expect(docs.failure == nil)
    }

    @Test func failuresBelongToTheirReadVersion() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let docs = DocsModel()
      await docs.refresh(reader, workspace: "acme", about: nil, archived: false, version: 1)
      docs.ref = "doc:missing@1"
      await docs.show(reader, workspace: "acme", version: 1)
      #expect(docs.phase(workspace: "acme", about: nil, archived: false, version: 1) == .failed)
      #expect(docs.phase(workspace: "acme", about: nil, archived: false, version: 2) == .loading)
      await docs.refresh(reader, workspace: "acme", about: nil, archived: false, version: 2)
      #expect(docs.failure != nil)
      #expect(docs.phase(workspace: "acme", about: nil, archived: false, version: 2) == .loading)
      await docs.show(reader, workspace: "acme", version: 2)
      #expect(docs.phase(workspace: "acme", about: nil, archived: false, version: 2) == .failed)
      await docs.refresh(reader, workspace: "missing", about: nil, archived: false, version: 1)
      #expect(docs.phase(workspace: "missing", about: nil, archived: false, version: 1) == .failed)
      #expect(
        docs.phase(workspace: "missing", about: nil, archived: false, version: 2) == .loading)
    }

    @Test func phaseTracksCurrentScopeVersionAndSelectedView() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let docs = DocsModel()
      func phase(_ workspace: String? = "acme", about: String? = nil, version: Int? = 1)
        -> DocsModel.Phase
      {
        docs.phase(workspace: workspace, about: about, archived: false, version: version)
      }
      #expect(phase(nil) == .starting)
      #expect(phase() == .loading)
      await docs.refresh(reader, workspace: "acme", about: nil, archived: false, version: 1)
      docs.ref = "doc:order-contract@2"
      #expect(phase() == .loading)
      await docs.show(reader, workspace: "acme", version: 1)
      #expect(phase() == .ready)
      docs.view = .comments
      #expect(phase() == .loading)
      await docs.show(reader, workspace: "acme", version: 1)
      #expect(phase() == .ready)
      #expect(phase(about: "app:acme-mobile") == .loading)
      #expect(phase(version: 2) == .loading)
      docs.ref = "doc:missing@1"
      await docs.show(reader, workspace: "acme", version: 1)
      #expect(phase() == .failed)
    }

    @Test func proposedFilterKeepsPendingOnlyAndUsesThePendingRevision() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let docs = DocsModel()
      await docs.refresh(reader, workspace: "acme", about: nil, archived: false)
      docs.proposedOnly = true
      #expect(docs.groups(search: "").flatMap(\.entries).allSatisfy { $0.state == "proposed" })
      #expect(docs.groups(search: "order").first?.preferred?.ref == "doc:order-contract@3")
      #expect(docs.groups(search: "push").first?.preferred?.ref == "doc:push-categories@1")
      docs.proposedOnly = false
      #expect(docs.groups(search: "order").first?.preferred?.ref == "doc:order-contract@2")
    }

    @Test func groupsPreferAcceptedAndReaderAppendsAllBodyPages() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let docs = DocsModel()
      await docs.refresh(reader, workspace: "acme", about: nil, archived: false)
      let order = try #require(docs.groups(search: "order").first)
      #expect(order.preferred?.ref == "doc:order-contract@2")
      #expect(docs.groups(search: "push").first?.preferred?.state == "proposed")
      docs.ref = "doc:operations@1"
      await docs.show(reader, workspace: "acme")
      #expect(docs.nextLine != nil)
      await docs.show(reader, workspace: "acme", append: true)
      #expect(docs.body.contains("Operational step 500.") && docs.nextLine == nil)
      await docs.show(reader, workspace: "acme", version: 2)
      #expect(docs.body.contains("Operational step 500.") && docs.nextLine == nil)
      docs.ref = "doc:order-contract@2"
      docs.view = .comments
      await docs.show(reader, workspace: "acme")
      #expect(docs.comments.count == 1 && docs.versions.count == 3 && docs.failure == nil)
      await docs.refresh(reader, workspace: "acme", about: "service:missing", archived: false)
      #expect(docs.entries.isEmpty && docs.listFailure != nil)
    }
  }

  @MainActor private final class PausedDocumentList {
    private var hasStarted = false
    private var ready: CheckedContinuation<Void, Never>?
    private var paused: CheckedContinuation<Void, Never>?

    func pause() async {
      await withCheckedContinuation { continuation in
        paused = continuation
        hasStarted = true
        ready?.resume()
        ready = nil
      }
    }
    func started() async {
      if hasStarted { return }
      await withCheckedContinuation { ready = $0 }
    }
    func resume() {
      paused?.resume()
      paused = nil
    }
  }
#endif
