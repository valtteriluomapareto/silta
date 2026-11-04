import Foundation
import SiltaCore

/// Process-bound hook policy, including work done before a command can be parsed.
enum BriefHook {
  static func requested(_ arguments: [String]) -> Bool {
    let flags = SiltaMain.withoutApprovalValues(arguments).prefix { $0 != "--" }
    return SiltaMain.commandPath(arguments) == "silta brief" && flags.contains("--hook")
      && !flags.contains("--help") && !flags.contains("--version")
  }

  static func watchdog() -> any DispatchSourceTimer {
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
    timer.schedule(deadline: .now() + 1.5)
    timer.setEventHandler { exit(0) }
    timer.resume()
    return timer
  }

  static func environment(
    _ snapshot: [String: String], deterministic: Bool, deadline: ContinuousClock.Instant
  ) async throws -> SiltaEnvironment {
    let git = HookGitRunner(snapshot: snapshot, deadline: deadline)
    let (actor, warnings) = try await ActorID.resolve(
      environment: snapshot, terminal: .system(), git: git,
      directory: URL(filePath: FileManager.default.currentDirectoryPath))
    var attributed = snapshot
    attributed["SILTA_ACTOR"] = actor.description
    let base = try await SiltaEnvironment.system(
      environment: attributed, deterministic: deterministic)
    return SiltaEnvironment(
      clock: base.clock, ids: base.ids, git: git, home: base.home,
      db: DatabaseStore(home: base.home.url, clock: base.clock, jitter: { 0 }, readBusyTimeout: 0),
      log: base.log, actor: actor, warnings: warnings)
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
