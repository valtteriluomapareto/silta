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
      runner: scripted, remaining: { 1 },
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
      runner: scripted, remaining: { 0 },
      onTimeout: { notifications.withLock { $0 += 1 } })
    let result = try await runner.run(
      .init(arguments: ["status"], directory: URL(filePath: "/acme")))
    #expect(result.termination == .timedOut)
    #expect(scripted.requests.isEmpty)
    #expect(notifications.withLock { $0 } == 1)
  }
}
