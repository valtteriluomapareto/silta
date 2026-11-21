public import Foundation
import SiltaCore

/// Read-only entry points for the Mac viewer, with an explicit human identity.
public struct AppReader: Sendable {
  let environment: SiltaEnvironment

  /// Configures an existing data home without opening, initializing or migrating it.
  /// `userHome` identifies the default `.silta` location; `now` supplies injected time.
  /// Configuration and read failures throw `AppReadError`.
  public init(
    home: URL, user: String, userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
    now: @escaping @Sendable () -> Date = { Date() }
  ) throws {
    environment = try Self.checked(home: home) {
      let clock = AppReadClock(provider: now)
      let location = try SiltaHome.resolve(
        environment: ["SILTA_HOME": home.path], userHome: userHome)
      let actor = ActorID.human(user: user)
      return SiltaEnvironment(
        clock: clock, ids: SystemIDGenerator(), git: SystemGitRunner(environment: [:]),
        home: location, db: DatabaseStore(home: location.url, clock: clock, jitter: { 0 }),
        log: AppReadLog(), actor: actor, human: actor)
    }
  }

  /// The human the app acts as, such as `human:acme`.
  public var human: String { environment.human.description }

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
      let tasks = try service.withResumeState(service.list(filter)).map {
        AppTask($0, submission: $0.status == "review" ? try service.reviewSubmission($0.ref) : nil)
      }
      let at = environment.clock.now()
      var calendar = Calendar(identifier: .iso8601)
      calendar.timeZone = .gmt
      guard let week = calendar.dateInterval(of: .weekOfYear, for: at)
      else {
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
      let blockedRefs = inbox.items.filter { ["due", "replan"].contains($0.kind) }
        .flatMap { $0.tasks ?? [] }.map(\.ref)
      let unmet = try service.unmetBlockers(Array(Set(blockedRefs)))
      let questions = try service.questionInbox().map(AppAttention.init)
      return AppSnapshot(
        board: AppBoard(
          todo: tasks.filter { ["todo", "blocked"].contains($0.status) },
          doing: tasks.filter { $0.status == "doing" }, review: reviews,
          doneThisWeek: completed, proposals: tasks.filter { $0.status == "proposed" },
          questions: questions, appOpenCounts: counts),
        work: AppWork(
          items: inbox.items.map { AppAttention($0).withUnmet(unmet) },
          remaining: inbox.remaining,
          moreCommand: inbox.more, reviews: reviews))
    }
  }

  /// Reads every current human inbox entry past the cap, proposals older than 14 days
  /// included, as `inbox --for me --all` does. The snapshot keeps the capped read for the
  /// waiting badge.
  public func fullInbox(workspace: String) throws -> [AppAttention] {
    try Self.checked(home: environment.home.url) {
      try checkSchema()
      let service = TaskService(environment: environment, workspace: workspace)
      return try service.inbox(for: "me", all: true).items.map(AppAttention.init)
    }
  }

  /// Reads task properties, parsed plan, discussion, relatives and blocker states through
  /// the core service in one read.
  public func task(_ ref: String, workspace: String) throws -> AppTask {
    try Self.checked(home: environment.home.url) {
      try checkSchema()
      let service = TaskService(environment: environment, workspace: workspace)
      let inspection = try service.inspect(ref)
      let task = inspection.task
      return AppTask(
        task, submission: task.status == "review" ? try service.reviewSubmission(ref) : nil,
        resolved: inspection.resolved, detail: AppTaskDetail(inspection))
    }
  }

  /// Reads the typed workspace map without loading YAML or mutating storage.
  public func workspaceMap(workspace: String) throws -> AppWorkspaceMap {
    try Self.checked(home: environment.home.url) {
      try checkSchema()
      let map = try WorkspaceMap.read(workspace: workspace, in: environment.db)
      return AppWorkspaceMap(
        apps: map.apps.map {
          AppMapApp(
            slug: $0.slug, name: $0.name, repo: $0.repo, ref: $0.ref,
            productionRef: $0.productionRef, subpath: $0.subpath, summary: $0.summary,
            lifecycle: $0.lifecycle, attachment: "app:" + $0.slug)
        },
        services: map.services.map {
          AppMapService(
            slug: $0.slug, name: $0.name,
            summary: $0.summary, attachment: $0.attachment)
        },
        connections: map.connections.map {
          AppConnection(
            attachment: $0.attachment,
            source: $0.source, target: $0.target, kind: $0.kind, summary: $0.summary,
            codeReferences: $0.codeReferences)
        })
    }
  }

  /// Opens one persistent read connection without initializing or migrating storage.
  public func makeChangeProbe() throws -> AppChangeProbe {
    try Self.checked(home: environment.home.url) {
      let core = try DatabaseChangeProbe(store: environment.db)
      if try core.sample().needsMigration { throw AppReadError.migrationRequired }
      return AppChangeProbe(core: core, home: environment.home.url)
    }
  }

  func checkSchema() throws {
    if try environment.db.readerNeedsMigration() { throw AppReadError.migrationRequired }
  }

  static func checked<Value>(home: URL, _ body: () throws -> Value) throws -> Value {
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
