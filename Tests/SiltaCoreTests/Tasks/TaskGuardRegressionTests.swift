import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

/// Guards that depend on who writes: the secret guard checks only added text, a human
/// unblocks without approval, and task reads have their index.
@Suite(.timeLimit(.minutes(1)))
struct TaskGuardRegressionTests {
  @Test func humanTickKeepsAnAllowedSecretPlan() async throws {
    try await withScratchDirectory { home in
      let env = try TaskServiceTests.environment(home, actor: TaskServiceTests.human())
      try TaskServiceTests.setup(env)
      let service = TaskService(environment: env)
      _ = try await service.add(TaskDraft(title: "Acme"), directory: home)
      let secret = "Pwd=" + "acme-secret"
      _ = try service.plan("AC-1", text: "- [ ] " + secret, allowSecret: true)
      let ticked = try service.tick("AC-1", step: 1, done: true)
      #expect(ticked.plan == "- [x] " + secret)
      #expect(ticked.warnings.isEmpty)
    }
  }

  @Test func taskEventsAreIndexedByTaskAndKind() throws {
    try withScratchDirectory { scratch in
      let store = DatabaseStore(
        home: scratch, clock: FakeClock(now: TaskServiceTests.now), jitter: { 0 })
      try store.initialize()
      let columns = try store.read {
        try String.fetchAll($0, sql: "SELECT name FROM pragma_index_info('task_event_task')")
      }
      #expect(columns == ["task_id", "kind"])
    }
  }

  @Test func humansUnblockOpenBlocksAndAgentsNeedApproval() async throws {
    try await withScratchDirectory { home in
      let human = TaskService(
        environment: try TaskServiceTests.environment(home, actor: TaskServiceTests.human()))
      try TaskServiceTests.setup(human.environment)
      for _ in 0..<2 { _ = try await human.add(TaskDraft(title: "Acme"), directory: home) }
      for ref in ["AC-1", "AC-2"] { _ = try human.block(ref, TaskBlockTests.input()) }
      let agent = TaskService(environment: try TaskServiceTests.environment(home))
      let refusal = #expect(throws: ActorError.self) { _ = try agent.unblock(["AC-1"]) }
      #expect(refusal?.message.hasPrefix("AC-1 waits on an answer;") == true)
      let approved = TaskService(environment: agent.environment, approved: "Unblock AC-1")
      #expect(try approved.unblock(["AC-1"]).approvalUsed)
      #expect(try !human.unblock(["AC-2"]).approvalUsed)
      let rows = try human.environment.db.read {
        try Int.fetchOne($0, sql: "SELECT count(*) FROM approval")
      }
      #expect(rows == 1)
    }
  }
}
