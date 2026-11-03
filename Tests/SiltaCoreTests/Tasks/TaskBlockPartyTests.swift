import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskBlockPartyTests {
  @Test func partiesAreHistoricalWorkspaceScopedAndConcurrent() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      try await TaskBlockTests.add(service, count: 2, directory: home)
      let results = try await withThrowingTaskGroup(of: TaskBlockResult.self) { group in
        for ref in ["AC-1", "AC-2"] {
          group.addTask { try service.block(ref, TaskBlockTests.input(["ext:acme"])) }
        }
        var values: [TaskBlockResult] = []
        for try await value in group { values.append(value) }
        return values
      }
      #expect(results.flatMap(\.warnings).filter { $0.code == "new_party" }.count == 1)
      _ = try service.unblock(["AC-1", "AC-2"])
      let known = try service.block("AC-1", TaskBlockTests.input(["ext:acme-next"]))
      #expect(
        known.warnings.map(\.message) == [
          "New party ext:acme-next; known parties: ext:acme. Silta sends nothing."
        ])
      let old = try service.block("AC-2", TaskBlockTests.input(["ext:acme"]))
      #expect(old.warnings.isEmpty)
      let config = try WorkspaceConfig.parse(
        "workspace: {slug: beta, name: Acme Beta, task_prefix: BE}")
      try service.environment.db.write {
        try config.apply(in: $0, ids: service.environment.ids, at: TaskServiceTests.now)
      }
      let beta = TaskService(environment: service.environment, workspace: "beta")
      try await TaskBlockTests.add(beta, directory: home)
      let other = try beta.block("BE-1", TaskBlockTests.input(["ext:acme"]))
      #expect(
        other.warnings.map(\.message) == [
          "New party ext:acme; known parties: none. Silta sends nothing."
        ])
      #expect(throws: TaskError.self) {
        _ = try service.block("AC-1", TaskBlockTests.input(["BE-1"]))
      }
    }
  }

  @Test func unknownEventKeysAndUnblockFieldsSurvive() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      try await TaskBlockTests.add(service, directory: home)
      _ = try service.block("AC-1", TaskBlockTests.input(["ext:acme"]))
      try service.environment.db.write { tx in
        try tx.database.execute(sql: "ALTER TABLE task ADD COLUMN future TEXT DEFAULT 'default'")
        try tx.database.execute(
          sql: "UPDATE task SET future='Acme retained',claimed_by=?,claimed_at=?",
          arguments: [
            TaskServiceTests.agent.description, TaskService.timestamp(TaskServiceTests.now),
          ])
        let body = try #require(
          try String.fetchOne(tx.database, sql: "SELECT body FROM task_event WHERE kind='block'"))
        try tx.database.execute(
          sql: "UPDATE task_event SET body=? WHERE kind='block'",
          arguments: [String(body.dropLast()) + ",\"future\":42}"])
      }
      let before = try service.environment.db.read { db in
        try String.fetchOne(db, sql: "SELECT body FROM task_event WHERE kind='block'")
      }
      _ = try service.block("AC-1", TaskBlockTests.input())
      try service.environment.db.write { tx in
        try tx.database.execute(
          sql: "UPDATE task SET claimed_by=?,claimed_at=?",
          arguments: [
            TaskServiceTests.agent.description, TaskService.timestamp(TaskServiceTests.now),
          ])
      }
      _ = try service.unblock(["AC-1"])
      let task = try service.show("AC-1")
      #expect(task.claimedBy == nil && task.claimedAt == nil && task.followUpAt == nil)
      try service.environment.db.read { db in
        let future = try String.fetchOne(db, sql: "SELECT future FROM task")
        let body = try String.fetchOne(
          db, sql: "SELECT body FROM task_event WHERE kind='block' ORDER BY id LIMIT 1")
        #expect(future == "Acme retained" && body == before)
      }
    }
  }
}
