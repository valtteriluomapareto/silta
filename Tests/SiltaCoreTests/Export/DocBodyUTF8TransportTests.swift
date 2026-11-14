import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocBodyUTF8TransportTests {
  @Test(arguments: ["", "Acme\u{0}tail", "é\u{0}尾"])
  func captureAndFilesRetainCompleteRevisionBody(body: String) throws {
    try withScratchDirectory { home in
      let store = try ExportDocumentSnapshotFixture.make(home)
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE doc_rev SET body_md=CAST(? AS TEXT)
            WHERE doc_id IN (SELECT id FROM doc WHERE workspace_id=17)
            """, arguments: [Data(body.utf8)])
      }
      let bytes = try Self.bodies(store)
      #expect(bytes == Array(repeating: Data(body.utf8), count: 5))
      let before = try RestoreSupport.dump(store)
      let snapshot = try ExportDocumentSnapshotTests.read(store)
      let parsed = try ExportDocumentSnapshot.parse(snapshot.files(), workspace: "acme")
      let expected: [Data?] = Array(repeating: Data(body.utf8), count: 5)
      withKnownIssue("Document export capture must retain revision body bytes after NUL") {
        #expect(Self.values(snapshot) == expected)
        #expect(Self.values(parsed) == expected)
      } when: {
        body.contains("\u{0}")
      }
      #expect(try RestoreSupport.dump(store) == before)
      #expect(try Self.bodies(store) == bytes)
    }
  }

  @Test(arguments: ["", "Acme\u{0}tail", "é\u{0}尾"])
  func authoredRestoreRetainsCompleteRevisionBody(body: String) throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentRowSupport.make(home)
      var graph = try RestoreDocumentGraphFixture.graph()
      for index in graph.documents.documents[0].records.indices
      where graph.documents.documents[0].records[index].value("table") == "doc_rev" {
        graph.documents.documents[0].records[index] = graph.documents.documents[0].records[index]
          .replacing("body_md", with: body, keys: ExportFormat.docRecords[0].keys)
      }
      graph.tree.documents = graph.documents
      let kept = try RestoreDocumentRowSupport.keptRows(store)
      let expected = try RestoreDocumentRowSupport.replace(
        store, tree: graph.tree, incoming: graph.documents)
      let bytes = try Self.bodies(store)
      let wanted = Array(repeating: Data(body.utf8), count: 5)
      withKnownIssue("Document restore must bind complete independently authored body bytes") {
        #expect(bytes == wanted)
      } when: {
        body.contains("\u{0}")
      }
      let after = try ExportDocumentSnapshotTests.read(store)
      #expect(after.revisionAllocations == expected.revisionAllocations)
      #expect(after.commentSequences == expected.commentSequences)
      #expect(try RestoreDocumentRowSupport.keptRows(store) == kept)
      #expect(
        try store.read {
          try String.fetchAll(
            $0,
            sql: """
              SELECT DISTINCT typeof(r.body_md) FROM doc_rev r JOIN doc d ON d.id=r.doc_id
              WHERE d.workspace_id=17
              """)
        } == ["text"])
      #expect(
        try store.read {
          try String.fetchAll(
            $0,
            sql: """
              SELECT DISTINCT r.state FROM doc_rev r JOIN doc d ON d.id=r.doc_id
              WHERE d.workspace_id=17 ORDER BY r.state
              """)
        } == ["accepted", "proposed", "rejected", "superseded"])
    }
  }

  @Test func exportCaptureInvalidStoredBodyUTF8RefusesWithoutMutation() throws {
    try withScratchDirectory { home in
      let store = try ExportDocumentSnapshotFixture.make(home)
      let invalid = Data([0x41, 0xFF, 0x42])
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE doc_rev SET body_md=CAST(? AS TEXT)
            WHERE doc_id IN (SELECT id FROM doc WHERE workspace_id=17) AND rev=2
            """, arguments: [invalid])
      }
      let bytes = try Self.bodies(store)
      try #require(bytes.count == 5)
      #expect(bytes[1] == invalid)
      let before = try RestoreSupport.dump(store)
      var captured: ExportDocumentSnapshot?
      var files: [String: Data]?
      var failure: StorageError?
      do {
        captured = try ExportDocumentSnapshotTests.read(store)
        files = try captured?.files()
      } catch let error as StorageError {
        #expect(error == .corrupt)
        failure = error
      }
      withKnownIssue("Invalid stored export body must refuse before returning replacement text") {
        #expect(failure == .corrupt)
        #expect(captured == nil && files == nil)
      }
      #expect(try RestoreSupport.dump(store) == before)
      #expect(try Self.bodies(store) == bytes)
    }
  }

  private static func values(_ snapshot: ExportDocumentSnapshot) -> [Data?] {
    snapshot.documents.flatMap(\.records).filter { $0.value("table") == "doc_rev" }
      .map { $0.value("body_md").map { Data($0.utf8) } }
  }

  private static func bodies(_ store: DatabaseStore) throws -> [Data] {
    try store.read {
      try Data.fetchAll(
        $0,
        sql: """
          SELECT CAST(r.body_md AS BLOB) FROM doc_rev r JOIN doc d ON d.id=r.doc_id
          WHERE d.workspace_id=17 ORDER BY r.rev
          """)
    }
  }
}
