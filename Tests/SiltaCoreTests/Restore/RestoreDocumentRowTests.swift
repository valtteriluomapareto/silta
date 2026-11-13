import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestoreDocumentRowTests {
  @Test func restoresLiteralRowsWithNewIDsAndDeferredReferences() throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentRowSupport.make(home)
      var graph = try RestoreDocumentGraphFixture.graph()
      graph.documents.documents[0].records.swapAt(6, 7)
      let kept = try RestoreDocumentRowSupport.keptRows(store)
      let expected = try RestoreDocumentRowSupport.replace(
        store, tree: graph.tree, incoming: graph.documents)
      let after = try store.read { try ExportDocumentSnapshot.read($0, workspace: 17) }
      ExportTreeTests.expectSame(try after.files(), try expected.files())
      Golden.forTests().check(
        ExportFormat.jsonl(after.revisionAllocations), "restore-doc-allocations.jsonl")
      #expect(try store.read { try ExportLinks.read($0, workspace: 17) } == graph.tree.links)
      #expect(try RestoreDocumentRowSupport.keptRows(store) == kept)
      try store.read { (db: Database) throws in
        let doc = try #require(try Row.fetchOne(db, sql: "SELECT * FROM doc WHERE workspace_id=17"))
        let revision = try #require(
          try Row.fetchOne(
            db, sql: "SELECT * FROM doc_rev WHERE uid=?",
            arguments: [ExportDocumentTests.uid("003")]))
        #expect((doc["id"] as Int64) != 91 && (doc["current_rev"] as Int64) == 2)
        #expect((revision["id"] as Int64) != 901 && (revision["source_task_id"] as Int64) == 1700)
        #expect(
          try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM seq_counter WHERE scope IN "
              + "('comment:doc_rev:901','comment:doc_rev:1100','comment:doc_rev:1101')") == 0)
        #expect(try String.fetchOne(db, sql: "PRAGMA foreign_key_check") == nil)
      }
      #expect(after.commentSequences[1].value("next") == "9")
      #expect(after.documents[0].records[0].value("title") == nil)
      #expect(after.documents[0].records[1].value("triaged_by") == "human:acme")
      #expect(after.documents[0].records[5].value("app_shas") == ExportDocumentTests.shas)
      #expect(try store.read { try ExportSnapshot.read($0, workspace: "acme").documents } == after)
    }
  }

  @Test func counterOnlyReplacementKeepsIndependentNamesInPublicExports() throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentRowSupport.make(home)
      var graph = try RestoreDocumentGraphFixture.graph()
      graph.tree.links = []
      let incoming = ExportDocumentSnapshot(
        documents: [],
        revisionAllocations: [
          ExportDocumentTests.row([("slug", "incoming-only"), ("next", "400")])
        ],
        commentSequences: [])
      let expected = try RestoreDocumentRowSupport.replace(
        store, tree: graph.tree, incoming: incoming)
      let after = try store.read { try ExportDocumentSnapshot.read($0, workspace: 17) }
      #expect(after.documents.isEmpty && after.commentSequences.isEmpty)
      ExportTreeTests.expectSame(try after.files(), try expected.files())
      #expect(
        after.revisionAllocations.map { $0.value("slug") } == [
          "future-only", "gone-rules", "incoming-only", "push-rules", "removed-rules",
        ])
      #expect(try store.read { try ExportSnapshot.read($0, workspace: "acme").documents } == after)
    }
  }

  @Test func legacyTitleKindAndUnknownSnapshotsSurviveInsertion() throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentRowSupport.make(home)
      var graph = try RestoreDocumentGraphFixture.graph()
      RestoreDocumentGraphFixture.otherDocument(&graph.documents)
      graph.documents.documents[1].records[0] = graph.documents.documents[1].records[0]
        .replacing("uid", with: "owned-legacy-revision", keys: ExportFormat.docRecords[0].keys)
      let last = graph.documents.commentSequences.count - 1
      graph.documents.commentSequences[last] = graph.documents.commentSequences[last]
        .replacing("doc_rev", with: "owned-legacy-revision", keys: ["doc_rev", "next"])
      let expected = try RestoreDocumentRowSupport.replace(
        store, tree: graph.tree, incoming: graph.documents)
      let after = try store.read { try ExportDocumentSnapshot.read($0, workspace: 17) }
      ExportTreeTests.expectSame(try after.files(), try expected.files())
      let old = try #require(after.documents.first { $0.slug == "other-rules" })
      #expect(old.row.value("kind") == "design")
      #expect(old.row.value("title") == "Legacy\n" + String(repeating: "x", count: 121))
      #expect(old.records[0].value("title") == nil && old.records[0].value("about_refs") == nil)
    }
  }

  @Test func rollbackRestoresRowsAndEveryAllocationScope() throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentRowSupport.make(home)
      let graph = try RestoreDocumentGraphFixture.graph()
      let before = try RestoreSupport.dump(store)
      let expected = try RestoreDocumentRowSupport.replace(
        store, tree: graph.tree, incoming: graph.documents, rollingBack: true)
      Golden.forTests().check(
        ExportFormat.jsonl(expected.revisionAllocations), "restore-doc-allocations.jsonl")
      #expect(try RestoreSupport.dump(store) == before)
    }
  }

  @Test func lateLinkConstraintRollsBackRowsThreadsAndBothCounterKinds() throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentRowSupport.make(home)
      let graph = try RestoreDocumentGraphFixture.graph()
      try store.write {
        try $0.database.execute(
          sql: "DELETE FROM link WHERE workspace_id=17 AND uid='typed-010'; "
            + "UPDATE link SET uid='typed-010' WHERE workspace_id=23")
      }
      let before = try RestoreSupport.dump(store)
      #expect(throws: StorageError.constraintViolation) {
        try RestoreDocumentRowSupport.replace(store, tree: graph.tree, incoming: graph.documents)
      }
      #expect(try RestoreSupport.dump(store) == before)
    }
  }

  @Test func actualAllocationDoesNotReuseReplacedOrAbsentHistory() throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentRowSupport.make(home)
      let graph = try RestoreDocumentGraphFixture.graph()
      _ = try RestoreDocumentRowSupport.replace(store, tree: graph.tree, incoming: graph.documents)
      let ids = SeededIDGenerator(seed: 501)
      #expect(
        try RestoreDocumentRowSupport.accept("push-rules", store: store, ids: ids).revision == 151)
      #expect(
        try RestoreDocumentRowSupport.accept("removed-rules", store: store, ids: ids).revision
          == 236)
      #expect(try RestoreDocumentFixture.commentSequence(store) == 9)
    }
  }

  @Test func exhaustedHistoricalAllocationRefusesWithoutReusingOrChangingRows() throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentRowSupport.make(home)
      let graph = try RestoreDocumentGraphFixture.graph()
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET rev=? WHERE uid='newer-rejection'", arguments: [Int64.max])
      }
      _ = try RestoreDocumentRowSupport.replace(store, tree: graph.tree, incoming: graph.documents)
      let before = try RestoreSupport.dump(store)
      #expect(throws: StorageError.resourceExhausted) {
        try RestoreDocumentRowSupport.accept(
          "push-rules", store: store, ids: SeededIDGenerator(seed: 501))
      }
      #expect(try RestoreSupport.dump(store) == before)
    }
  }
}
