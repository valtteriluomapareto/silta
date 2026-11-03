import Foundation
import GRDB

extension TaskService {
  static func blocker(_ raw: String, workspace: String, in db: Database) throws -> TaskLinkTarget {
    if raw.hasPrefix("ext:") {
      guard let party = TaskBlock.party(raw) else {
        throw TaskError.invalid(
          "Use ext:<party>: 1–64 lowercase letters, digits or hyphens, with alphanumeric ends.")
      }
      return TaskLinkTarget(kind: "ext", external: party)
    }
    if raw.hasPrefix("url:") { return try TaskLinkTarget.url(raw) }
    guard !raw.contains(":") || raw.hasPrefix("task:"), !raw.contains("/") else {
      throw TaskError.invalid("Blockers must be task, ext:party or url:http(s) references.")
    }
    return TaskLinkTarget(kind: "task", id: try lookup(raw, workspace: workspace, in: db).id)
  }

  static func blockLinks(_ task: TaskDetails, in db: Database) throws -> [Row] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT link.*
        FROM link
        WHERE workspace_id=? AND from_kind='task' AND from_id=? AND rel='blocked_by'
        ORDER BY to_kind,to_id,to_ext
        """, arguments: [task.workspaceID, task.id])
  }

  static func waiting(_ task: TaskDetails, at date: Date, in db: Database) throws -> TaskWaiting? {
    guard task.status == "blocked" else { return nil }
    let links = try blockLinks(task, in: db)
    let events = try Row.fetchAll(
      db,
      sql: """
        SELECT body,created_at
        FROM task_event
        WHERE task_id=? AND kind='block'
          AND id>COALESCE((SELECT MAX(id) FROM task_event WHERE task_id=? AND kind='unblock'),0)
        ORDER BY id
        """, arguments: [task.id, task.id])
    guard let first = events.first, let last = events.last else { throw StorageError.unavailable }
    let began: Date
    do {
      began = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(
        first["created_at"])
    } catch { throw StorageError.unavailable }
    let latest = try TaskBlockEvent.decode(last["body"])
    var ready = !links.isEmpty
    var dropped: [String] = []
    var on: [String] = []
    for link in links {
      let ref = try TaskLinkTarget.render(link, in: db)
      on.append((link["to_kind"] as String) == "url" ? SecretGuard.redacted(ref) : ref)
      if (link["to_kind"] as String) != "task" {
        ready = false
        continue
      }
      guard
        let blocker = try Row.fetchOne(
          db, sql: "SELECT status,external_ref FROM task WHERE id=?",
          arguments: [link["to_id"] as Int64])
      else { throw StorageError.unavailable }
      if (blocker["status"] as String) == "dropped" { dropped.append(ref) }
      if (blocker["status"] as String) != "done" || (blocker["external_ref"] as String?) != nil {
        ready = false
      }
    }
    return TaskWaiting(
      on: on, ageDays: Int(max(0, date.timeIntervalSince(began)) / 86400),
      why: SecretGuard.redacted(latest.why), ready: ready, dropped: dropped)
  }

  static func matchesBlocker(_ raw: String?, task: TaskDetails, workspace: String, in db: Database)
    throws -> Bool
  {
    guard let raw else { return true }
    let target = try blocker(raw, workspace: workspace, in: db)
    return try blockLinks(task, in: db).contains {
      ($0["to_kind"] as String) == target.kind && ($0["to_id"] as Int64?) == target.id
        && ($0["to_ext"] as String?) == target.external
    }
  }

  static func safeEvent(_ row: Row) throws -> TaskEvent {
    let kind: String = row["kind"]
    let body: String? = row["body"]
    let safe: String?
    if kind == "block", let body {
      safe = try TaskBlockEvent.decode(body).safeBody()
    } else if kind == "unblock" {
      safe = body.map(SecretGuard.redacted)
    } else {
      safe = body
    }
    return TaskEvent(kind: kind, actor: row["actor"], body: safe, at: row["created_at"])
  }
}
