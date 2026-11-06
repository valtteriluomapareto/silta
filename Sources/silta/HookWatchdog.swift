import Darwin
import Foundation
import SiltaCore
import Synchronization

/// Owns the timeout record or yields exclusive logging/output ownership to completion.
/// Mutable state is mutex protected; the timer is immutable.
final class HookWatchdog: @unchecked Sendable {
  private enum Phase { case armed, completed, fired }
  private struct State {
    var timedOut = false
    var phase = Phase.armed
    var record: (path: String, data: Data)?
    var entry: LogEntry?
  }
  private let command: String
  private let flags: [String]
  private let state = Mutex(State())
  private let timer: any DispatchSourceTimer
  private let finished = DispatchSemaphore(value: 0)

  init(command: String, flags: [String]) {
    self.command = command
    self.flags = flags
    // The only process-deadline owner: a strict timer without leeway.
    timer = DispatchSource.makeTimerSource(flags: .strict, queue: .global(qos: .userInteractive))
    let budget = BriefHookDeadline.budget.components
    timer.schedule(
      deadline: .now() + Double(budget.seconds) + Double(budget.attoseconds) / 1e18,
      leeway: .nanoseconds(0))
    timer.setEventHandler { [self] in fire() }
    timer.resume()
  }

  func prepare(snapshot: [String: String], deterministic: Bool) {
    do {
      let home = try SiltaHome.resolve(environment: snapshot, deterministic: deterministic)
      let actor = try? ActorID.detect(  // Invalid attribution must not hide a failed attempt.
        environment: snapshot, terminal: .system(), session: "hook-unattributed")
      let supplied = home.permitsDeterminism ? snapshot["SILTA_NOW"].flatMap(utcInstant) : nil
      let timestamp = supplied.flatMap { $0.timeIntervalSince1970 >= 0 ? $0 : nil }
      prepare(
        home: home.url, actor: actor ?? .agent(tool: "unknown", session: "hook-unattributed"),
        at: timestamp ?? SystemClock().now())
    } catch {}  // Best-effort fallback before environment assembly succeeds.
  }

  func prepare(environment: SiltaEnvironment) {
    prepare(home: environment.home.url, actor: environment.actor, at: environment.clock.now())
  }

  private func prepare(home: URL, actor: ActorID, at timestamp: Date) {
    do {
      var entry = LogEntry(
        timestamp: timestamp, command: command,
        actor: actor.description, exitCode: 0,
        milliseconds: Int(BriefHookDeadline.budget / .milliseconds(1)))
      entry.flags = flags
      entry.errorCode = .env
      entry.warnings = ["hook_timeout"]
      let record = try SystemLog.prepared(entry)
      let directory = home.appending(path: "log")
      let path = directory.appending(path: record.name).path
      state.withLock {
        if $0.phase == .armed {
          $0.record = (path, record.data)
          $0.entry = entry
        }
      }
    } catch {}  // Timeout diagnostics must never obstruct the command.
  }

  func cancel() {
    let won = state.withLock { state in
      if state.phase == .completed { return true }
      guard state.phase == .armed else { return false }
      state.phase = .completed
      return true
    }
    if !won {
      // The timeout owner finishes its append before either thread exits the process.
      finished.wait()
      _exit(0)
    }
    timer.setEventHandler {}
    timer.cancel()
  }

  func timedOut() { state.withLock { $0.timedOut = true } }

  func finish(_ entry: LogEntry) {
    var entry = entry
    if state.withLock({ $0.timedOut }), !entry.warnings.contains("hook_timeout") {
      entry.warnings.append("hook_timeout")
    }
    let directory = state.withLock {
      $0.record.map { URL(filePath: $0.path).deletingLastPathComponent() }
    }
    let prepared = try? SystemLog.prepared(entry)  // Best-effort command diagnostics.
    cancel()
    if let directory, let prepared {
      append(path: directory.appending(path: prepared.name).path, data: prepared.data)
    }
  }

  /// Completes a failed attempt even when input or environment assembly never succeeded.
  func failed(milliseconds: Int) {
    guard var entry = state.withLock({ $0.entry }) else { return }
    entry.milliseconds = milliseconds
    entry.errorCode = .env
    entry.warnings = ["hook_failed"]
    finish(entry)
  }

  private func append(path: String, data: Data) {
    let url = URL(filePath: path)
    try? SystemLog.append(  // Best-effort diagnostics skip unsafe targets.
      directory: url.deletingLastPathComponent(), name: url.lastPathComponent, data: data)
  }

  private func fire() {
    let owned = state.withLock { state -> (Bool, (path: String, data: Data)?) in
      guard state.phase == .armed else { return (false, nil) }
      state.phase = .fired
      return (true, state.record)
    }
    guard owned.0 else { return }
    if let record = owned.1 {
      append(path: record.path, data: record.data)
    }
    finished.signal()
    _exit(0)
  }
}
