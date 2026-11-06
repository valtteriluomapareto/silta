import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .tags(.slow), .enabled(if: slowTestsEnabled()))
struct PolicyScenarioTests {
  @Test(arguments: ["proposals-ask", "ask-short"])
  func policyReplayStoresOnlyScriptedOutcomes(_ name: String) throws {
    try withScratchDirectory { scratch in
      let file = ScenarioRunner.repository.appending(path: "Tests/Scenarios/\(name).yaml")
      try ScenarioRunner.run(file, in: scratch)
      let store = BriefCommandTests().store(scratch)
      try store.read { (db: Database) throws in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM task WHERE status='proposed'") == 0)
        #expect(
          try Int.fetchOne(db, sql: "SELECT count(*) FROM comment WHERE kind='question'") == 0)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM comment WHERE kind='handoff'") == 1)
        if name == "proposals-ask" {
          #expect(
            try String.fetchAll(db, sql: "SELECT status FROM task ORDER BY seq") == [
              "doing", "todo",
            ])
          #expect(
            try String.fetchAll(db, sql: "SELECT words FROM approval ORDER BY id") == [
              "Ask before Acme proposals.", "Add the Acme retry fix for later.",
            ])
        } else {
          #expect(
            try Int.fetchOne(db, sql: "SELECT count(*) FROM comment WHERE kind='decision'") == 1)
          #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM approval") == 1)
        }
      }
    }
  }
}
