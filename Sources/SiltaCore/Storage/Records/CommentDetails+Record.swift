import Foundation
import GRDB

extension CommentDetails {
  init(row: Row, task: String) {
    id = row["id"]
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
    answered = kind == "question" ? false : nil
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

  /// The newest live handoff of posts in creation then id order, resolved or not.
  static func newestHandoff(_ posts: [CommentDetails]) -> CommentDetails? {
    posts.last { $0.kind == "handoff" && !$0.deleted }
  }

  static func discussion(_ task: TaskDetails, timeline: Bool, in db: Database) throws
    -> [CommentDetails]
  {
    let rows = try Row.fetchAll(
      db, sql: commentQuery + " WHERE c.task_id=? ORDER BY c.created_at,c.id", arguments: [task.id])
    var posts = rows.map { CommentDetails(row: $0, task: task.ref) }
    let answers = posts.filter { $0.kind == "answer" && !$0.deleted }
    for index in posts.indices where posts[index].kind == "question" {
      posts[index].answered = posts[index].isAnswered(by: answers)
    }
    if timeline { return posts }
    let groups = Dictionary(grouping: posts) { $0.replyTo ?? $0.ref }
    let handoff = newestHandoff(posts)?.ref
    let roots = posts.filter { post in
      guard post.replyTo == nil else { return false }
      if post.ref == handoff { return true }
      guard post.resolvedAt == nil else { return false }
      let liveReplies = groups[post.ref, default: []].contains { $0.replyTo != nil && !$0.deleted }
      return liveReplies || (post.kind != "handoff" && !post.deleted)
    }
    let ordered = roots.filter { $0.ref == handoff } + roots.filter { $0.ref != handoff }
    return ordered.flatMap { root in
      [root] + groups[root.ref, default: []].filter { $0.replyTo != nil }
    }
  }
}
