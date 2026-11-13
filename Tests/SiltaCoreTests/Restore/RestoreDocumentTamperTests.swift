import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestoreDocumentTamperTests {
  @Test(arguments: RestoreDocumentGraphTests.damages, [false, true])
  func malformedPublicGraphsRefuseBeforeWriting(
    _ damage: RestoreDocumentGraphTests.Damage, dryRun: Bool
  ) throws {
    try withScratchDirectory { scratch in
      var graph = try RestoreDocumentGraphFixture.graph()
      damage.apply(&graph.tree, &graph.documents)
      graph.tree.documents = graph.documents
      let directory = try RestoreSupport.write(
        graph.tree.files(), to: scratch.appending(path: "tree/acme"))
      let home = scratch.appending(path: "home")
      let target = try RestoreDocumentRowSupport.make(home)
      try RestoreSupport.settle(target)
      let before = try RestoreSupport.dump(target)
      let backups = try RestoreSupport.backups(home)
      do {
        _ = try RestoreSupport.restore(directory, into: target, home: home, dryRun: dryRun)
        Issue.record("Restored malformed graph: \(damage.testDescription)")
      } catch let error as any CodedError {
        #expect(error.code == .invalid)
        #expect(
          !error.message.contains("is not in the form export writes"),
          "Public admission remained closed instead of validating the graph")
      }
      #expect(try RestoreSupport.dump(target) == before)
      #expect(try RestoreSupport.backups(home) == backups)
    }
  }

  @Test(arguments: ["title", "kind"])
  func byteDistinctCurrentMetadataIsRejectedPublicly(_ key: String) throws {
    try withScratchDirectory { scratch in
      var graph = try RestoreDocumentGraphFixture.graph()
      RestoreDocumentGraphFixture.document(&graph.documents, key, "caf\u{e9}")
      RestoreDocumentGraphFixture.record(&graph.documents, 1, key, "cafe\u{301}")
      graph.tree.documents = graph.documents
      let directory = try RestoreSupport.write(
        graph.tree.files(), to: scratch.appending(path: "tree/acme"))
      let home = scratch.appending(path: "home")
      let target = try RestoreDocumentRowSupport.make(home)
      let before = try RestoreSupport.dump(target)
      #expect(
        throws: ExportError.invalidTree(
          reason: "current document metadata differs from its accepted revision", workspace: "acme")
      ) {
        try RestoreSupport.restore(directory, into: target, home: home)
      }
      #expect(try RestoreSupport.dump(target) == before)
    }
  }

  @Test(arguments: ["doc", "doc_rev", "doc_verification", "task-comment", "doc-comment"])
  func foreignUIDsAreCheckedBeforePublicReplacement(_ kind: String) throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let target = try RestoreDocumentRowSupport.make(home)
      try RestoreSnapshotPreflightTests.foreignRows(target)
      var tree = try RestoreDocumentGraphFixture.graph().tree
      let old: String
      let new: String
      switch kind {
      case "doc":
        old = ExportDocumentTests.uid("001")
        new = "other-doc"
      case "doc_rev":
        old = ExportDocumentTests.uid("002")
        new = "other-revision"
      case "doc_verification":
        old = ExportDocumentTests.uid("030")
        new = "foreign-verification"
      case "task-comment":
        old = try #require(
          tree.tasks[0].records.first { $0.value("table") == "comment" }?.value("uid"))
        new = "foreign-doc-comment"
      default:
        old = ExportDocumentTests.uid("040")
        new = "foreign-task-comment"
      }
      Self.renameUID(&tree, from: old, to: new)
      try RestoreDocumentGraph(tree: tree, documents: tree.documents, slug: "acme").run()
      let directory = try RestoreSupport.write(
        tree.files(), to: scratch.appending(path: "tree/acme"))
      let before = try RestoreSupport.dump(target)
      do {
        _ = try RestoreSupport.restore(directory, into: target, home: home)
        Issue.record("Restored another workspace's \(kind) UID")
      } catch let error as any CodedError {
        #expect(error.code == .conflict)
        #expect(error.message.contains("belongs to another workspace"))
      }
      #expect(try RestoreSupport.dump(target) == before)
    }
  }

  @Test(arguments: [
    "digest", "manifest counts", "missing stream", "low floor", "symlink", "approval",
  ])
  func damagedDocumentTreesChangeNothing(_ kind: String) throws {
    try withScratchDirectory { scratch in
      let tree = try RestoreDocumentGraphFixture.graph().tree
      var files = try tree.files()
      let path = "docs/push-rules.md"
      switch kind {
      case "digest": files[path] = Data("tampered\n".utf8)
      case "manifest counts":
        files["manifest.json"] = Data(
          text(files["manifest.json"] ?? Data()).replacingOccurrences(
            of: #""doc": "1""#, with: #""doc": "9""#
          ).utf8)
      case "missing stream": files[ExportFormat.docAllocationsFile] = nil
      case "low floor":
        let stream = ExportFormat.docAllocationsFile
        files[stream] = Data(
          text(files[stream] ?? Data()).replacingOccurrences(
            of: #""next": "20""#, with: #""next": "1""#
          ).utf8)
        TreeDamage.rehash(&files, stream)
      default: break
      }
      let directory = try RestoreSupport.write(files, to: scratch.appending(path: "tree/acme"))
      if kind == "symlink" {
        try FileManager.default.createSymbolicLink(
          at: directory.appending(path: "docs/extra.md"),
          withDestinationURL: scratch.appending(path: "outside"))
      }
      let home = scratch.appending(path: "home")
      let target = try RestoreDocumentRowSupport.make(home)
      let before = try RestoreSupport.dump(target)
      do {
        _ = try RestoreSupport.restore(
          directory, into: target, home: home,
          manifest: kind == "approval" ? "deadbeef" : nil)
        Issue.record("Restored damaged document tree: \(kind)")
      } catch let error as any CodedError {
        #expect(error.code == (kind == "approval" ? .conflict : .invalid))
      }
      #expect(try RestoreSupport.dump(target) == before)
    }
  }

  static func renameUID(_ tree: inout ExportSnapshot, from old: String, to new: String) {
    func row(_ original: ExportRow) -> ExportRow {
      var result = original
      for index in result.fields.indices
      where ["uid", "doc_rev", "thread", "from", "to", "source_task"].contains(
        result.fields[index].key)
      {
        if result.fields[index].value.utf8.elementsEqual(old.utf8) {
          result.fields[index].value = new
        }
      }
      return result
    }
    for index in tree.tasks.indices {
      tree.tasks[index].row = row(tree.tasks[index].row)
      tree.tasks[index].records = tree.tasks[index].records.map(row)
    }
    for index in tree.documents.documents.indices {
      tree.documents.documents[index].row = row(tree.documents.documents[index].row)
      tree.documents.documents[index].records = tree.documents.documents[index].records.map(row)
    }
    tree.documents.commentSequences = tree.documents.commentSequences.map(row)
    tree.links = tree.links.map(row)
  }
}
