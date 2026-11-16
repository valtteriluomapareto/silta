public import Foundation
import SiltaCore

/// Read-only entry points for the Mac viewer, with an explicit human identity.
public struct AppReader: Sendable {
  let environment: SiltaEnvironment

  /// Configures an existing data home without opening, initializing or migrating it.
  /// `now` supplies injected time. Configuration and read failures throw `AppReadError`.
  public init(home: URL, user: String, now: @escaping @Sendable () -> Date = { Date() }) throws {
    environment = try Self.checked(home: home) {
      let clock = AppReadClock(provider: now)
      let location = try SiltaHome.resolve(
        environment: ["SILTA_HOME": home.path], userHome: home.deletingLastPathComponent())
      let actor = ActorID.human(user: user)
      return SiltaEnvironment(
        clock: clock, ids: SystemIDGenerator(), git: SystemGitRunner(environment: [:]),
        home: location, db: DatabaseStore(home: location.url, clock: clock, jitter: { 0 }),
        log: AppReadLog(), actor: actor, human: actor)
    }
  }

  /// Lists workspaces without writing selection or command logs.
  public func workspaces() throws -> [AppWorkspace] {
    try Self.checked(home: environment.home.url) {
      try checkSchema()
      return try WorkspaceSelection.list(in: environment.db).map {
        AppWorkspace(slug: $0.slug, name: $0.name)
      }
    }
  }

  /// Loads task counts once and reads the current, capped human inbox separately.
  public func snapshot(workspace: String) throws -> AppSnapshot {
    try Self.checked(home: environment.home.url) {
      try checkSchema()
      let service = TaskService(environment: environment, workspace: workspace)
      var filter = TaskFilter()
      filter.proposed = true
      let tasks = try service.list(filter).map(AppTask.init)
      let at = environment.clock.now()
      var calendar = Calendar(identifier: .iso8601)
      calendar.timeZone = .gmt
      guard let week = calendar.dateInterval(of: .weekOfYear, for: at) else {
        throw StorageError.internalMisuse
      }
      let completed = try tasks.filter { task in
        guard task.status == "done", let stamp = task.closedAt else { return false }
        guard let date = utcInstant(stamp) else { throw StorageError.corrupt }
        return date >= week.start && date <= at
      }
      let open = tasks.filter { ["todo", "doing", "review", "blocked"].contains($0.status) }
      let counts = open.reduce(into: [String: Int]()) { counts, task in
        if let app = task.app { counts[app, default: 0] += 1 }
      }
      let reviews = tasks.filter { $0.status == "review" }
      let inbox = try service.inbox(for: "me")
      return AppSnapshot(
        board: AppBoard(
          todo: tasks.filter { ["todo", "blocked"].contains($0.status) },
          doing: tasks.filter { $0.status == "doing" }, review: reviews,
          doneThisWeek: completed, proposedCount: tasks.filter { $0.status == "proposed" }.count,
          appOpenCounts: counts),
        work: AppWork(
          items: inbox.items.map(AppAttention.init), remaining: inbox.remaining,
          moreCommand: inbox.more, reviews: reviews))
    }
  }

  /// Reads task properties, parsed plan and discussion through the core service.
  public func task(_ ref: String, workspace: String) throws -> AppTask {
    try Self.checked(home: environment.home.url) {
      try checkSchema()
      return AppTask(try TaskService(environment: environment, workspace: workspace).show(ref))
    }
  }

  private func checkSchema() throws {
    if try environment.db.readerNeedsMigration() { throw AppReadError.migrationRequired }
  }

  private static func checked<Value>(home: URL, _ body: () throws -> Value) throws -> Value {
    do { return try body() } catch { throw AppReadError(error).scoped(to: home) }
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
