import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct WorkspaceSettingsRepairTests {
  @Test(arguments: ["not-json", "null", "1.5", "\"broken\""])
  func validReplacementRepairsCorruptStoredSettings(stored: String) throws {
    withKnownIssue("#13: corrected settings cannot replace corrupt stored JSON") {
      try withScratchDirectory { home in
        let store = WorkspaceConfigTests.store(home)
        try WorkspaceConfigTests.apply(WorkspaceConfigTests.minimal, to: store)
        try WorkspaceSettingsRegressionTests.set(stored, in: store)
        let shown = try store.read { try WorkspaceConfig.render(from: $0, slug: "acme") }
        let replacement =
          shown.split(separator: "\n").map {
            $0.hasPrefix("settings:") ? "settings: {review_gate: none}" : String($0)
          }.joined(separator: "\n") + "\n"
        let result = try WorkspaceEditor.apply(
          replacement, slug: "acme", store: store, actor: TaskServiceTests.agent,
          identity: (SeededIDGenerator(seed: 3), TaskServiceTests.now),
          approved: "Repair the Acme settings")
        #expect(result == "acme")
        #expect(
          try store.read { try String.fetchOne($0, sql: "SELECT settings FROM workspace") }
            == "{\"review_gate\":\"none\"}")
        #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM approval") } == 1)
      }
    }
  }
}
