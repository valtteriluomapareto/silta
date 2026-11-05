import Foundation
import SiltaCore
import SiltaTestSupport
import Synchronization
import Testing

/// The hook's timing decisions on a fake monotonic clock. These run in the parallel
/// suite because no assertion depends on how busy the machine is; the wall-clock proof
/// that the process honours them is `WallClockHookTests`, run isolated by
/// `scripts/verify.sh full`.
struct BriefHookDeadlineTests {
  /// A deadline frozen at `milliseconds` after the hook started.
  static func deadline(_ milliseconds: Int) -> BriefHookDeadline {
    let elapsed = FakeElapsed(milliseconds: milliseconds)
    return BriefHookDeadline(elapsed: { elapsed.now() })
  }

  func deadline(_ milliseconds: Int) -> BriefHookDeadline { Self.deadline(milliseconds) }

  /// The watchdog schedules exactly this budget; child reads stop half a second sooner.
  @Test func processBudgetIsOnePointFiveSecondsWithAHalfSecondChildReserve() {
    #expect(BriefHookDeadline.budget == .milliseconds(1500))
    #expect(BriefHookDeadline.childReserve == .milliseconds(500))
    #expect(deadline(0).childSeconds == 1.0)
    #expect(deadline(1000).childSeconds == 0)
  }

  @Test(arguments: [
    (elapsed: 0, requested: 10.0, bounded: 1.0),
    (elapsed: 750, requested: 10.0, bounded: 0.25),
    (elapsed: 0, requested: 0.1, bounded: 0.1),
  ])
  func childReadsEndHalfASecondBeforeTheProcessDeadline(
    elapsed: Int, requested: Double, bounded: Double
  ) async throws {
    let directory = URL(filePath: "/acme")
    let expected = GitRequest(
      arguments: ["status"], directory: directory, timeout: bounded, lazyFetch: false)
    let scripted = ScriptedGitRunner(script: [(expected, .success(.init(termination: .exit(0))))])
    let notifications = Mutex(0)
    let runner = BriefHookGitRunner(
      runner: scripted, deadline: deadline(elapsed),
      onTimeout: { notifications.withLock { $0 += 1 } })
    let result = try await runner.run(
      GitRequest(arguments: ["status"], directory: directory, timeout: requested))
    #expect(result.termination == .exit(0))
    #expect(scripted.requests == [expected])
    #expect(notifications.withLock { $0 } == 0)
  }

  @Test(arguments: [1000, 1499, 1500])
  func childReadsDoNotStartInsideTheCleanupReserve(_ milliseconds: Int) async throws {
    let scripted = ScriptedGitRunner(script: [])
    let notifications = Mutex(0)
    let runner = BriefHookGitRunner(
      runner: scripted, deadline: deadline(milliseconds),
      onTimeout: { notifications.withLock { $0 += 1 } })
    let result = try await runner.run(
      GitRequest(arguments: ["status"], directory: URL(filePath: "/acme")))
    #expect(result.termination == .timedOut)
    #expect(scripted.requests.isEmpty)
    #expect(notifications.withLock { $0 } == 1)
  }
}
