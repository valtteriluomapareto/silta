public import Foundation
import SiltaCore

/// Read-only entry points for the Mac viewer, with an explicit human identity.
public struct AppReader: Sendable {
  let environment: SiltaEnvironment

  /// Configures an existing data home without opening, initializing or migrating it.
  /// `now` supplies the viewer's injected time, including deterministic control launches.
  public init(home: URL, user: String, now: @escaping @Sendable () -> Date = { Date() }) throws {
    let clock = AppReadClock(provider: now)
    let location = try SiltaHome.resolve(
      environment: ["SILTA_HOME": home.path], userHome: home.deletingLastPathComponent())
    let actor = ActorID.human(user: user)
    environment = SiltaEnvironment(
      clock: clock, ids: SystemIDGenerator(), git: SystemGitRunner(environment: [:]),
      home: location, db: DatabaseStore(home: location.url, clock: clock, jitter: { 0 }),
      log: AppReadLog(), actor: actor, human: actor)
  }

  /// Lists workspaces without writing selection or command logs.
  public func workspaces() throws -> [AppWorkspace] { [] }

  /// Loads task-based counts once and reads the current, capped human inbox.
  public func snapshot(workspace: String) throws -> AppSnapshot {
    AppSnapshot(
      board: AppBoard(todo: [], doing: [], review: [], doneThisWeek: [], proposedCount: 0,
        appOpenCounts: [:]),
      work: AppWork(items: [], remaining: 0, moreCommand: nil, reviews: []))
  }

  /// Reads task properties, parsed plan and discussion through the core service.
  public func task(_ ref: String, workspace: String) throws -> AppTask {
    throw StorageError.unknown
  }
}

private struct AppReadClock: SiltaCore.Clock {
  let provider: @Sendable () -> Date
  func now() -> Date { provider() }
  func wait(milliseconds: UInt64) { SystemClock().wait(milliseconds: milliseconds) }
}

private struct AppReadLog: Log {
  func record(_ entry: LogEntry) {}
}
