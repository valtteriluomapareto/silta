import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct MapSlugMigrationTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["SILTA_SLOW_TESTS"] == "1"),
    .enabled(if: ProcessInfo.processInfo.environment["SILTA_V8_BINARY"] != nil)
  )
  func actualV8WriterRefusesSlugHistoryWithoutMutation() throws {
    let binary = try #require(ProcessInfo.processInfo.environment["SILTA_V8_BINARY"])
    try withScratchDirectory { home in
      let fixture = DocsMigrationTests.fixture.deletingLastPathComponent().appending(
        path: "storage-v8.db")
      let store = try DocAuditMigrationTests.copy(fixture, to: home)
      try store.initialize()
      try store.write { tx in
        try tx.database.execute(
          sql: "UPDATE app SET previous_slugs='[\"former\"]' WHERE id=(SELECT min(id) FROM app)")
      }
      let before = try store.read { try Row.fetchAll($0, sql: "SELECT * FROM app ORDER BY id") }
      let result = try SiltaBinary.runProcess(
        URL(filePath: binary),
        ["--json", "--ws", "acme", "task", "add", "Acme older writer proof"], in: home,
        environment: [
          "SILTA_HOME": home.path, "SILTA_ACTOR": "agent:codex:acme",
          "SILTA_NOW": "2023-11-14T22:13:22.000Z", "SILTA_ID_SEED": "72",
        ])
      #expect(result.termination == .exit(9))
      #expect(result.stdout.contains("Database requires a newer version of silta."))
      #expect(
        try store.read { try Row.fetchAll($0, sql: "SELECT * FROM app ORDER BY id") } == before)
      #expect(
        try store.read {
          try Int.fetchOne(
            $0, sql: "SELECT count(*) FROM task WHERE title='Acme older writer proof'")
        } == 0)
    }
  }
}
