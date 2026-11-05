import Foundation
import SiltaCore

/// Process-bound hook policy, including work done before a command can be parsed.
enum BriefHook {
  static func requested(_ arguments: [String]) -> Bool {
    let flags = SiltaMain.withoutApprovalValues(arguments).prefix { $0 != "--" }
    return SiltaMain.commandPath(arguments) == "silta brief" && flags.contains("--hook")
      && !flags.contains("--help") && !flags.contains("--version")
  }

  /// The process deadline on the monotonic clock, measured from `started`.
  static func deadline(startedAt started: ContinuousClock.Instant) -> BriefHookDeadline {
    BriefHookDeadline(elapsed: { started.duration(to: ContinuousClock.now) })
  }

  static func environment(
    _ snapshot: [String: String], deterministic: Bool, deadline: BriefHookDeadline,
    watchdog: HookWatchdog?
  ) async throws -> SiltaEnvironment {
    let git = BriefHookGitRunner(
      runner: SystemGitRunner(killAfter: 0.01, environment: snapshot),
      deadline: deadline, onTimeout: { watchdog?.timedOut() })
    return try await SiltaEnvironment.system(
      environment: snapshot, deterministic: deterministic, git: git, readBusyTimeout: 0)
  }
}
