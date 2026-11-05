import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct TaskPriorityRecoveryTests {
  @Test func addRecoveryAndTextRetainNondefaultPriority() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      let refused = try SiltaBinary.run(
        [
          "task", "add", "Acme", "--priority", "3", "--allow-secret", "--json",
        ], in: scratch, environment: TaskCommandTests.actor)
      #expect(refused.termination == .exit(3))
      #expect(refused.stdout.contains("--priority 3"))
      #expect(
        try SiltaBinary.run(
          ["task", "add", "Acme", "--priority", "3"], in: scratch,
          environment: TaskCommandTests.actor
        ).termination == .exit(0))
      let shown = try SiltaBinary.run(
        ["task", "show", "AC-1"], in: scratch,
        environment: TaskCommandTests.actor)
      #expect(shown.stdout.contains("priority 3"))
    }
  }
}
