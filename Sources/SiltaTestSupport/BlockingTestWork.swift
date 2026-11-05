import Foundation
package import Testing

private final class BlockingTestExecutor: TaskExecutor {
  static let shared = BlockingTestExecutor()
  private let queue: OperationQueue

  private init() {
    queue = OperationQueue()
    queue.name = "silta.blocking-tests"
    queue.maxConcurrentOperationCount = 4
  }

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    queue.addOperation {
      job.runSynchronously(on: self.asUnownedTaskExecutor())
    }
  }
}

/// Runs synchronous test bodies without occupying cooperative executor workers.
package struct BlockingTestScope: TestTrait, SuiteTrait, TestScoping {
  package init() {}
  package var isRecursive: Bool { true }

  package func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
    guard !test.isSuite, !test.isParameterized || testCase != nil else { return nil }
    return self
  }

  package func provideScope(
    for test: Test, testCase: Test.Case?,
    performing function: @concurrent @Sendable () async throws -> Void
  ) async throws {
    try await withTaskExecutorPreference(BlockingTestExecutor.shared) {
      try await function()
    }
  }
}

extension Trait where Self == BlockingTestScope {
  /// Keeps blocking test bodies outside the cooperative pool.
  package static var blockingTestWork: Self { Self() }
}
