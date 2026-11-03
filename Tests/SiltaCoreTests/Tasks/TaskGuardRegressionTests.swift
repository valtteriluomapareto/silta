import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

/// The secret guard checks only text a write adds, and task reads have their index.
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
}
