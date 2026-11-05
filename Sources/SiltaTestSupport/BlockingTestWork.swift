import Foundation

/// Suspends the caller while long synchronous test work runs outside the cooperative pool.
/// The child task inherits Swift Testing's task-local context, including assertion attribution.
package func withBlockingTestWork<T: Sendable>(
  _ body: @escaping @Sendable () throws -> T
) async throws -> T {
  try await Task(executorPreference: BlockingTestExecutor()) { try body() }.value
}

private final class BlockingTestExecutor: TaskExecutor {
  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    Thread.detachNewThread {
      job.runSynchronously(on: self.asUnownedTaskExecutor())
    }
  }
}
