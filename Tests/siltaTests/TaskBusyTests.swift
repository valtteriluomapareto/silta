import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct TaskBusyTests {
  @Test(.tags(.slow), .enabled(if: slowTestsEnabled()))
  func busyRetryNamesOnlyFailedCommandPath() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let queue = try DatabaseQueue(path: store.path)
      try queue.inTransaction(.immediate) { _ in
        let result = try SiltaBinary.run(
          ["--ws", "acme", "task", "add", "Private task body", "--json"],
          in: scratch, environment: TaskCommandTests.actor, timeout: 45)
        #expect(result.termination == .exit(5))
        #expect(result.stdout.contains("\"next\":[\"silta task add\"]"))
        #expect(!result.stdout.contains("Private task body"))
        return .rollback
      }
    }
  }
}
