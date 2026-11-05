import Darwin
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

struct BlockingTestScopeTests {
  @Test func scopedProcessAllowsSingleWorkerProgress() async throws {
    await withKnownIssue("Blocking process scope occupies the only worker") {
      try await checkScopedProcessProgress()
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
    withKnownIssue("Inherited scope still occupies cooperative workers") {
      #expect(OperationQueue.current?.name == "silta.blocking-tests")
    }
    #expect(Test.current != nil)
    #expect(Test.Case.current != nil)
    #expect(value > 0)
  }
}
