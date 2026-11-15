import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocCommentCounterFormatTests {
  @Test func legacyReservationsAreIgnoredAndExhaustionDoesNotOverflow() throws {
    try withScratchDirectory { scratch in
      let sourceHome = scratch.appending(path: "source")
      let source = try RestoreDocumentFixture.source(sourceHome)
      try source.write {
        try $0.database.execute(
          sql: "UPDATE comment SET seq=? WHERE doc_rev_id=901 AND seq=7",
          arguments: [Int64.max])
      }
      var tree = try source.read { try ExportSnapshot.read($0, workspace: "acme") }
      tree.format = "2"
      tree.documents.legacyCommentSequences = [
        ExportDocumentTests.row([("doc_rev", "discarded-owner"), ("next", "unused")])
      ]
      let directory = try RestoreSupport.write(
        tree.files(), to: scratch.appending(path: "out/acme"))
      let home = scratch.appending(path: "target")
      let target = try RestoreDocumentRowSupport.make(home)
      _ = try RestoreSupport.restore(directory, into: target, home: home)
      let highest = try target.read {
        try Int64.fetchOne($0, sql: "SELECT max(seq) FROM comment WHERE doc_rev_id IS NOT NULL")
      }
      #expect(highest == Int64.max)
      let before = try RestoreSupport.dump(target)
      #expect(throws: StorageError.resourceExhausted) {
        try RestoreDocumentFixture.commentSequence(target)
      }
      #expect(try RestoreSupport.dump(target) == before)
      let current = try target.read { try ExportSnapshot.read($0, workspace: "acme") }
      #expect(current.documents.documents == tree.documents.documents)
      #expect(current.documents.legacyCommentSequences == nil)
    }
  }

  @Test func publicExportOmitsCommentReservations() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "source")
      let store = try RestoreDocumentFixture.source(home)
      let before = try RestoreSupport.dump(store)
      let directory = try RestoreDocumentIntegrationTests.publish(
        store, home: home, to: scratch.appending(path: "out"))
      let files = try RestoreService.readTree(directory)
      let bytes = try #require(files["manifest.json"])
      let manifest = try #require(
        try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
      let counts = try #require(manifest["counts"] as? [String: String])
      do {
        #expect(manifest["format"] as? String == "3")
        #expect(files["doc_comment_sequences.jsonl"] == nil)
        #expect(counts["doc_comment_sequence"] == nil)
      }
      #expect(files["doc_revision_allocations.jsonl"] != nil)
      #expect(try RestoreSupport.dump(store) == before)
    }
  }

  @Test(arguments: [false, true])
  func restoreRebuildsCommentCountersFromRetainedRows(noComments: Bool) throws {
    try withScratchDirectory { scratch in
      let sourceHome = scratch.appending(path: "source")
      let source = try RestoreDocumentFixture.source(sourceHome)
      try source.write {
        try $0.database.execute(
          sql: "UPDATE seq_counter SET next=444 WHERE scope='comment:doc_rev:901'")
        if noComments {
          try $0.database.execute(
            sql: """
              DELETE FROM link WHERE workspace_id=17 AND (from_kind='comment' OR to_kind='comment');
              DELETE FROM comment WHERE doc_rev_id IN (SELECT id FROM doc_rev WHERE doc_id=91);
              """)
        }
      }
      let directory = try RestoreDocumentIntegrationTests.publish(
        source, home: sourceHome, to: scratch.appending(path: "out"))
      let home = scratch.appending(path: "target")
      let target = try RestoreDocumentRowSupport.make(home)
      let kept = try RestoreDocumentFixture.retained(target)
      _ = try RestoreSupport.restore(directory, into: target, home: home)
      #expect(try RestoreDocumentFixture.retained(target) == kept)
      let allocated = try RestoreDocumentFixture.commentSequence(target)
      do {
        #expect(allocated == (noComments ? 1 : 8))
      }
      #expect(
        try RestoreDocumentRowSupport.accept(
          "push-rules", store: target, ids: SeededIDGenerator(seed: 77)
        ).revision == 151)
    }
  }
}
