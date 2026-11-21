import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct WorkspaceRemovalMigrationTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["SILTA_SLOW_TESTS"] == "1"),
    .enabled(if: ProcessInfo.processInfo.environment["SILTA_V9_BINARY"] != nil)
  )
  func actualV9SelectorRefusesWorkspaceRemovalFloor() throws {
    let binary = try #require(ProcessInfo.processInfo.environment["SILTA_V9_BINARY"])
    try withScratchDirectory { home in
      let fixture = DocsMigrationTests.fixture.deletingLastPathComponent().appending(
        path: "storage-v9.db")
      let store = try DocAuditMigrationTests.copy(fixture, to: home)
      let history = try store.read {
        try String.fetchAll($0, sql: "SELECT previous_slugs FROM app")
      }
      try store.initialize()
      let before = try store.read { try Row.fetchAll($0, sql: "SELECT * FROM meta ORDER BY key") }
      let result = try SiltaBinary.runProcess(
        URL(filePath: binary), ["ws", "use", "acme", "--json"], in: home,
        environment: ["SILTA_HOME": home.path, "SILTA_ACTOR": "agent:codex:acme"])
      #expect(result.termination == .exit(9))
      #expect(result.stdout.contains("Database requires a newer version of silta."))
      #expect(
        try store.read { try Row.fetchAll($0, sql: "SELECT * FROM meta ORDER BY key") } == before)
      #expect(
        try store.read { try String.fetchAll($0, sql: "SELECT previous_slugs FROM app") } == history
      )
    }
  }
}
