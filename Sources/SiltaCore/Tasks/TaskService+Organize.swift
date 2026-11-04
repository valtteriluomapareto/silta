import Foundation
import GRDB

extension TaskService {
  static func validatePriority(_ priority: Int) throws {
    guard (1...3).contains(priority) else { throw TaskError.invalid("Priority must be 1, 2 or 3.") }
  }

  /// Sets an explicit archive choice; age-based reads never change storage.
  package func archive(_ ref: String, keep: Bool = false) throws -> TaskResult {
    let slug = try selected()
    let at = environment.clock.now()
    return try environment.db.write { tx in
      let task = try Self.lookup(ref, workspace: slug, in: tx.database)
      try validateClaim(task, workspace: slug, at: at)
      try tx.database.execute(
        sql: """
          UPDATE task
          SET archive_override=?,updated_at=?,
            claimed_at=CASE WHEN claimed_by=? THEN ? ELSE claimed_at END
          WHERE id=?
          """,
        arguments: [
          keep ? "kept" : "archived", Self.timestamp(at), environment.actor.description,
          Self.timestamp(at), task.id,
        ])
      try changed(task.id, kind: "field", body: keep ? "kept" : "archived", at: at, in: tx)
      return receipt(task)
    }
  }

  static func isArchived(_ task: TaskDetails, at date: Date, in db: Database) throws -> Bool {
    if let choice = task.archiveOverride { return choice == "archived" }
    guard ["done", "dropped"].contains(task.status), let closed = task.closedAt else {
      return false
    }
    let instant: Date
    do {
      instant = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(closed)
    } catch { throw StorageError.unavailable }
    let days = try WorkspaceSettings.read(workspaceID: task.workspaceID, in: db).archiveAfterDays
    return instant < date.addingTimeInterval(-Double(days) * 86400)
  }

  /// Records tracker ownership and releases the local claim without changing status.
  /// A proposal needs triage and a blocked task an unblock first, so no proposal or
  /// block is left behind where nothing can change it.
  /// State refusals come before the human's go-ahead is asked for, so a yes is never spent
  /// on a promotion that can't happen.
  package func promote(_ ref: String, external: String) throws -> TaskResult {
    let command = "silta task promote " + shellWord(ref) + " --ext " + shellWord(external)
    guard
      external.wholeMatch(of: /ado:[1-9][0-9]*/) != nil
        || external.wholeMatch(of: /gh:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[1-9][0-9]*/) != nil
        || external.wholeMatch(of: /jira:[A-Z][A-Z0-9]*-[1-9][0-9]*/) != nil
    else { throw TaskError.invalid("Use ado:<id>, gh:<owner>/<repo>#<id> or jira:<KEY>-<id>.") }
    let at = environment.clock.now()
    let slug = try selected()
    try promotable(try show(ref), workspace: slug, at: at)
    let approval = try approval(required: true, command: command)
    return try environment.db.write { tx in
      let task = try Self.decorate(
        Self.lookup(ref, workspace: slug, in: tx.database), at: at, in: tx.database)
      try promotable(task, workspace: slug, at: at)
      try tx.database.execute(
        sql: """
          UPDATE task
          SET external_ref=?,claimed_by=NULL,claimed_at=NULL,updated_at=?
          WHERE id=?
          """, arguments: [external, Self.timestamp(at), task.id])
      try changed(task.id, kind: "promote", body: external, at: at, in: tx)
      try approval?.record(
        command: command, workspace: slug,
        identity: (environment.ids, at), in: tx)
      return receipt(task)
    }
  }

  private func promotable(_ task: TaskDetails, workspace: String, at date: Date) throws {
    try validateClaim(task, workspace: workspace, at: date)
    if task.status == "proposed" {
      throw TaskError.proposal(task.ref, human: environment.actor.isHuman)
    }
    if task.status == "blocked" {
      throw TaskError.blockedPromotion(task.ref, ready: task.waiting?.ready == true)
    }
  }
}
