import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskPlanTests {
  static func work(_ env: SiltaEnvironment, directory: URL) async throws -> TaskService {
    try TaskServiceTests.setup(env)
    let service = TaskService(environment: env)
    var draft = TaskDraft(title: "Acme work")
    draft.start = true
    _ = try await service.add(draft, directory: directory)
    return service
  }

  @Test func revisionsCompareRefreshAndKeepSnapshots() async throws {
    try await withScratchDirectory { home in
      let clock = FakeClock(now: TaskServiceTests.now)
      let env = try TaskServiceTests.environment(home, clock: clock)
      let service = try await Self.work(env, directory: home)
      try env.db.write {
        try $0.database.execute(sql: "ALTER TABLE task ADD COLUMN future TEXT DEFAULT 'default'")
        try $0.database.execute(sql: "UPDATE task SET future='retained'")
      }
      clock.advance(milliseconds: 60_000)
      let original = "- [ ] First\n- [x] Second"
      let first = try service.plan("AC-1", text: original, ifRevision: 0)
      #expect(first.planRev == 1 && first.plan == original)
      #expect(try service.show("AC-1").claimedAt == TaskServiceTests.timestamp(clock.now()))
      #expect(throws: TaskError.staleRev("AC-1", actual: 1)) {
        _ = try service.plan("AC-1", text: "Wrong", ifRevision: 0)
      }
      #expect(throws: TaskError.invalid("--if-rev must be nonnegative.")) {
        _ = try service.plan("AC-1", text: "Wrong", ifRevision: -1)
      }
      clock.advance(milliseconds: 60_000)
      #expect(try service.tick("AC-1", step: 1, done: true, ifRevision: 1).planRev == 1)
      #expect(try service.show("AC-1").claimedAt == TaskServiceTests.timestamp(clock.now()))
      #expect(throws: TaskError.staleRev("AC-1", actual: 1)) {
        _ = try service.tick("AC-1", step: 2, done: false, ifRevision: 0)
      }
      #expect(try service.tick("AC-1", step: 2, done: false).plan == "- [x] First\n- [ ] Second")
      #expect(try service.plan("AC-1", text: "Replacement", ifRevision: 1).planRev == 2)
      try env.db.read { (db: Database) throws in
        #expect(
          try String.fetchAll(db, sql: "SELECT body_md FROM task_plan_rev ORDER BY rev") == [
            original, "Replacement",
          ])
        #expect(
          try String.fetchAll(db, sql: "SELECT actor FROM task_plan_rev") == [
            env.actor.description, env.actor.description,
          ])
        #expect(
          try String.fetchAll(db, sql: "SELECT kind FROM task_event ORDER BY id") == [
            "created", "plan", "step", "step", "plan",
          ])
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM change_log WHERE kind='task'") == 5)
        #expect(try String.fetchOne(db, sql: "SELECT future FROM task") == "retained")
      }
    }
  }

  @Test func claimAndWriterGateRefuseWithoutChanges() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      let service = try await Self.work(env, directory: home)
      _ = try service.plan("AC-1", text: "- [ ] Work")
      let rival = TaskService(
        environment: try TaskServiceTests.environment(
          home, actor: .agent(tool: "codex", session: "rival")))
      #expect(
        throws: TaskError.claimed("AC-1", holder: env.actor.description, minutes: 0, human: false)
      ) {
        _ = try rival.plan("AC-1", text: "Wrong")
      }
      #expect(throws: TaskError.self) { _ = try rival.tick("AC-1", step: 1, done: true) }
      try env.db.write {
        try $0.database.execute(sql: "UPDATE meta SET value='4' WHERE key='min_writer_version'")
      }
      #expect(throws: StorageError.schemaTooNew) { _ = try service.plan("AC-1", text: "Wrong") }
      #expect(throws: StorageError.schemaTooNew) {
        _ = try service.tick("AC-1", step: 1, done: true)
      }
      #expect(try service.show("AC-1").plan == "- [ ] Work")
      #expect(
        try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task_plan_rev") } == 1)
      #expect(try env.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task_event") } == 2)
    }
  }

  @Test func tickChangesOnlySelectedBytes() throws {
    let text = "# Acme\r\n```md\r\n- [ ] Example\r\n```\r\n- [X] Å\r\n  - [ ] Nested\r\n2. [ ] β"
    let done = try MarkdownPlan.tick(text, step: 2, done: true)
    #expect(
      Array(done.utf8) == Array(text.replacingOccurrences(of: "2. [ ] β", with: "2. [x] β").utf8))
    #expect(try MarkdownPlan.tick(done, step: 1, done: false).contains("- [ ] Å\r\n"))
    for step in [-1, 0, 3] {
      #expect(throws: TaskError.self) { _ = try MarkdownPlan.tick(text, step: step, done: true) }
    }
    #expect(throws: TaskError.self) { _ = try MarkdownPlan.tick("No boxes", step: 1, done: true) }
  }

  @Test func planSecretPolicyAndSafeRetry() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home)
      let service = try await Self.work(env, directory: home)
      let secret = "Pwd=" + "acme-value"
      let result = try service.plan("AC-1", text: secret)
      #expect(result.plan == "[REDACTED:password]" && result.warnings == [SecretGuard.warning])
      #expect(try service.show("AC-1", timeline: true).timeline?.last?.kind == "secret_redacted")
      #expect(throws: ActorError.self) {
        _ = try service.plan("AC-1", text: "Plain", allowSecret: true)
      }
      let human = TaskService(
        environment: try TaskServiceTests.environment(home, actor: TaskServiceTests.human()))
      do {
        _ = try human.plan("AC-1", text: secret)
        Issue.record("Human secret accepted")
      } catch let error as SecretError {
        #expect(error.next == ["silta task plan 'AC-1' -F <file> --allow-secret"])
        #expect(!error.message.contains(secret))
      }
      let otherHome = home.appending(path: "human")
      let humanEnv = try TaskServiceTests.environment(otherHome, actor: TaskServiceTests.human())
      let owned = try await Self.work(humanEnv, directory: home)
      #expect(try owned.plan("AC-1", text: secret, allowSecret: true).plan == secret)
    }
  }
}
