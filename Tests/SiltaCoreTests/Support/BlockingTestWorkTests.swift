import Darwin
import Dispatch
import Foundation
import SiltaTestSupport
import Testing

private final class SingleTestWorker: TaskExecutor {
  private let queue = DispatchQueue(label: "silta.test.single-worker")

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
  }
}

struct BlockingTestScopeTests {
  @Test func scopedProcessAllowsSingleWorkerProgress() async throws {
    try await checkScopedProcessProgress()
  }

  @Test func scopedErrorsPreserveTestingContext() async throws {
    let test = try #require(Test.current)
    await #expect(throws: CocoaError(.fileReadUnknown)) {
      try await BlockingTestScope().provideScope(for: test, testCase: nil) {
        #expect(Test.current?.id == test.id)
        throw CocoaError(.fileReadUnknown)
      }
    }
  }

  private func checkScopedProcessProgress() async throws {
    try await withScratchDirectory { scratch in
      let fifo = scratch.appending(path: "input").path
      #expect(mkfifo(fifo, 0o600) == 0)
      let descriptor = open(fifo, O_RDWR | O_NONBLOCK)
      #expect(descriptor >= 0)
      defer { close(descriptor) }
      let test = try #require(Test.current)
      let worker = SingleTestWorker()
      try await Task(executorPreference: worker) {
        let (entered, continuation) = AsyncStream<Void>.makeStream()
        let sibling = Task(executorPreference: worker) {
          for await _ in entered {
            var byte: UInt8 = 120
            #expect(write(descriptor, &byte, 1) == 1)
            return
          }
        }
        try await BlockingTestScope().provideScope(for: test, testCase: nil) {
          continuation.yield()
          defer { continuation.finish() }
          let result = try SiltaBinary.runProcess(
            URL(filePath: "/bin/dd"), ["if=" + fifo, "bs=1", "count=1"],
            in: scratch, timeout: 2, killAfter: 1)
          #expect(result.termination == .exit(0))
          #expect(result.stdout == "x")
        }
        await sibling.value
      }.value
    }
  }
}

@Suite(.blockingTestWork)
struct InheritedBlockingScopeTests {
  @Test(arguments: [1, 2])
  func synchronousCasesUseBlockingExecutor(value: Int) {
    #expect(OperationQueue.current?.name == "silta.blocking-tests")
    #expect(OperationQueue.current?.maxConcurrentOperationCount == 32)
    #expect(Test.current != nil)
    #expect(Test.Case.current != nil)
    #expect(value > 0)
  }
}
