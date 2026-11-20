#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SwiftUI
  import Synchronization
  @testable import SiltaAppSupport
  import Testing

  @MainActor struct DocsPresentationTests {
    @Test func fixtureDocumentsListOnceWithProposalsAndLegacyRows() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let docs = DocsModel()
      await docs.refresh(reader, workspace: "acme", about: nil, archived: true)
      let sections = DocsContent.sections(docs.groups(search: ""))
      let ids = sections.flatMap { $0.groups.map(\.id) }
      #expect(ids.count == Set(ids).count)
      #expect(ids.contains("legacy-notes") && ids.contains("push-categories"))
      #expect(sections.last?.title == "Kind not recorded · 1")
      docs.ref = "doc:order-contract@2"
      await docs.show(reader, workspace: "acme")
      let proposal = try #require(DocsContent.proposal(in: docs.versions))
      let banner = DocsContent.attribution(proposal, now: AppV2Fixture.now)
      #expect(banner.contains("Codex") && banner.contains("AC-9") && banner.contains("@3"))
      #expect(DocsContent.row(docs.groups(search: "order")[0]).contains("@3 proposed"))
    }

    private func doc(
      _ slug: String, title: String? = nil, kind: String? = "reference", about: [String]? = [],
      revision: Int = 1, state: String = "accepted", archived: Bool = false
    ) -> AppDocument {
      AppDocument(
        ref: "doc:\(slug)@\(revision)", slug: slug, revision: revision, title: title, kind: kind,
        about: about, state: state, archived: archived)
    }

    @Test func eachDocumentAppearsOnceUnderItsKind() {
      let entries = [
        doc(
          "environments", title: "Release pipelines",
          about: [
            "app:acme-web", "app:acme-pdf", "topic:environments", "edge:acme-web/acme-pdf/http-api",
          ]),
        doc("pdf-contract", title: "Portal and PDF", kind: "contract"),
        doc("b-flow", title: "Checkout", kind: "flow"),
        doc("a-flow", title: "Checkout", kind: "flow"),
        doc("aaa", title: nil, kind: "flow"),
        doc("keys", title: "Rotating keys", kind: "runbook"),
        doc("odd", title: "Odd", kind: "memo"),
        doc("capital", title: "Capital", kind: "Contract"),
        doc("legacy", kind: nil, about: nil),
        doc("untitled", title: nil, kind: "flow"),
      ]
      let sections = DocsContent.sections(DocsContent.groups(entries))
      #expect(
        sections.map(\.title) == [
          "Contracts · 1", "Flows · 4", "References · 1", "Runbooks · 1", "Other kinds · 2",
          "Kind not recorded · 1",
        ])
      let ids = sections.flatMap { $0.groups.map(\.id) }
      #expect(ids.count == Set(ids).count && ids.count == entries.count)
      #expect(sections[1].groups.map(\.id) == ["aaa", "a-flow", "b-flow", "untitled"])
      #expect(sections[4].groups.map(\.id) == ["capital", "odd"])
    }

    @Test func subtitlesSummariseWhatADocumentIsAbout() {
      func subtitle(_ entries: [AppDocument]) -> String {
        DocsContent.subtitle(DocsModel.Group(id: entries[0].slug, entries: entries))
      }
      #expect(
        subtitle([doc("a", about: ["edge:acme-portal/acme-pdf/http-api"])])
          == "acme-portal → acme-pdf · @1")
      #expect(
        subtitle([doc("a", about: ["edge:acme-portal/service:mail/http-api"])])
          == "acme-portal → mail · @1")
      #expect(
        subtitle([doc("a", about: ["edge:acme%2Fweb/acme-pdf/http-api"])])
          == "acme/web → acme-pdf · @1")
      #expect(subtitle([doc("a", about: ["app:acme-crm"])]) == "acme-crm · @1")
      #expect(subtitle([doc("a", about: ["topic:login"])]) == "#login · @1")
      let wide = [
        "app:acme-web", "app:acme-pdf", "edge:acme-web/acme-auth/http-api",
        "edge:acme-web/service:mail/http-api", "topic:environments",
      ]
      #expect(subtitle([doc("a", about: wide)]) == "3 apps · #environments · @1")
      #expect(
        subtitle([doc("a", about: ["app:acme-crm", "service:erp"])]) == "acme-crm · erp · @1")
      #expect(subtitle([doc("a", about: [])]) == "Whole workspace · @1")
      #expect(subtitle([doc("a", about: nil)]) == "Attachments not recorded · @1")
      let pending = [
        doc("a", about: ["app:acme-crm"], revision: 2),
        doc("a", about: ["app:acme-crm"], revision: 3, state: "proposed"),
      ]
      #expect(subtitle(pending) == "acme-crm · @2 · @3 proposed")
      #expect(subtitle([doc("a", about: [], archived: true)]) == "Whole workspace · @1 · archived")
    }

    @Test func readerTracksBodyLinesAndSourceSelection() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let docs = DocsModel()
      docs.ref = "doc:operations@1"
      await docs.show(reader, workspace: "acme")
      let initial = try #require(docs.lines)
      #expect(initial.first == 1 && initial.last < initial.total)
      docs.showingSource = true
      await docs.show(reader, workspace: "acme", append: true)
      #expect(docs.lines?.first == 1 && docs.lines?.last == initial.total)
      await docs.show(reader, workspace: "acme", version: 2)
      #expect(docs.lines?.last == initial.total && docs.showingSource)
      docs.ref = "doc:order-contract@2"
      #expect(!docs.showingSource && docs.lines == nil)
    }

    @Test func rejectedAttributionAndEmptySourceRemainTruthful() {
      let doc = AppDocument(
        ref: "doc:contract@3", slug: "contract", revision: 3, title: "Contract",
        kind: "contract", about: [], state: "rejected", archived: false,
        actor: "agent:codex:test", triagedBy: "human:acme")
      #expect(DocsContent.attribution(doc, now: AppV2Fixture.now).hasPrefix("Rejected by acme"))
      #expect(DocsContent.readerText(doc, body: "", diagnostic: "CLI metadata").isEmpty)
      #expect(
        DocsContent.readerText(nil, body: "", diagnostic: "No accepted revision")
          == "No accepted revision")
    }

    @Test func docsHeaderHandlesNoSelectionAndPartialHistory() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let history = try reader.documentVersions("order-contract", workspace: "acme")
      let partial = AppDocumentList(
        entries: Array(history.entries.prefix(1)), total: 3, nextOffset: 1)
      let docs = DocsModel(readVersions: { _, _, _, _ in partial })
      let model = AppModel(
        reader: reader, documents: docs,
        load: { _, _, _ in
          AppLoadedData(
            workspaces: [], workspace: "acme", snapshot: nil, map: nil,
            version: 1, checkedAt: AppV2Fixture.now)
        })
      await model.refresh().value
      model.navigate(to: .docs)
      #expect(model.screenSummary == "Workspace documents")
      model.select(document: "doc:order-contract@2")
      await docs.show(reader, workspace: "acme")
      #expect(model.screenSummary.contains("loaded history"))
    }

    @Test func realCLIDiffColoursBodyAndMetadataOnlyChanges() throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let body = try AppTestCLI.run(
        ["--ws", "acme", "doc", "show", "doc:order-contract@3", "--diff"], home: home)
      #expect(
        DocumentDiff(body).lines.contains { $0.kind == .added && $0.text.contains("idempotency") })
      try AppTestCLI.run(
        [
          "--ws", "acme", "doc", "edit", "order-contract", "--keep-body",
          "--title", "Acme order handbook", "--kind", "runbook", "--about", "app:acme-mobile",
          "--approved", "Update Acme metadata",
        ], home: home)
      let metadata = try AppTestCLI.run(
        ["--ws", "acme", "doc", "show", "doc:order-contract@4", "--diff"], home: home)
      #expect(!metadata.contains("@@"))
      let lines = DocumentDiff(metadata).lines
      for field in ["title:", "kind:", "about:"] {
        #expect(lines.contains { $0.kind == .removed && $0.text.contains(field) })
        #expect(lines.contains { $0.kind == .added && $0.text.contains(field) })
      }
    }

    @Test func realCLIDiffKeepsHeaderLikeBodyLinesColoured() throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      for (offset, body) in ["-- old\n-- metadata old\nkeep", "++ new\n++ metadata new\nkeep"]
        .enumerated()
      {
        let file = root.appending(path: "body.md")
        try body.write(to: file, atomically: true, encoding: .utf8)
        try AppTestCLI.run(
          [
            "--ws", "acme", "doc", "edit", "order-contract", "-F", file.path,
            "--approved", "Record Acme punctuation",
          ], home: home, seed: 501 + offset)
      }
      let text = try AppTestCLI.run(
        ["--ws", "acme", "doc", "show", "doc:order-contract@5", "--diff"], home: home)
      let lines = DocumentDiff(text).lines
      for (value, kind) in [
        ("--- old", DocumentDiff.Kind.removed), ("--- metadata old", .removed),
        ("+++ new", .added), ("+++ metadata new", .added),
      ] {
        #expect(lines.contains { $0.text == value && $0.kind == kind })
      }
    }

  }
#endif
