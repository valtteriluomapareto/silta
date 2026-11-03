import Foundation
import GRDB

/// Performs task writes through the shared transaction gate and reads without mutation.
package struct TaskService: Sendable {
  let environment: SiltaEnvironment

  let workspace: String?

  /// Uses the supplied workspace, or the current selection when an operation begins.
  package init(environment: SiltaEnvironment, workspace: String? = nil) {
    self.environment = environment
    self.workspace = workspace
  }

  func selected() throws -> String {
    try WorkspaceSelection.resolve(workspace, in: environment.db)
  }

  static func timestamp(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
  }

  func checked(_ text: String, allow: Bool, command: String) throws -> (String, Bool) {
    if allow { try environment.actor.requireHuman(command: command + " --allow-secret") }
    guard !SecretGuard.matches(in: text).isEmpty else { return (text, false) }
    if environment.actor.isHuman {
      guard allow else { throw SecretError(command: command, text: text) }
      return (text, false)
    }
    return (SecretGuard.redacted(text), true)
  }

  func validateClaim(_ task: TaskDetails, at date: Date, steal: Bool = false) throws {
    guard !steal, let holder = task.claimedBy, holder != environment.actor.description else {
      return
    }
    guard let raw = task.claimedAt else { throw StorageError.unavailable }
    let instant: Date
    do {
      instant = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw)
    } catch {
      throw StorageError.unavailable
    }
    let age = max(0, date.timeIntervalSince(instant))
    if age < 7200 {
      throw TaskError.claimed(task.ref, holder: holder, minutes: Int(age / 60))
    }
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
