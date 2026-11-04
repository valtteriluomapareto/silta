import Foundation
import GRDB

extension CommentDetails {
  init(row: Row, task: String) {
    ref = task + "/\(row["seq"] as Int)"
    kind = row["kind"]
    deleted = row["deleted_at"] as String? != nil
    body = deleted ? "[deleted]" : row["body_md"]
    actor = row["actor"]
    replyTo = (row["root_seq"] as Int?).map { task + "/\($0)" }
    resolvedAt = row["root_resolved_at"] ?? row["resolved_at"]
    resolvedBy = row["root_resolved_by"] ?? row["resolved_by"]
    createdAt = row["created_at"]
    let raw: String = row["mentions"]
    let data = Data(raw.utf8)
    mentions = (try? JSONDecoder().decode([String].self, from: data)) ?? []  // newer encodings
    accepted = row["accepted"]
    source = (row["source"] as String?).map { "note:" + $0 }
  }
}

extension TaskService {
  static let commentQuery = """
    SELECT c.*,(SELECT to_ext FROM link WHERE from_kind='comment' AND from_id=c.id
      AND rel='cites' AND to_kind='note' ORDER BY id LIMIT 1) AS source,
    r.seq AS root_seq,r.resolved_at AS root_resolved_at,r.resolved_by AS root_resolved_by
    FROM comment c LEFT JOIN comment r ON r.id=c.thread_id AND r.task_id=c.task_id
    """

  static func discussion(_ task: TaskDetails, timeline: Bool, in db: Database) throws
    -> [CommentDetails]
  {
    let rows = try Row.fetchAll(
      db, sql: commentQuery + " WHERE c.task_id=? ORDER BY c.created_at,c.id", arguments: [task.id])
    if timeline { return rows.map { CommentDetails(row: $0, task: task.ref) } }
    let groups = Dictionary(grouping: rows) { ($0["thread_id"] as Int64?) ?? ($0["id"] as Int64) }
    let latest = rows.last {
      $0["kind"] as String == "handoff" && $0["deleted_at"] as String? == nil
    }
    let handoff = latest.map { ($0["thread_id"] as Int64?) ?? ($0["id"] as Int64) }
    let roots = rows.filter { row in
      guard row["thread_id"] as Int64? == nil else { return false }
      let id: Int64 = row["id"]
      if id == handoff { return true }
      guard row["resolved_at"] as String? == nil else { return false }
      let liveReplies = groups[id, default: []].contains {
        $0["thread_id"] as Int64? != nil && $0["deleted_at"] as String? == nil
      }
      return liveReplies
        || (row["kind"] as String != "handoff" && row["deleted_at"] as String? == nil)
    }
    let ordered =
      roots.filter { $0["id"] as Int64 == handoff } + roots.filter { $0["id"] as Int64 != handoff }
    return ordered.flatMap { root in
      let replies = groups[root["id"] as Int64, default: []].filter {
        $0["thread_id"] as Int64? != nil
      }
      return ([root] + replies).map { CommentDetails(row: $0, task: task.ref) }
    }
  }
}
