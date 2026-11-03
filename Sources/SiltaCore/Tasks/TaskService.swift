import Foundation
import GRDB

/// Performs task writes through the shared transaction gate and reads without mutation.
package struct TaskService: Sendable {
  let environment: SiltaEnvironment

  let workspace: String?

  let approved: String?

  /// Uses the supplied workspace, or the current selection when an operation begins.
  package init(environment: SiltaEnvironment, workspace: String? = nil, approved: String? = nil) {
    self.environment = environment
    self.workspace = workspace
    self.approved = approved
  }

  func selected() throws -> String {
    try WorkspaceSelection.resolve(workspace, in: environment.db)
  }

  /// The workspace this service's operations resolve, for the command log (spec §19);
  /// nil when it doesn't resolve, which leaves the log line untagged.
  package func resolvedWorkspace() -> String? {
    do { return try selected() } catch { return nil }
  }

  static func timestamp(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
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

  func validateClaim(_ task: TaskDetails, at date: Date, steal: Bool = false) throws {
    try Self.mutable(task)
    if !steal, let claim = try foreignClaim(task, at: date) {
      throw TaskError.claimed(task.ref, holder: claim.holder, minutes: claim.minutes)
    }
  }

  /// Another actor's claim under two hours old: the only claim `--steal` overrides.
  func foreignClaim(_ task: TaskDetails, at date: Date) throws -> (holder: String, minutes: Int)? {
    guard let holder = task.claimedBy, holder != environment.actor.description else {
      return nil
    }
    guard let raw = task.claimedAt else { throw StorageError.unavailable }
    let instant: Date
    do {
      instant = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw)
    } catch {
      throw StorageError.unavailable
    }
    let age = max(0, date.timeIntervalSince(instant))
    return age < 7200 ? (holder, Int(age / 60)) : nil
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

  static func entity(_ table: String, slug: String, workspace: Int64, in db: Database) throws
    -> Int64
  {
    guard
      let id = try Int64.fetchOne(
        db,
        sql: """
          SELECT id FROM \(table)
          WHERE workspace_id=? AND slug=?
          """, arguments: [workspace, slug])
    else { throw TaskError.notFound }
    return id
  }
}
