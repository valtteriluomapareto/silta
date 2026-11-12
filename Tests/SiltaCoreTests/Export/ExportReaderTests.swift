import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

/// The strict reader of format 1 (spec §15).
@Suite(.timeLimit(.minutes(1)))
struct ExportReaderTests {
  @Test func readerRoundTripsTheTree() throws {
    try withScratchDirectory { scratch in
      let store = try ExportFixture.make(scratch)
      let files = try ExportTreeTests.render(store)
      let snapshot = try ExportTree.parse(files)
      #expect(snapshot == (try store.read { try ExportSnapshot.read($0, workspace: "acme") }))
      ExportTreeTests.expectSame(snapshot.files(), files)
      let task = try #require(snapshot.tasks.first { $0.ref == "AC-10" })
      #expect(task.row.value("description_md") == "~~~\n## Plan\n")
      #expect(task.row.value("result_md") == nil)
      #expect(snapshot.tasks.first { $0.ref == "AC-2" }?.row.value("result_md") == "Waiting.")
    }
  }

  /// Every way a tree can differ from what export writes is refused by the reader.
  @Test(arguments: TreeDamage.all)
  func readerRefusesDamagedTrees(_ damage: TreeDamage) throws {
    try withScratchDirectory { scratch in
      let store = try ExportFixture.make(scratch)
      var files = try ExportTreeTests.render(store)
      damage.apply(&files)
      #expect(throws: ExportError.self) { try ExportTree.parse(files) }
    }
  }

  /// The manifest is checked before anything is parsed (spec §15): a changed, missing or
  /// unlisted file is named as such, not caught later as a file in the wrong form.
  @Test func readerChecksTheManifestFirst() throws {
    try withScratchDirectory { scratch in
      let store = try ExportFixture.make(scratch)
      let files = try ExportTreeTests.render(store)
      var changed = files
      changed["tasks/AC-2.md"] = Data(
        text(try #require(files["tasks/AC-2.md"])).replacingOccurrences(
          of: "Waiting.", with: "Waiting!"
        ).utf8)
      #expect(
        throws: ExportError.invalidTree(
          reason: "tasks/AC-2.md does not match its sha256", workspace: "acme")
      ) {
        try ExportTree.parse(changed)
      }
      var missing = files
      missing["links.jsonl"] = nil
      #expect(throws: ExportError.invalidTree(reason: "links.jsonl is missing", workspace: "acme"))
      {
        try ExportTree.parse(missing)
      }
      var extra = files
      extra["notes.md"] = Data()
      #expect(
        throws: ExportError.invalidTree(
          reason: "notes.md is not in the manifest", workspace: "acme")
      ) {
        try ExportTree.parse(extra)
      }
    }
  }

  /// A tree names its schema; one this binary doesn't know is refused, and an older
  /// one it knows is read (spec §15).
  @Test func readerChecksTheTreeSchema() throws {
    try withScratchDirectory { scratch in
      let store = try ExportFixture.make(scratch)
      var files = try ExportTreeTests.render(store)
      let manifest = text(try #require(files["manifest.json"]))
      files["manifest.json"] = Data(
        manifest.replacingOccurrences(of: #""schema": "v6""#, with: #""schema": "v3""#).utf8)
      #expect(try ExportTree.parse(files).schema == "v3")
      files["manifest.json"] = Data(
        manifest.replacingOccurrences(of: #""schema": "v6""#, with: #""schema": "v99""#).utf8)
      #expect(throws: StorageError.schemaTooNew) { try ExportTree.parse(files) }
    }
  }
}
