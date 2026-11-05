import Foundation
import SiltaCore
import SiltaTestSupport
import Synchronization
import Testing

struct BriefHookGitRunnerTests {
  @Test(arguments: [GitTermination.timedOut, .exit(0), .exit(128), .signal(9)])
  func childDeadlineNotifiesWithoutWaitingForProcessDeadline(_ termination: GitTermination)
    async throws
  {
    let request = GitRequest(arguments: ["status"], directory: URL(filePath: "/acme"))
    let bounded = GitRequest(
      arguments: request.arguments, directory: request.directory,
      timeout: 1, lazyFetch: false)
    let scripted = ScriptedGitRunner(script: [(bounded, .success(.init(termination: termination)))])
    let notifications = Mutex(0)
    let runner = BriefHookGitRunner(
      runner: scripted, deadline: BriefHookDeadlineTests.deadline(0),
      onTimeout: { notifications.withLock { $0 += 1 } })
    let result = try await runner.run(request)
    #expect(result.termination == termination)
    #expect(scripted.requests == [bounded])
    #expect(notifications.withLock { $0 } == (termination == .timedOut ? 1 : 0))
  }

  @Test func expiredBudgetNotifiesWithoutSpawning() async throws {
    let scripted = ScriptedGitRunner(script: [])
    let notifications = Mutex(0)
    let runner = BriefHookGitRunner(
      runner: scripted, deadline: BriefHookDeadlineTests.deadline(1000),
      onTimeout: { notifications.withLock { $0 += 1 } })
    let result = try await runner.run(
      .init(arguments: ["status"], directory: URL(filePath: "/acme")))
    #expect(result.termination == .timedOut)
    #expect(scripted.requests.isEmpty)
    #expect(notifications.withLock { $0 } == 1)
  }
}

extension BriefHookGitRunnerTests {
  @Test(arguments: [Int32(0), 2])
  func completionIsSilentOnErrorsAndKeepsOutput(_ exitCode: Int32) {
    let original = LogEntry(
      timestamp: Date(timeIntervalSince1970: 1_700_000_000),
      command: "silta brief", actor: "agent:codex:acme", exitCode: exitCode, milliseconds: 1499)
    var diagnosed = original
    diagnosed.errorCode = .notFound
    let output = Rendered(
      stdout: "Acme context", stderr: "warning", exitCode: exitCode, errorCode: nil)
    let completed = BriefHookCompletion(rendered: output, entry: original)
    #expect(!completed.entry.warnings.contains("hook_timeout"))
    #expect(completed.entry.exitCode == 0)
    #expect(completed.rendered.exitCode == 0)
    #expect(completed.rendered.stderr.isEmpty)
    #expect(completed.rendered.stdout == (exitCode != 0 ? "" : "Acme context"))
    let failed = BriefHookCompletion(rendered: output, entry: diagnosed)
    #expect(failed.entry.errorCode == .notFound)
    #expect(failed.entry.exitCode == 0)
  }
}
