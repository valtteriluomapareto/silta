import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskOrganizationTests {
  static func service(_ home: URL, clock: FakeClock = FakeClock(now: TaskServiceTests.now)) throws
    -> TaskService
  {
    let env = try TaskServiceTests.environment(home, clock: clock)
    try TaskServiceTests.setup(env)
    return TaskService(environment: env, approved: "Organize the Acme backlog")
  }

  static func add(
    _ service: TaskService, title: String = "Acme", priority: Int = 2,
    start: Bool = false, directory: URL
  ) async throws -> TaskResult {
    var draft = TaskDraft(title: title)
    draft.priority = priority
    draft.start = start
    return try await TaskService(environment: service.environment, workspace: service.workspace)
      .add(draft, directory: directory)
  }

  static func counts(_ service: TaskService) throws -> [Int] {
    try service.environment.db.read { db in
      try ["task_event", "change_log", "approval", "task_plan_rev", "link"].map { table in
        try #require(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)"))
      }
    }
  }

  @Test func priorityBatchValidationAndAtomicity() async throws {
    try await withScratchDirectory { home in
      let service = try Self.service(home)
      for priority in [3, 1, 2] {
        _ = try await Self.add(service, priority: priority, directory: home)
      }
      #expect(try service.list().map(\.ref) == ["AC-2", "AC-3", "AC-1"])
      for priority in [0, 4] {
        await #expect(throws: TaskError.invalid("Priority must be 1, 2 or 3.")) {
          _ = try await Self.add(service, priority: priority, directory: home)
        }
      }
      var batch = TaskTriage()
      batch.accept = ["AC-1", "task:AC-1"]
      batch.drop = ["AC-2", "AC-404"]
      batch.priority = 1
      let before = try Self.counts(service)
      #expect(throws: TaskReferenceError.self) { _ = try service.triage(batch) }
      #expect(try Self.counts(service) == before)
      #expect(try service.show("AC-1").status == "proposed")
      batch.drop = ["AC-1"]
      #expect(throws: TaskError.self) { _ = try service.triage(batch) }
      #expect(try Self.counts(service) == before)
      batch.drop = ["AC-2", "task:AC-2"]
      #expect(try service.triage(batch).map(\.status) == ["todo", "dropped"])
      #expect(try service.show("AC-1").priority == 1)
      #expect(try service.show("AC-2").priority == 1)
      #expect(try service.show("AC-2").result == "Dropped in triage.")
      #expect(try service.show("AC-2").closedAt == TaskService.timestamp(TaskServiceTests.now))
      #expect(try Self.counts(service)[2] == 1)
      #expect(throws: TaskError.self) { _ = try service.triage(batch) }
      #expect(throws: TaskError.self) { _ = try service.triage(TaskTriage()) }
      var invalid = batch
      invalid.priority = 4
      invalid.accept = ["AC-3"]
      invalid.drop = []
      #expect(throws: TaskError.invalid("Priority must be 1, 2 or 3.")) {
        _ = try service.triage(invalid)
      }
    }
  }

  @Test func triageHumanGateSecretsAndForeignClaims() async throws {
    try await withScratchDirectory { home in
      let approved = try Self.service(home)
      let env = approved.environment
      _ = try await Self.add(approved, priority: 3, directory: home)
      var batch = TaskTriage()
      batch.drop = ["AC-1"]
      batch.why = ("Pwd=" + "acme-secret")
      let agent = TaskService(environment: env)
      #expect(throws: ActorError.self) { _ = try agent.triage(batch) }
      let before = try Self.counts(agent)
      try env.db.write { tx in
        try tx.database.execute(
          sql: "UPDATE task SET claimed_by=?,claimed_at=?",
          arguments: ["agent:codex:other", TaskService.timestamp(TaskServiceTests.now)])
      }
      #expect(throws: TaskError.self) { _ = try approved.triage(batch) }
      #expect(try Self.counts(agent) == before)
      try env.db.write { try $0.database.execute(sql: "UPDATE task SET claimed_by=NULL") }
      let result = try approved.triage(batch)
      #expect(result[0].warnings.map(\.code) == ["secret_redacted"])
      #expect(try agent.show("AC-1").result == "[REDACTED:password]")
      #expect(try agent.show("AC-1").priority == 3)
      #expect(try agent.show("AC-1").claimedBy == nil)
      let human = TaskService(
        environment: try TaskServiceTests.environment(
          home,
          actor: TaskServiceTests.human()))
      _ = try await Self.add(human, directory: home)
      var accept = TaskTriage()
      accept.accept = ["AC-2"]
      #expect(try human.show("AC-2").status == "todo")
      #expect(throws: TaskError.self) { _ = try human.triage(accept) }
    }
  }

  @Test func archiveBoundaryOverridesAndPureReads() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let service = try Self.service(home, clock: clock)
      _ = try await Self.add(service, start: true, directory: home)
      _ = try await service.close("AC-1", result: "Acme done", directory: home)
      clock.advance(milliseconds: 14 * 86400 * 1000)
      #expect(try !service.show("AC-1").archived)
      clock.advance(milliseconds: 1)
      let before = try Self.counts(service)
      #expect(try service.show("AC-1").archived)
      #expect(try service.list().isEmpty)
      var all = TaskFilter()
      all.archived = true
      #expect(try service.list(all).map(\.ref) == ["AC-1"])
      #expect(try Self.counts(service) == before)
      _ = try service.archive("AC-1", keep: true)
      #expect(try service.list().count == 1)
      #expect(try service.show("AC-1").archiveOverride == "kept")
      #expect(try service.show("AC-1", timeline: true).timeline?.last?.body == "kept")
      _ = try service.archive("AC-1")
      #expect(try service.list().isEmpty)
      #expect(try service.show("AC-1").archiveOverride == "archived")
      #expect(try service.show("AC-1", timeline: true).timeline?.last?.body == "archived")
      _ = try await Self.add(service, start: true, directory: home)
      try service.environment.db.write { tx in
        try tx.database.execute(
          sql: "UPDATE task SET closed_at=? WHERE seq=2",
          arguments: [TaskService.timestamp(TaskServiceTests.now)])
      }
      clock.advance(milliseconds: 100 * 86400 * 1000)
      #expect(try !service.show("AC-2").archived)
      try service.environment.db.write { tx in
        try tx.database.execute(
          sql: "UPDATE workspace SET settings=?",
          arguments: ["{\"archive_after_days\":200,\"future\":true}"])
        try tx.database.execute(sql: "UPDATE task SET archive_override=NULL WHERE seq=1")
      }
      #expect(try !service.show("AC-1").archived)
    }
  }
}
