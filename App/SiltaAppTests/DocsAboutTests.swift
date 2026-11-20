#if DEBUG
  import Foundation
  @testable import SiltaApp
  @testable import SiltaAppSupport
  import Testing

  @MainActor struct DocsAboutTests {
    private func doc(
      _ slug: String, title: String? = nil, kind: String? = "reference", about: [String]? = [],
      revision: Int = 1, state: String = "accepted", archived: Bool = false
    ) -> AppDocument {
      AppDocument(
        ref: "doc:\(slug)@\(revision)", slug: slug, revision: revision, title: title, kind: kind,
        about: about, state: state, archived: archived)
    }

    @Test func aboutMenuListsLiveAppsServicesAndRememberedTopics() async throws {
      let map = AppWorkspaceMap(
        apps: [
          AppMapApp(
            slug: "web", name: "Acme web", repo: "web", ref: "origin/main", productionRef: nil,
            subpath: nil, summary: nil, lifecycle: "active", attachment: "app:web")
        ],
        services: [
          AppMapService(slug: "aws.s3", name: "S3", summary: nil, attachment: "service:aws%2Es3")
        ], connections: [])
      var reads: [String?] = []
      let docs = DocsModel(readList: { _, workspace, about, _, _ in
        reads.append(about)
        let all = [
          self.doc("env", about: ["app:web", "topic:environments"]),
          self.doc("login", about: ["topic:login"]),
        ]
        let found = workspace == "beta" ? [] : all
        let shown = about.map { ref in found.filter { $0.about?.contains(ref) == true } } ?? found
        return AppDocumentList(entries: shown, total: shown.count, nextOffset: nil)
      })
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      await docs.refresh(reader, workspace: "acme", about: nil, archived: false)
      await docs.refresh(reader, workspace: "acme", about: "app:web", archived: false)
      #expect(reads == [nil, "app:web"] && docs.entries.map(\.slug) == ["env"])
      let sections = DocsContent.aboutOptions(map: map, topics: docs.topics)
      #expect(sections.map(\.title) == ["Apps", "Services", "Topics"])
      #expect(
        sections.map { $0.options.map(\.ref) }
          == [["app:web"], ["service:aws%2Es3"], ["topic:environments", "topic:login"]])
      #expect(sections[2].options.map(\.name) == ["#environments", "#login"])
      #expect(DocsContent.aboutLabel("app:web", map: map) == "Acme web")
      #expect(DocsContent.aboutLabel("service:aws%2Es3", map: map) == "S3")
      #expect(DocsContent.aboutLabel("topic:login", map: map) == "#login")
      #expect(
        DocsContent.aboutLabel("edge:web/service:aws%2Es3/sdk", map: map) == "web → aws.s3 · sdk")
      await docs.refresh(reader, workspace: "beta", about: nil, archived: false)
      #expect(docs.topics.isEmpty)
      await docs.refresh(reader, workspace: "acme", about: nil, archived: false)
      #expect(!docs.topics.isEmpty)
      docs.clear()
      #expect(docs.topics.isEmpty && DocsContent.aboutOptions(map: nil, topics: []).isEmpty)
    }

    @Test func loadingSelectsTheFirstDocumentInListOrderAndChipsKeepIt() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let entries = [
        doc("a-notes", title: "A notes", about: ["app:web"]),
        doc("z-contract", title: "Z contract", kind: "contract", about: ["app:web"]),
      ]
      let docs = DocsModel(readList: { _, _, _, _, _ in
        AppDocumentList(entries: entries, total: entries.count, nextOffset: nil)
      })
      let model = AppModel(
        reader: reader, documents: docs,
        load: { _, _, _ in
          AppLoadedData(
            workspaces: [], workspace: "acme", snapshot: nil, map: nil,
            version: 1, checkedAt: AppV2Fixture.now)
        })
      await model.refresh().value
      model.openDocuments(about: "app:web")
      await model.loadDocuments()
      #expect(docs.ref == "doc:z-contract@1")
      model.select(document: "doc:a-notes@1")
      model.select(documentView: .comments)
      model.filterDocuments(about: "topic:other")
      #expect(model.docsAbout == "topic:other")
      #expect(docs.ref == "doc:a-notes@1" && docs.view == .comments)
      await model.loadDocuments()
      #expect(docs.ref == "doc:a-notes@1" && docs.view == .comments)
    }

    @Test func anUnfilteredReloadDropsTopicsThatAreGone() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      var entries = [
        doc("env", about: ["topic:environments"]), doc("login", about: ["topic:login"]),
      ]
      let docs = DocsModel(readList: { _, _, about, _, _ in
        let shown =
          about.map { ref in entries.filter { $0.about?.contains(ref) == true } } ?? entries
        return AppDocumentList(entries: shown, total: shown.count, nextOffset: nil)
      })
      await docs.refresh(reader, workspace: "acme", about: nil, archived: false)
      await docs.refresh(reader, workspace: "acme", about: "topic:login", archived: false)
      #expect(docs.topics == ["topic:environments", "topic:login"])
      entries.removeLast()
      await docs.refresh(reader, workspace: "acme", about: nil, archived: false, force: true)
      #expect(docs.topics == ["topic:environments"])
    }
  }
#endif
