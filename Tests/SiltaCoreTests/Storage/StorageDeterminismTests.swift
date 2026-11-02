import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StorageDeterminismTests {
  @Test func fixedEnvironmentReplaysContentionWithoutRandomClockAdvancement() throws {
    try withScratchDirectory { scratch in
      var identifiers: [String] = []
      var elapsed: [TimeInterval] = []
      for index in 0..<2 {
        let environment = try SiltaEnvironment.system(
          environment: [
            "SILTA_HOME": scratch.appending(path: "data-\(index)").path,
            "SILTA_NOW": "2023-11-14T22:13:20.000Z", "SILTA_ID_SEED": "0",
          ], userHome: scratch.appending(path: "user"), temporaryRoots: [scratch])
        try environment.db.write { try $0.database.execute(sql: "PRAGMA busy_timeout=0") }
        let before = environment.clock.now()
        let external = try DatabaseQueue(path: environment.db.path)
        try external.write { _ in
          do {
            #expect(throws: StorageError.busy) { try environment.db.write { _ in () } }
          }
        }
        let after = environment.clock.now()
        elapsed.append(after.timeIntervalSince(before))
        identifiers.append(try environment.ids.next(at: after))
      }
      #expect(elapsed.allSatisfy { abs($0 - 0.001) < 0.000001 })
      #expect(identifiers[0] == identifiers[1])
    }
  }
}
