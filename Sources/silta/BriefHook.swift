import Foundation
import SiltaCore

/// Process-bound hook policy, including work done before a command can be parsed.
enum BriefHook {
  static func requested(_ arguments: [String]) -> Bool {
    let flags = SiltaMain.withoutApprovalValues(arguments).prefix { $0 != "--" }
    return SiltaMain.commandPath(arguments) == "silta brief" && flags.contains("--hook")
      && !flags.contains("--help") && !flags.contains("--version")
  }

  static func environment(
    _ snapshot: [String: String], deterministic: Bool, deadline: ContinuousClock.Instant
  ) async throws -> SiltaEnvironment {
    let git = HookGitRunner(snapshot: snapshot, deadline: deadline)
    return try await SiltaEnvironment.system(
      environment: snapshot, deterministic: deterministic, git: git, readBusyTimeout: 0)
  }
}

/// Every child gets the remaining process budget, with time reserved to terminate and reap it.
private struct HookGitRunner: GitRunner {
  let system: SystemGitRunner
  let deadline: ContinuousClock.Instant

  init(snapshot: [String: String], deadline: ContinuousClock.Instant) {
    system = SystemGitRunner(killAfter: 0.01, environment: snapshot)
    self.deadline = deadline
  }

  func run(_ request: GitRequest) async throws -> GitResult {
    let duration = ContinuousClock().now.duration(to: deadline).components
    // Utility workers can coalesce timeout wakeups; reserve time to terminate and reap.
    let remaining = Double(duration.seconds) + Double(duration.attoseconds) / 1e18 - 0.5
    guard remaining > 0 else { return GitResult(termination: .timedOut) }
    return try await system.run(
      GitRequest(
        arguments: request.arguments,
        directory: request.directory, timeout: min(request.timeout, remaining), lazyFetch: false))
  }
}
