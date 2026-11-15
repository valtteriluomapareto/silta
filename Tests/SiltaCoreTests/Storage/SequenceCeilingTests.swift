import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct SequenceCeilingTests {
  @Test(arguments: ["task:17", "comment:doc_rev:901"], [false, true])
  func terminalCounterRefusesWithoutChangingTransactionTruth(scope: String, atMaximum: Bool) throws
  {
    try withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.write {
        try $0.database.execute(
          sql: "INSERT INTO seq_counter(scope,next) VALUES(?,?)",
          arguments: [scope, atMaximum ? Int64.max : Int64.max - 1])
      }
      if !atMaximum {
        #expect(try store.write { try $0.nextSequence(scope: scope) } == Int64.max - 1)
      }
      let before = try RestoreSupport.dump(store)
      var allocated: Int64?
      var failure: (any Error)?
      do {
        allocated = try store.write { tx in
          try tx.recordChange(kind: "doc", rowID: 1)
          return try tx.nextSequence(scope: scope)
        }
      } catch { failure = error }
      let after = try RestoreSupport.dump(store)
      do {
        #expect((failure as? StorageError) == .resourceExhausted)
        #expect(allocated == nil && after == before)
      }
    }
  }

  @Test func missingAndNormalScopesKeepTheirExistingSequence() throws {
    try withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      let values = try store.write { tx in
        [try tx.nextSequence(scope: "task:17"), try tx.nextSequence(scope: "task:17")]
      }
      #expect(values == [1, 2])
      #expect(
        try store.read {
          try Int64.fetchOne($0, sql: "SELECT next FROM seq_counter WHERE scope='task:17'")
        } == 3)
    }
  }
}
