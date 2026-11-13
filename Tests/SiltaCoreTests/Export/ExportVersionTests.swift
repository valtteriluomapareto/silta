import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct ExportVersionTests {
  static var frozenDirectory: URL {
    URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "Fixtures/export-v1-acme")
  }

  static func frozen() throws -> [String: Data] {
    try RestoreService.readTree(frozenDirectory)
  }

  static func version(_ files: [String: Data]) throws -> String {
    let data = try #require(files["manifest.json"])
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(object["format"] as? String)
  }

  @Test func frozenFormatOneKeepsItsOriginalBytes() throws {
    let files = try Self.frozen()
    #expect(try Self.version(files) == "1")
    let parsed = try ExportTree.parse(files)
    #expect(parsed.schema == "v4")
    ExportTreeTests.expectSame(parsed.files(), files)
    let apps = try #require(parsed.sections.first { $0.name == "apps" })
    #expect(apps.rows.compactMap { $0.value("slug") } == ["mobile", "doc", "edge", "service"])
    let edges = try #require(parsed.sections.first { $0.name == "edges" })
    #expect(edges.rows.compactMap { $0.value("kind") } == ["HTTP API", "SDK / v1"])
  }

  @Test func newExportsUseFormatTwoAndRequiredAllocationStreams() throws {
    try withScratchDirectory { scratch in
      let store = try ExportFixture.make(scratch)
      let files = try ExportTreeTests.render(store)
      #expect(try Self.version(files) == "2")
      #expect(files["doc_revision_allocations.jsonl"] == Data())
      #expect(files["doc_comment_sequences.jsonl"] == Data())
      ExportTreeTests.expectSame(try ExportTree.parse(files).files(), files)
    }
  }

  @Test func frozenTreeRestoresLiteralLegacyValuesIntoCurrentFormat() throws {
    try withScratchDirectory { home in
      let before = try ExportTree.parse(Self.frozen())
      let store = ExportFixture.store(home)
      try store.initialize()
      _ = try RestoreSupport.restore(Self.frozenDirectory, into: store, home: home)
      let files = try ExportTreeTests.render(store)
      #expect(try Self.version(files) == "2")
      let after = try ExportTree.parse(files)
      #expect(after.sections == before.sections)
      #expect(after.tasks == before.tasks)
      #expect(after.links == before.links)
      #expect(after.approvals == before.approvals)
    }
  }

  @Test func publicationCanUpgradeAnOwnedFormatOneTree() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = ExportFixture.store(home)
      try store.initialize()
      _ = try RestoreSupport.restore(Self.frozenDirectory, into: store, home: home)
      let root = scratch.appending(path: "out")
      let target = try RestoreSupport.write(Self.frozen(), to: root.appending(path: "acme"))
      _ = try ExportService.export(workspace: "acme", to: root, store: store, home: home)
      let files = try RestoreService.readTree(target)
      #expect(try Self.version(files) == "2")
      ExportTreeTests.expectSame(files, try ExportTreeTests.render(store))
    }
  }

  @Test func unsupportedVersionsStillRefuse() throws {
    var files = try Self.frozen()
    let data = try #require(files["manifest.json"])
    let manifest = try #require(String(data: data, encoding: .utf8))
    files["manifest.json"] = Data(
      manifest.replacingOccurrences(
        of: #""format": "1""#, with: #""format": "3""#
      ).utf8)
    #expect(throws: ExportError.self) { try ExportTree.parse(files) }
  }

  @Test func requiredEmptyStreamsCannotBeMissingOrCarryIgnoredData() throws {
    try withScratchDirectory { home in
      let store = try ExportFixture.make(home)
      let original = try ExportTreeTests.render(store)
      try #require(original["doc_revision_allocations.jsonl"] != nil)
      var missing = original
      missing["doc_revision_allocations.jsonl"] = nil
      #expect(throws: ExportError.self) { try ExportTree.parse(missing) }
      var changed = original
      changed["doc_revision_allocations.jsonl"] = Data(
        #"{"slug": "rules", "next": "20", "unknown": "ignored"}"#.appending("\n").utf8)
      TreeDamage.rehash(&changed, "doc_revision_allocations.jsonl")
      #expect(throws: ExportError.self) { try ExportTree.parse(changed) }
    }
  }
}
