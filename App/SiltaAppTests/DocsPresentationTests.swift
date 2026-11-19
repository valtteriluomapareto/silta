#if DEBUG
  import Foundation
  @testable import SiltaApp
  import SwiftUI
  import Synchronization
  @testable import SiltaAppSupport
  import Testing

  @MainActor struct DocsPresentationTests {
    @Test func groupsDocumentsByRecordedAttachment() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }  // cleanup
      let home = root.appending(path: "data")
      try AppDocsFixture.seed(home: home)
      let reader = try AppReader(home: home, user: "acme", now: { AppV2Fixture.now })
      let docs = DocsModel()
      await docs.refresh(reader, workspace: "acme", about: nil, archived: true)
      let sections = DocsContent.sections(docs.groups(search: ""))
      #expect(sections.contains { $0.id.hasPrefix("edge:") })
      #expect(sections.contains { $0.id.hasPrefix("app:") })
      #expect(sections.first?.title == "acme-mobile → acme-backend · http-api")
      #expect(sections.flatMap(\.groups).contains { $0.id == "legacy-notes" })
      #expect(sections.flatMap(\.groups).contains { $0.id == "push-categories" })
      docs.ref = "doc:order-contract@2"
      await docs.show(reader, workspace: "acme")
      let proposal = try #require(DocsContent.proposal(in: docs.versions))
      let banner = DocsContent.attribution(proposal, now: AppV2Fixture.now)
      #expect(banner.contains("Codex") && banner.contains("AC-9") && banner.contains("@3"))
      #expect(DocsContent.row(docs.groups(search: "order")[0]).contains("@3 proposed"))
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

    @Test func markdownLinksShowAndProtectTheirActualDestinations() throws {
      let address = "https://example.test/docs?q=one"
      let source = """
        [Local reference](file:///acme/inert)

        [**Acme** documentation](\(address))

        [Relative reference](/acme/notes)

        `[Sample](https://example.test/sample)`
        """
      let blocks = MarkdownContent(source).blocks
      let local = try #require(blocks.first { String($0.text.characters) == "Local reference" })
      #expect(local.text.runs.compactMap(\.link).isEmpty)
      let relative = try #require(
        blocks.first { String($0.text.characters) == "Relative reference" })
      #expect(relative.text.runs.compactMap(\.link).isEmpty)
      let allowed = try #require(
        blocks.first { String($0.text.characters).hasPrefix("Acme documentation") })
      #expect(Set(allowed.text.runs.compactMap { $0.link?.absoluteString }) == [address])
      #expect(String(allowed.text.characters) == "Acme documentation (\(address))")
      let sample = try #require(blocks.first { String($0.text.characters).hasPrefix("[Sample]") })
      #expect(sample.text.runs.compactMap(\.link).isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func sharedLinkActionChecksTheActualDestination() async throws {
      let opened = Mutex<[URL]>([])
      let action = DocumentMarkdown.linkAction { url in
        opened.withLock { $0.append(url) }
        return .handled
      }
      let accepted = ["https://example.test/docs", "http://example.test/read"]
      let rejected = ["file:///acme/inert", "acme:reference", "https:reference", "/acme/notes"]
      for address in accepted + rejected {
        let url = try #require(URL(string: address))
        let handled = await withCheckedContinuation { continuation in
          action(url) { continuation.resume(returning: $0) }
        }
        #expect(handled == accepted.contains(address))
      }
      #expect(opened.withLock { $0.map(\.absoluteString) } == accepted)
    }

    @Test func markdownTablesAndDiffRemainReadable() {
      let table = "| Name | Value |\n| --- | ---: |\n| amount | 42 |"
      let content = MarkdownContent("# Contract\n\n" + table, title: "Contract")
      #expect(!content.blocks.contains { $0.header == 1 })
      #expect(content.blocks.contains { $0.code && String($0.text.characters).contains("amount") })
      let fenced = MarkdownContent("```text\n" + table + "\n```")
      #expect(fenced.blocks.filter(\.code).count == 1)
      let diff = DocumentDiff("--- old\n+++ new\n@@ -1 +1 @@\n-old\n+new\n same")
      #expect(
        diff.lines.map(\.kind) == [.metadata, .metadata, .metadata, .removed, .added, .context])
    }
  }
#endif
