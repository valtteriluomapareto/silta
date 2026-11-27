package import Foundation
import GRDB

/// Performs task writes through the shared transaction gate and reads without mutation.
package struct TaskService: Sendable {
  let environment: SiltaEnvironment

  let workspace: String?

  let approved: String?

  let bodyFlag: String?

  let retryBodyFlag: String?

  let referenceHints: Bool

  /// Uses the supplied workspace, or the current selection when an operation begins.
  /// `bodyFlag` is the body flag the command was given, `-m <text>` or `-F <file>`,
  /// which approval rows name without the body (spec §11). `retryBodyFlag` tells
  /// the caller how to resupply the input without revealing it.
  package init(
    environment: SiltaEnvironment, workspace: String? = nil, approved: String? = nil,
    bodyFlag: String? = nil, retryBodyFlag: String? = nil, referenceHints: Bool = false
  ) {
    self.environment = environment
    self.workspace = workspace
    self.approved = approved
    self.bodyFlag = bodyFlag
    self.retryBodyFlag = retryBodyFlag ?? bodyFlag
    self.referenceHints = referenceHints
  }

  /// `command` as an approval row records it: with the body flag passed, never the body.
  func audited(_ command: String) -> String {
    command + (bodyFlag.map { " " + $0 } ?? "")
  }

  /// Keeps a retry tied to the workspace selected for the attempted write.
  func scopedCommand(_ command: String, workspace: String) -> String {
    workspaceCommand(command, workspace: workspace)
  }

  func selected() throws -> String {
    try WorkspaceSelection.resolve(
      workspace, in: environment.db, prepared: environment.workspaceSelection)
  }

  /// The workspace this service's operations resolve, for the command log (spec §19);
  /// nil when it doesn't resolve, which leaves the log line untagged.
  package func resolvedWorkspace() -> String? {
    do { return try selected() } catch { return nil }
  }

  static func timestamp(_ date: Date) -> String {
    utcTimestamp(date)
  }

  func checked(_ text: String, allow: Bool, command: String) throws -> (String, Bool) {
    if allow {
      try environment.actor.requireHuman(command: command + " --allow-secret", approved: approved)
    }
    guard !SecretGuard.matches(in: text).isEmpty else { return (text, false) }
    if allow { return (text, false) }
    if environment.actor.isHuman {
      throw SecretError(command: command, text: text)
    }
    return (SecretGuard.redacted(text), true)
  }

  func approval(required: Bool, command: String) throws -> HumanApproval? {
    try required ? environment.actor.requireHuman(command: command, approved: approved) : nil
  }

  func validateClaim(
    _ task: TaskDetails, workspace: String, at date: Date, steal: Bool = false
  ) throws {
    try Self.mutable(task)
    if !steal, let claim = try foreignClaim(task, at: date) {
      throw TaskError.claimed(
        task.ref, holder: claim.holder, minutes: claim.minutes, human: environment.actor.isHuman,
        workspace: workspace)
    }
  }

  /// Shared expiry boundary for claim ownership and diagnostics.
  package static let claimDuration: TimeInterval = 2 * 60 * 60

  /// Another actor's claim under two hours old: the only claim `--steal` overrides.
  func foreignClaim(_ task: TaskDetails, at date: Date) throws -> (holder: String, minutes: Int)? {
    guard let holder = task.claimedBy, holder != environment.actor.description else {
      return nil
    }
    guard let raw = task.claimedAt else { throw StorageError.corrupt }
    let expiry = try Self.claimExpiry(raw)
    let age = max(0, date.timeIntervalSince(expiry) + Self.claimDuration)
    return date < expiry ? (holder, Int(age / 60)) : nil
  }

  /// When a claim with this heartbeat stops protecting its task; an unreadable heartbeat
  /// is corrupt storage.
  package static func claimExpiry(_ claimedAt: String) throws -> Date {
    do {
      return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(claimedAt)
        .addingTimeInterval(claimDuration)
    } catch {
      throw StorageError.corrupt
    }
  }

  static func mutable(_ task: TaskDetails) throws {
    if let ref = task.externalRef { throw TaskError.promoted(task.ref, external: ref) }
  }

  func event(
    _ kind: String, task: Int64, body: String?, at date: Date, in tx: StorageTransaction
  ) throws {
    try tx.database.execute(
      sql: """
        INSERT INTO task_event(task_id,actor,kind,body,created_at)
        VALUES(?,?,?,?,?)
        """, arguments: [task, environment.actor.description, kind, body, Self.timestamp(date)])
  }

  func changed(
    _ task: Int64, kind: String, body: String?, redacted: Bool = false,
    at date: Date, in tx: StorageTransaction
  ) throws {
    try event(kind, task: task, body: body, at: date, in: tx)
    if redacted { try event("secret_redacted", task: task, body: nil, at: date, in: tx) }
    try tx.recordChange(kind: "task", rowID: task)
  }

  func receipt(_ task: TaskDetails, warnings: [OutputWarning] = []) -> TaskResult {
    TaskResult(ref: task.ref, status: task.status, warnings: warnings)
  }

  static func workspaceID(_ slug: String, in db: Database) throws -> Int64 {
    guard
      let id = try Int64.fetchOne(
        db, sql: "SELECT id FROM workspace WHERE slug=?", arguments: [slug])
    else { throw WorkspaceError.notFound }
    return id
  }

  /// Runs `body`, naming a task it doesn't find by `role`: "parent task AC-9".
  static func named<T>(_ role: String, _ body: () throws -> T) throws -> T {
    do { return try body() } catch TaskError.notFound(let what) {
      throw TaskError.notFound(role + " " + what)
    }
  }

  static func entity(_ table: String, slug: String, workspace: Int64, in db: Database) throws
    -> Int64
  {
    if let kind = WorkspaceSlugs.Kind(rawValue: table) {
      return try namedSlug(kind, slug, workspace: workspace, in: db).id
    }
    guard
      let id = try Int64.fetchOne(
        db,
        sql: """
          SELECT id FROM \(table)
          WHERE workspace_id=? AND slug=CAST(? AS TEXT)
          """, arguments: [workspace, Data(slug.utf8)])
    else { throw TaskError.notFound(table + " " + slug) }
    return id
  }
  static func namedSlug(
    _ kind: WorkspaceSlugs.Kind, _ slug: String, workspace: Int64, in db: Database
  )
    throws -> WorkspaceSlugs.Resolved
  {
    guard let selected = try WorkspaceSlugs.resolve(kind, slug, workspace: workspace, in: db)
    else { throw TaskError.notFound(kind.rawValue + " " + slug) }
    return selected
  }

}
