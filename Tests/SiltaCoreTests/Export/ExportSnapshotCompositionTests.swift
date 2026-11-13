import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct ExportSnapshotCompositionTests {
  @Test func fullSnapshotRoundTripsLiteralFilesAndAuthoredCounts() throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentGraphFixture.source(home)
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO comment(uid,task_id,seq,kind,body_md,actor,created_at)
            VALUES('task-comment',700,1,'comment','Task discussion','human:acme','')
            """)
      }
      let before = try RestoreSupport.dump(store)
      let snapshot = try store.read { try ExportSnapshot.capture($0, workspace: "acme") }
      let files = try snapshot.files()
      ExportTreeTests.expectSame(
        files.filter { $0.key.hasPrefix("docs/") || $0.key.hasPrefix("doc_") },
        try ExportDocumentSnapshotTests.golden())
      #expect(snapshot.documents == (try ExportDocumentSnapshotTests.read(store)))
      #expect(snapshot.links == (try RestoreDocumentGraphFixture.links()))
      let parsed = try ExportTree.parseSnapshot(files)
      #expect(parsed == snapshot)
      ExportTreeTests.expectSame(try parsed.files(), files)
      let manifest = try #require(files["manifest.json"])
      let object = try #require(try JSONSerialization.jsonObject(with: manifest) as? [String: Any])
      let counts = try #require(object["counts"] as? [String: String])
      let keys = [
        "doc", "doc_rev", "doc_verification", "doc_revision_allocation",
        "doc_comment_sequence", "comment",
      ]
      let selected = ExportRow(keys: keys, values: counts)
      Golden.forTests().check(ExportFormat.line(selected) + "\n", "export-doc-counts.json")
      #expect(try RestoreSupport.dump(store) == before)
      #expect(try store.read { try ExportSnapshot.read($0, workspace: "acme") } == snapshot)
      #expect(try ExportTree.parse(files) == snapshot)
    }
  }

  @Test func emptyDocumentCompositionKeepsPublishedBytes() throws {
    try withScratchDirectory { home in
      let store = try ExportFixture.make(home)
      let tree = try store.read { try ExportSnapshot.capture($0, workspace: "acme") }
      ExportTreeTests.expectSame(try tree.files(), try ExportTreeTests.golden("acme"))
      let old = try ExportVersionTests.frozen()
      ExportTreeTests.expectSame(try ExportTree.parseSnapshot(old).files(), old)
    }
  }

  @Test func formatOneCannotHideDocumentsOrStandaloneReservations() throws {
    var graph = try RestoreDocumentGraphFixture.graph()
    graph.tree.documents = graph.documents
    graph.tree.format = "1"
    #expect(throws: ExportError.self) { try graph.tree.files() }
    graph.tree.documents.documents = []
    graph.tree.documents.commentSequences = []
    #expect(throws: ExportError.self) { try graph.tree.files() }
  }

  @Test func rawCaptureCanReadDestinationMetadataThatNeedsRepair() throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentGraphFixture.source(home)
      try store.write {
        try $0.database.execute(sql: "UPDATE doc SET title='Broken projection' WHERE id=91")
      }
      let before = try RestoreSupport.dump(store)
      let snapshot = try store.read { try ExportSnapshot.capture($0, workspace: "acme") }
      let document = try #require(snapshot.documents.documents.first)
      #expect(document.row.value("title") == "Broken projection")
      #expect(throws: ExportError.self) {
        try RestoreDocumentGraph(tree: snapshot, documents: snapshot.documents, slug: "acme").run()
      }
      #expect(try RestoreSupport.dump(store) == before)
    }
  }

  @Test(arguments: ["title", "kind"])
  func currentMetadataComparesUnicodeBytes(_ key: String) throws {
    var graph = try RestoreDocumentGraphFixture.graph()
    let composed = "caf\u{e9}"
    let decomposed = "cafe\u{301}"
    #expect(composed == decomposed)
    RestoreDocumentGraphFixture.document(&graph.documents, key, composed)
    RestoreDocumentGraphFixture.record(&graph.documents, 1, key, decomposed)
    #expect(throws: ExportError.self) {
      try RestoreDocumentGraph(tree: graph.tree, documents: graph.documents, slug: "acme").run()
    }
  }
}
