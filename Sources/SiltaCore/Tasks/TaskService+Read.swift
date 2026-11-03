import Foundation
import GRDB

extension TaskService {
  static let statuses = ["proposed", "todo", "doing", "review", "blocked", "done", "dropped"]

  static let query = """
    SELECT task.*,workspace.task_prefix,app.slug AS app_slug,repo_path.path AS repo_path
    FROM task
    JOIN workspace ON workspace.id=task.workspace_id
    LEFT JOIN app ON app.id=task.app_id
    LEFT JOIN repo_path ON repo_path.repo_id=app.repo_id
    """

  /// Reads the selected workspace backlog and always retains the caller's proposals.
  package func list(_ filter: TaskFilter = TaskFilter()) throws -> [TaskDetails] {
    if let status = filter.status, !Self.statuses.contains(status) {
      throw TaskError.invalid("Unknown task status.")
    }
    let slug = try selected()
    return try environment.db.read { db in
      let id = try Self.workspaceID(slug, in: db)
      return try Row.fetchAll(
        db,
        sql: Self.query + """
          \nWHERE task.workspace_id=?
          ORDER BY task.seq
          """, arguments: [id]
      ).map { try Self.decorate(TaskDetails(row: $0), in: db) }
        .filter {
          let visible =
            $0.status != "proposed" || filter.proposed || environment.actor.isHuman
            || $0.createdBy == environment.actor.description
          return visible && (filter.status == nil || filter.status == $0.status)
            && (filter.app == nil || filter.app == $0.app)
            && (filter.topic == nil
              || $0.links.contains {
                $0.target == "topic:" + (filter.topic ?? "") && $0.rel == "about"
              })
            && (!filter.mine || $0.createdBy == environment.actor.description
              || $0.claimedBy == environment.actor.description)
        }
    }
  }

  /// Reads a task and optionally its event history without creating storage.
  package func show(_ ref: String, timeline: Bool = false) throws -> TaskDetails {
    let slug = try selected()
    return try environment.db.read { db in
      var task = try Self.decorate(Self.lookup(ref, workspace: slug, in: db), in: db)
      if timeline {
        task.timeline = try Row.fetchAll(
          db,
          sql: """
            SELECT kind,actor,body,created_at
            FROM task_event
            WHERE task_id=?
            ORDER BY id
            """, arguments: [task.id]
        ).map {
          TaskEvent(kind: $0["kind"], actor: $0["actor"], body: $0["body"], at: $0["created_at"])
        }
      }
      return task
    }
  }

  static func lookup(_ ref: String, workspace: String, in db: Database) throws -> TaskDetails {
    let raw = ref.hasPrefix("task:") ? String(ref.dropFirst(5)) : ref
    guard
      let workspaceRow = try Row.fetchOne(
        db, sql: "SELECT id,task_prefix FROM workspace WHERE slug=?", arguments: [workspace])
    else { throw WorkspaceError.notFound }
    let prefix = (workspaceRow["task_prefix"] as String) + "-"
    guard raw.hasPrefix(prefix), let seq = Int64(raw.dropFirst(prefix.count)), seq > 0,
      raw == prefix + String(seq)
    else { throw TaskError.invalid("Use a canonical task reference from this workspace.") }
    guard
      let row = try Row.fetchOne(
        db,
        sql: query + """
          \nWHERE task.workspace_id=? AND task.seq=?
          """, arguments: [workspaceRow["id"] as Int64, seq])
    else { throw TaskError.notFound }
    return TaskDetails(row: row)
  }

  static func decorate(_ original: TaskDetails, in db: Database) throws -> TaskDetails {
    var task = original
    task.links = try Row.fetchAll(
      db,
      sql: """
        SELECT link.rel,link.to_kind,link.to_ext,app.slug AS app_slug,topic.slug AS topic_slug
        FROM link
        LEFT JOIN app ON link.to_kind='app' AND app.id=link.to_id
        LEFT JOIN topic ON link.to_kind='topic' AND topic.id=link.to_id
        WHERE link.from_kind='task' AND link.from_id=? AND link.workspace_id=?
        ORDER BY link.id
        """, arguments: [task.id, task.workspaceID]
    ).map { row in
      let kind: String = row["to_kind"]
      let target: String = row["to_ext"] ?? row["app_slug"] ?? row["topic_slug"] ?? ""
      return TaskLink(rel: row["rel"], target: kind + ":" + target)
    }
    return task
  }
}
