import Foundation
import GRDB

extension CommentDetails {
  init(row: Row, task: String) throws {
    ref = task + "/\(row["seq"] as Int)"
    kind = row["kind"]
    deleted = row["deleted_at"] as String? != nil
    body = deleted ? "[deleted]" : row["body_md"]
    actor = row["actor"]
    mentions =
      try deleted
      ? [] : JSONDecoder().decode([String].self, from: Data((row["mentions"] as String).utf8))
    replyTo = (row["root_seq"] as Int?).map { task + "/\($0)" }
    source = deleted ? nil : (row["note"] as String?).map { "note:" + $0 }
    accepted = row["accepted"]
    resolvedAt = row["root_resolved_at"] ?? row["resolved_at"]
    resolvedBy = row["root_resolved_by"] ?? row["resolved_by"]
    createdAt = row["created_at"]
  }
}

extension TaskService {
  static let commentQuery = """
    SELECT c.*,r.seq AS root_seq,r.resolved_at AS root_resolved_at,
      r.resolved_by AS root_resolved_by,
      (SELECT to_ext FROM link WHERE from_kind='comment' AND from_id=c.id AND to_kind='note'
        ORDER BY id LIMIT 1) AS note
    FROM comment c LEFT JOIN comment r ON r.id=c.thread_id AND r.task_id=c.task_id
    """

  static func discussion(_ task: TaskDetails, timeline: Bool, in db: Database) throws
    -> [CommentDetails]
  {
    let rows = try Row.fetchAll(
      db, sql: commentQuery + " WHERE c.task_id=? ORDER BY c.created_at,c.id", arguments: [task.id])
    if timeline { return try rows.map { try CommentDetails(row: $0, task: task.ref) } }
    let latest = rows.last {
      $0["kind"] as String == "handoff" && $0["deleted_at"] as String? == nil
    }
    let handoff = latest.map { ($0["thread_id"] as Int64?) ?? ($0["id"] as Int64) }
    let roots = rows.filter { row in
      guard row["thread_id"] as Int64? == nil else { return false }
      let id: Int64 = row["id"]
      if id == handoff { return true }
      guard row["kind"] as String != "handoff", row["resolved_at"] as String? == nil else {
        return false
      }
      return row["deleted_at"] as String? == nil
        || rows.contains { $0["thread_id"] as Int64? == id && $0["deleted_at"] as String? == nil }
    }
    let ordered =
      roots.filter { $0["id"] as Int64 == handoff } + roots.filter { $0["id"] as Int64 != handoff }
    return try ordered.flatMap { root in
      try ([root] + rows.filter { $0["thread_id"] as Int64? == (root["id"] as Int64) })
        .map { try CommentDetails(row: $0, task: task.ref) }
    }
  }
}
