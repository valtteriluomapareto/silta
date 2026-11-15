import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

extension DocCommentCounterFormatTests {
  @Test func reusedPhysicalRevisionScopeGetsTheRetainedRowsCounter() throws {
    try withScratchDirectory { scratch in
      let sourceHome = scratch.appending(path: "source")
      let source = try RestoreDocumentFixture.source(sourceHome)
      let directory = try RestoreDocumentIntegrationTests.publish(
        source, home: sourceHome, to: scratch.appending(path: "out"))
      let home = scratch.appending(path: "target")
      let target = try RestoreDocumentRowSupport.make(home)
      let owner = try #require(
        try target.read {
          try Int64.fetchOne(
            $0,
            sql: """
              SELECT max(r.id)+1 FROM doc_rev r JOIN doc d ON d.id=r.doc_id
              WHERE d.workspace_id<>17
              """)
        })
      try target.write {
        try $0.database.execute(
          sql: "INSERT INTO seq_counter(scope,next) VALUES(?,4444)",
          arguments: ["comment:doc_rev:\(owner)"])
      }
      var failure: (any Error)?
      do { _ = try RestoreSupport.restore(directory, into: target, home: home) } catch {
        failure = error
      }
      do {
        #expect(failure == nil)
      }
      guard failure == nil else { return }
      #expect(
        try target.read {
          try Int64.fetchOne(
            $0, sql: "SELECT next FROM seq_counter WHERE scope=?",
            arguments: ["comment:doc_rev:\(owner)"])
        } == 1)
      #expect(try RestoreDocumentFixture.commentSequence(target) == 8)
      #expect(
        try target.read {
          try Int64.fetchOne(
            $0,
            sql: "SELECT count(*) FROM seq_counter WHERE scope IN "
              + "('comment:doc_rev:950','comment:doc_rev:4040404')")
        } == 2)
    }
  }
}
