import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestoreDocumentCounterIntegrationTests {
  @Test func counterOnlyPublicRoundtripKeepsAbsentNamesAndOldReservations() throws {
    try withScratchDirectory { scratch in
      let sourceHome = scratch.appending(path: "source")
      let source = try RestoreDocumentFixture.source(sourceHome)
      try source.write {
        try $0.database.execute(
          sql: """
            DELETE FROM link WHERE workspace_id=17;
            DELETE FROM comment WHERE doc_rev_id IN (SELECT id FROM doc_rev WHERE doc_id=91);
            DELETE FROM doc_verification
            WHERE doc_rev_id IN (SELECT id FROM doc_rev WHERE doc_id=91);
            DELETE FROM doc_rev WHERE doc_id=91;
            DELETE FROM doc WHERE id=91;
            INSERT INTO seq_counter(scope,next) VALUES('doc_rev:17:incoming-only',400);
            """)
      }
      let directory = try RestoreDocumentIntegrationTests.publish(
        source, home: sourceHome, to: scratch.appending(path: "out"))
      let home = scratch.appending(path: "target")
      let target = try RestoreDocumentRowSupport.make(home)
      _ = try RestoreSupport.restore(directory, into: target, home: home)
      let snapshot = try ExportTree.parse(ExportTreeTests.render(target))
      #expect(snapshot.documents.documents.isEmpty && snapshot.documents.commentSequences.isEmpty)
      let floors = Dictionary(
        uniqueKeysWithValues: snapshot.documents.revisionAllocations.map {
          ($0.value("slug") ?? "", $0.value("next") ?? "")
        })
      #expect(
        floors == [
          "future-only": "333", "gone-rules": "88", "incoming-only": "400", "push-rules": "151",
          "removed-rules": "236",
        ])
      try target.read { db in
        let scopes = try String.fetchAll(db, sql: "SELECT scope FROM seq_counter")
        #expect(!scopes.contains("comment:doc_rev:901"))
        #expect(
          !scopes.contains("comment:doc_rev:1100") && !scopes.contains("comment:doc_rev:1101"))
        #expect(
          scopes.contains("comment:doc_rev:950") && scopes.contains("comment:doc_rev:4040404"))
      }
      #expect(
        try RestoreDocumentRowSupport.accept(
          "push-rules", store: target, ids: SeededIDGenerator(seed: 77)
        ).revision == 151)
    }
  }

  @Test func exhaustedDestinationHistorySurvivesPublicOlderRestore() throws {
    try withScratchDirectory { scratch in
      let sourceHome = scratch.appending(path: "source")
      let source = try RestoreDocumentFixture.source(sourceHome)
      let directory = try RestoreDocumentIntegrationTests.publish(
        source, home: sourceHome, to: scratch.appending(path: "out"))
      let home = scratch.appending(path: "target")
      let target = try RestoreDocumentRowSupport.make(home)
      try target.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET rev=? WHERE uid='newer-rejection'", arguments: [Int64.max])
      }
      _ = try RestoreSupport.restore(directory, into: target, home: home)
      let before = try RestoreSupport.dump(target)
      #expect(throws: StorageError.resourceExhausted) {
        try RestoreDocumentRowSupport.accept(
          "push-rules", store: target, ids: SeededIDGenerator(seed: 501))
      }
      #expect(try RestoreSupport.dump(target) == before)
    }
  }
}
