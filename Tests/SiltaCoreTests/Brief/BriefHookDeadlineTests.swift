import Foundation
import SiltaCore
import SiltaTestSupport
import Synchronization
import Testing

/// The hook's timing decisions on a fake monotonic clock. These run in the parallel
/// suite because no assertion depends on how busy the machine is; the wall-clock proof
/// that the process honours them is `HookDeadlineTests`, run isolated by
/// `scripts/verify.sh full`.
struct BriefHookDeadlineTests {
  /// Elapsed hook time that only the test advances.
  final class Elapsed: Sendable {
    private let value: Mutex<Duration>
    init(milliseconds: Int) { value = Mutex(.milliseconds(milliseconds)) }
    func set(milliseconds: Int) { value.withLock { $0 = .milliseconds(milliseconds) } }
    var deadline: BriefHookDeadline { BriefHookDeadline(elapsed: { self.value.withLock { $0 } }) }
  }

  @Test(arguments: [(0, false), (1499, false), (1500, true), (4000, true)])
  func processExpiresExactlyAtOnePointFiveSeconds(_ milliseconds: Int, _ expired: Bool) {
    #expect(Elapsed(milliseconds: milliseconds).deadline.expired == expired)
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
      runner: scripted, deadline: Elapsed(milliseconds: elapsed).deadline,
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
      runner: scripted, deadline: Elapsed(milliseconds: milliseconds).deadline,
      onTimeout: { notifications.withLock { $0 += 1 } })
    let result = try await runner.run(
      GitRequest(arguments: ["status"], directory: URL(filePath: "/acme")))
    #expect(result.termination == .timedOut)
    #expect(scripted.requests.isEmpty)
    #expect(notifications.withLock { $0 } == 1)
  }

  @Test func completionAfterTheDeadlineIsSilentAndTagged() {
    let elapsed = Elapsed(milliseconds: 1499)
    let entry = LogEntry(
      timestamp: Date(timeIntervalSince1970: 1_700_000_000),
      command: "silta brief", actor: "agent:codex:acme", exitCode: 0, milliseconds: 1499)
    let output = Rendered(stdout: "Acme context", stderr: "", exitCode: 0, errorCode: nil)
    let onTime = BriefHookCompletion(
      rendered: output, entry: entry, expired: elapsed.deadline.expired)
    #expect(onTime.rendered.stdout == "Acme context")
    #expect(!onTime.entry.warnings.contains("hook_timeout"))
    elapsed.set(milliseconds: 1500)
    let late = BriefHookCompletion(
      rendered: output, entry: entry, expired: elapsed.deadline.expired)
    #expect(late.rendered == Rendered(stdout: "", stderr: "", exitCode: 0, errorCode: nil))
    #expect(late.entry.warnings == ["hook_timeout"])
  }
}
