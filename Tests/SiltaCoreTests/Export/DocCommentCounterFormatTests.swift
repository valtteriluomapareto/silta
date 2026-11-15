import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocCommentCounterFormatTests {
  @Test func publicExportOmitsCommentReservations() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "source")
      let store = try RestoreDocumentFixture.source(home)
      let before = try RestoreSupport.dump(store)
      let directory = try RestoreDocumentIntegrationTests.publish(
        store, home: home, to: scratch.appending(path: "out"))
      let files = try RestoreService.readTree(directory)
      let manifest = try #require(
        try JSONSerialization.jsonObject(with: #require(files["manifest.json"])) as? [String: Any])
      let counts = try #require(manifest["counts"] as? [String: String])
      withKnownIssue("SI-132: current exports include unnecessary comment reservations") {
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
      withKnownIssue("SI-132: restore preserves comment reservation gaps") {
        #expect(allocated == (noComments ? 1 : 8))
      }
      #expect(
        try RestoreDocumentRowSupport.accept(
          "push-rules", store: target, ids: SeededIDGenerator(seed: 77)
        ).revision == 151)
    }
  }
}
