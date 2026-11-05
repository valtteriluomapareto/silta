import Dispatch
import Foundation
import SiltaTestSupport
import Testing

struct BlockingTestWorkTests {
  @Test func blockingWorkAllowsSingleWorkerProgress() async throws {
    let worker = SingleTestWorker()
    try await Task(executorPreference: worker) {
      let (entered, continuation) = AsyncStream<Void>.makeStream()
      let release = DispatchSemaphore(value: 0)
      let sibling = Task(executorPreference: worker) {
        for await _ in entered {
          release.signal()
          return
        }
      }
      let progressed = try await withBlockingTestWork {
        continuation.yield()
        defer { continuation.finish() }
        return release.wait(timeout: .now() + 2) == .success
      }
      await sibling.value
      #expect(progressed)
    }.value
  }

  @Test func blockingWorkPreservesTestingContextAndErrors() async throws {
    let test = Test.current?.id
    let inherited = try await withBlockingTestWork { Test.current?.id }
    #expect(test != nil && inherited == test)
    await #expect(throws: CocoaError(.fileReadUnknown)) {
      try await withBlockingTestWork { throw CocoaError(.fileReadUnknown) }
    }
  }
}

private final class SingleTestWorker: TaskExecutor {
  private let queue = DispatchQueue(label: "silta.test.single-worker")

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
  }
}
