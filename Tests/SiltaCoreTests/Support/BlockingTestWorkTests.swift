import Darwin
import Dispatch
import Foundation
import SiltaTestSupport
import Synchronization
import Testing

private final class SingleTestWorker: TaskExecutor {
  private let queue = DispatchQueue(label: "silta.test.single-worker")

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
  }
}

struct BlockingTestScopeTests {
  @Test func runnerScopesStayCooperative() async throws {
    let test = try #require(Test.current)
    #expect(BlockingTestScope().scopeProvider(for: test, testCase: nil) != nil)
    try await BlockingTestScope().provideScope(for: test, testCase: nil) {
      let wasBlocking = onBlockingExecutor()
      #expect(!wasBlocking)
    }
    let testCase = try #require(Test.Case.current)
    #expect(BlockingTestScope().scopeProvider(for: test, testCase: testCase) != nil)
  }

  @Test func scopedProcessAllowsSingleWorkerProgress() async throws {
    try await checkScopedProcessProgress()
  }

  @Test func scopedErrorsPreserveTestingContext() async throws {
    let test = try #require(Test.current)
    let testCase = try #require(Test.Case.current)
    await #expect(throws: CocoaError(.fileReadUnknown)) {
      try await BlockingTestScope().provideScope(for: test, testCase: testCase) {
        #expect(Test.current?.id == test.id)
        throw CocoaError(.fileReadUnknown)
      }
    }
  }

  @Test func admissionBoundsWorkAndHandlesCancellation() async throws {
    let test = try #require(Test.current)
    let worker = SingleTestWorker()
    try await Task(executorPreference: worker) {
      let scope = BlockingTestScope()
      let (entered, announce) = AsyncStream<Void>.makeStream()
      let (released, release) = AsyncStream<Void>.makeStream()
      defer {
        announce.finish()
        release.finish()
      }
      let holders = (0..<8).map { _ in
        Task(executorPreference: worker) {
          try await scope.provideScope(for: test, testCase: nil) {
            announce.yield()
            for await _ in released { break }
          }
        }
      }
      var iterator = entered.makeAsyncIterator()
      for _ in 0..<8 {
        let event = await iterator.next()
        #expect(event != nil)
      }
      let ran = Mutex(false)
      let cancelled = Task(executorPreference: worker) {
        try await scope.provideScope(for: test, testCase: nil) {
          ran.withLock { $0 = true }
        }
      }
      await Task(executorPreference: worker) {}.value
      #expect(!ran.withLock { $0 })
      cancelled.cancel()
      for _ in 0..<8 { release.yield() }
      for holder in holders { try await holder.value }
      await #expect(throws: CancellationError.self) { try await cancelled.value }
      #expect(!ran.withLock { $0 })
    }.value
    try await checkFreshAdmission(test)
  }

  private func checkFreshAdmission(_ test: Test) async throws {
    let scope = BlockingTestScope()
    await #expect(throws: CocoaError(.fileReadUnknown)) {
      try await scope.provideScope(for: test, testCase: nil) {
        throw CocoaError(.fileReadUnknown)
      }
    }
    try await scope.provideScope(for: test, testCase: nil) {
      let wasBlocking = onBlockingExecutor()
      #expect(!wasBlocking)
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
      let testCase = try #require(Test.Case.current)
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
        try await BlockingTestScope().provideScope(for: test, testCase: testCase) {
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
  @Test func synchronousCaseUsesBlockingExecutor() {
    #expect(OperationQueue.current?.name == "silta.blocking-tests")
    #expect(Test.current != nil)
    #expect(Test.Case.current != nil)
  }

  @Test(arguments: [1, 2])
  func synchronousCasesUseBlockingExecutor(value: Int) {
    #expect(OperationQueue.current?.name == "silta.blocking-tests")
    #expect(OperationQueue.current?.maxConcurrentOperationCount == 32)
    #expect(Test.current != nil)
    #expect(Test.Case.current != nil)
    #expect(value > 0)
  }
}

private func onBlockingExecutor() -> Bool {
  OperationQueue.current?.name == "silta.blocking-tests"
}
