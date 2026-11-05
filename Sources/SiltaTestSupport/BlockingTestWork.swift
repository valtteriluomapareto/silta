import Foundation
package import Testing

private final class BlockingTestExecutor: TaskExecutor {
  static let shared = BlockingTestExecutor()
  private let queue: OperationQueue

  private init() {
    queue = OperationQueue()
    queue.name = "silta.blocking-tests"
    // Cases wait on child processes. Admit I/O work alongside long stress cases
    // while bounding simultaneous bodies independently of cooperative workers.
    queue.maxConcurrentOperationCount = 32
  }

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    queue.addOperation {
      job.runSynchronously(on: self.asUnownedTaskExecutor())
    }
  }
}

/// Admits test functions before their deadlines, then runs synchronous case bodies
/// without occupying cooperative executor workers.
package struct BlockingTestScope: TestTrait, SuiteTrait, TestScoping {
  package init() {}
  package var isRecursive: Bool { true }

  package func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
    guard !test.isSuite else { return nil }
    return self
  }

  package func provideScope(
    for test: Test, testCase: Test.Case?,
    performing function: @concurrent @Sendable () async throws -> Void
  ) async throws {
    // Function admission precedes Swift Testing's case timers.
    if testCase == nil {
      try await BlockingTestAdmissions.shared.run(function)
      return
    }
    try await withTaskExecutorPreference(BlockingTestExecutor.shared) {
      try await function()
    }
  }
}

extension Trait where Self == BlockingTestScope {
  /// Keeps blocking test bodies outside the cooperative pool.
  package static var blockingTestWork: Self { Self() }
}

private actor BlockingTestAdmissions {
  static let shared = BlockingTestAdmissions()
  private var running = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func run(_ body: @concurrent @Sendable () async throws -> Void) async throws {
    try Task.checkCancellation()
    if running == 8 {
      await withCheckedContinuation { waiting.append($0) }
    } else {
      running += 1
    }
    defer {
      if waiting.isEmpty {
        running -= 1
      } else {
        waiting.removeFirst().resume()
      }
    }
    try Task.checkCancellation()
    try await body()
  }
}
