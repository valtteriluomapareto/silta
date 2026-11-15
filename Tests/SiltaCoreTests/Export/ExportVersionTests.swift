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

  static func frozenTwo() throws -> [String: Data] {
    var files = try ExportTreeTests.golden("acme")
    let manifest = URL(filePath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "Golden/export-v2-manifest.json")
    files["manifest.json"] = try Data(contentsOf: manifest)
    files["doc_comment_sequences.jsonl"] = Data()
    return files
  }

  @Test func frozenFormatTwoKeepsBytesAndUpgradesItsOwnedPublication() throws {
    let files = try Self.frozenTwo()
    let parsed = try ExportTree.parse(files)
    #expect(parsed.format == "2" && parsed.documents.legacyCommentSequences == [])
    ExportTreeTests.expectSame(try parsed.files(), files)
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = ExportFixture.store(home)
      try store.initialize()
      let root = scratch.appending(path: "out")
      let directory = try RestoreSupport.write(files, to: root.appending(path: "acme"))
      _ = try RestoreSupport.restore(directory, into: store, home: home)
      _ = try ExportService.export(workspace: "acme", to: root, store: store, home: home)
      let current = try RestoreService.readTree(directory)
      #expect(try Self.version(current) == "3")
      #expect(current["doc_comment_sequences.jsonl"] == nil)
      ExportTreeTests.expectSame(current, try ExportTreeTests.render(store))
    }
  }

  @Test func manifestVersionControlsLegacyStreamEligibility() throws {
    var missing = try Self.frozenTwo()
    missing["doc_comment_sequences.jsonl"] = nil
    let bytes = try #require(missing["manifest.json"])
    let text = try #require(String(data: bytes, encoding: .utf8))
    missing["manifest.json"] = Data(
      text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.contains(#""path": "doc_comment_sequences.jsonl""#) }.joined(separator: "\n")
        .utf8)
    #expect(
      throws: ExportError.invalidTree(
        reason: "format 2 requires its legacy comment reservation stream", workspace: "acme")
    ) {
      try ExportTree.parse(missing)
    }
    var forbidden = try Self.frozenTwo()
    forbidden["manifest.json"] = Data(
      text.replacingOccurrences(
        of: #""format": "2""#,
        with: #""format": "3""#
      ).utf8)
    #expect(
      throws: ExportError.invalidTree(
        reason: "format 3 cannot hold legacy comment reservations", workspace: "acme")
    ) {
      try ExportTree.parse(forbidden)
    }
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
    ExportTreeTests.expectSame(try parsed.files(), files)
    let apps = try #require(parsed.sections.first { $0.name == "apps" })
    #expect(apps.rows.compactMap { $0.value("slug") } == ["mobile", "doc", "edge", "service"])
    let edges = try #require(parsed.sections.first { $0.name == "edges" })
    #expect(edges.rows.compactMap { $0.value("kind") } == ["HTTP API", "SDK / v1"])
  }

  @Test func newExportsUseFormatThreeAndOnlyRevisionAllocations() throws {
    try withScratchDirectory { scratch in
      let store = try ExportFixture.make(scratch)
      let files = try ExportTreeTests.render(store)
      #expect(try Self.version(files) == "3")
      #expect(files["doc_revision_allocations.jsonl"] == Data())
      #expect(files["doc_comment_sequences.jsonl"] == nil)
      do { ExportTreeTests.expectSame(try ExportTree.parse(files).files(), files) } catch {
        #expect(Bool(false), "Current format must parse without a comment stream: \(error)")
      }
    }
  }

  @Test func frozenTreeRestoresLiteralLegacyValuesIntoCurrentFormat() throws {
    try withScratchDirectory { home in
      let before = try ExportTree.parse(Self.frozen())
      let store = ExportFixture.store(home)
      try store.initialize()
      _ = try RestoreSupport.restore(Self.frozenDirectory, into: store, home: home)
      let files = try ExportTreeTests.render(store)
      #expect(try Self.version(files) == "3")
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
      #expect(try Self.version(files) == "3")
      ExportTreeTests.expectSame(files, try ExportTreeTests.render(store))
    }
  }

  @Test func unsupportedVersionsStillRefuse() throws {
    var files = try Self.frozen()
    let data = try #require(files["manifest.json"])
    let manifest = try #require(String(data: data, encoding: .utf8))
    files["manifest.json"] = Data(
      manifest.replacingOccurrences(
        of: #""format": "1""#, with: #""format": "4""#
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
      #expect(
        throws: ExportError.invalidTree(
          reason: "doc_revision_allocations.jsonl is missing", workspace: "acme")
      ) {
        try ExportTree.parse(missing)
      }
      var changed = original
      changed["doc_revision_allocations.jsonl"] = Data(
        #"{"slug": "rules", "next": "20", "unknown": "ignored"}"#.appending("\n").utf8)
      TreeDamage.rehash(&changed, "doc_revision_allocations.jsonl")
      #expect(throws: ExportError.self) { try ExportTree.parse(changed) }
    }
  }
}
