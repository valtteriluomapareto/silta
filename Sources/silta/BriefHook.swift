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
    _ snapshot: [String: String], deterministic: Bool, deadline: ContinuousClock.Instant,
    watchdog: HookWatchdog?
  ) async throws -> SiltaEnvironment {
    let git = BriefHookGitRunner(
      runner: SystemGitRunner(killAfter: 0.01, environment: snapshot),
      remaining: {
        let duration = ContinuousClock().now.duration(to: deadline).components
        // Utility workers can coalesce timeout wakeups; reserve time to terminate and reap.
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18 - 0.5
      }, onTimeout: { watchdog?.timedOut() })
    return try await SiltaEnvironment.system(
      environment: snapshot, deterministic: deterministic, git: git, readBusyTimeout: 0)
  }
}
