#if DEBUG
  import Foundation
  @testable import SiltaApp
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

    @Test func markdownTablesAndDiffRemainReadable() {
      let table = "| Name | Value |\n| --- | ---: |\n| amount | 42 |"
      let content = MarkdownContent("# Contract\n\n" + table, title: "Contract")
      #expect(!content.blocks.contains { $0.header == 1 })
      #expect(content.blocks.contains { $0.code && String($0.text.characters).contains("amount") })
      let fenced = MarkdownContent("```text\n" + table + "\n```")
      #expect(fenced.blocks.filter(\.code).count == 1)
      let diff = DocumentDiff("--- old\n+++ new\n@@ -1 +1 @@\n-old\n+new\n same")
      #expect(diff.lines.map(\.kind) == [.metadata, .metadata, .metadata, .removed, .added, .context])
    }
  }
#endif
