import Foundation
import GRDB

extension TaskService {
  static let statuses = ["proposed", "todo", "doing", "review", "blocked", "done", "dropped"]

  static let query = """
    SELECT task.*,workspace.task_prefix,app.slug AS app_slug,repo_path.path AS repo_path,
      parent.seq AS parent_seq
    FROM task
    JOIN workspace ON workspace.id=task.workspace_id
    LEFT JOIN task AS parent ON parent.id=task.parent_id
    LEFT JOIN app ON app.id=task.app_id
    LEFT JOIN repo_path ON repo_path.repo_id=app.repo_id
    """

  /// Reads the selected workspace backlog and always retains the caller's proposals.
  /// Promoted tasks belong to their tracker and are left out unless asked for.
  package func list(_ filter: TaskFilter = TaskFilter()) throws -> [TaskDetails] {
    if let status = filter.status, !Self.statuses.contains(status) {
      throw TaskError.invalid("Unknown task status.")
    }
    let slug = try selected()
    return try environment.db.read { db in
      let id = try Self.workspaceID(slug, in: db)
      if let on = filter.on { _ = try Self.blocker(on, workspace: slug, in: db) }
      return try Row.fetchAll(
        db,
        sql: Self.query + """
          \nWHERE task.workspace_id=?
          ORDER BY task.priority,task.seq
          """, arguments: [id]
      ).map { TaskDetails(row: $0) }.filter {
        let visible =
          $0.status != "proposed" || filter.proposed || filter.status == "proposed"
          || environment.actor.isHuman || $0.createdBy == environment.actor.description
        return visible && ($0.externalRef == nil || filter.promoted)
          && (filter.status == nil || filter.status == $0.status)
          && (filter.app == nil || filter.app == $0.app)
          && (!filter.mine || $0.createdBy == environment.actor.description
            || $0.claimedBy == environment.actor.description)
      }.filter { try Self.matchesBlocker(filter.on, task: $0, workspace: slug, in: db) }
        .map { try Self.decorate($0, at: environment.clock.now(), in: db) }.filter {
          (!($0.archived) || filter.archived)
            && (filter.topic == nil
              || $0.links.contains {
                $0.target == "topic:" + (filter.topic ?? "") && $0.rel == "about"
              })
        }

    }
  }

  /// Reads a task and optionally its event history without creating storage.
  package func show(_ ref: String, timeline: Bool = false) throws -> TaskDetails {
    let slug = try selected()
    return try environment.db.read { db in
      var task = try Self.decorate(
        Self.lookup(ref, workspace: slug, in: db), at: environment.clock.now(), in: db)
      let comments = try Self.discussion(task, timeline: timeline, in: db)
      task.comments = comments.isEmpty ? nil : comments
      if !timeline {
        let resolved =
          try Int.fetchOne(
            db,
            sql: """
              SELECT count(*) FROM comment
              WHERE task_id=? AND thread_id IS NULL AND resolved_at IS NOT NULL
              """, arguments: [task.id]) ?? 0
        if resolved > 0 { task.resolvedThreads = resolved }
      }
      if task.status == "doing", task.claimedBy == nil, task.externalRef == nil,
        let body = try String.fetchOne(
          db,
          sql: """
            SELECT body FROM task_event WHERE task_id=? AND kind='claim' ORDER BY id DESC LIMIT 1
            """, arguments: [task.id]), body.hasPrefix("released ")
      {
        task.resumeAvailable = true
        let ref = String(body.dropFirst("released ".count))
        let live =
          try Bool.fetchOne(
            db,
            sql: """
              SELECT EXISTS(SELECT 1 FROM comment
              WHERE task_id=? AND ? || '/' || seq=? AND deleted_at IS NULL)
              """,
            arguments: [task.id, task.ref, ref]) ?? false
        if live { task.handedOff = ref }
      }
      if timeline {
        task.timeline = try Row.fetchAll(
          db,
          sql: """
            SELECT kind,actor,body,created_at
            FROM task_event
            WHERE task_id=?
            ORDER BY id
            """, arguments: [task.id]
        ).map { try Self.safeEvent($0, in: db) }
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
    else { throw TaskError.notFound("task " + raw) }
    return TaskDetails(row: row)
  }

  static func decorate(_ original: TaskDetails, at date: Date, in db: Database) throws
    -> TaskDetails
  {
    var task = original
    task.archived = try isArchived(task, at: date, in: db)
    task.waiting = try waiting(task, at: date, in: db)
    task.links = try Row.fetchAll(
      db,
      sql: """
        SELECT link.*
        FROM link
        WHERE link.from_kind='task' AND link.from_id=? AND link.workspace_id=?
        ORDER BY link.id
        """, arguments: [task.id, task.workspaceID]
    ).map { row in
      let target = try TaskLinkTarget.render(row, in: db)
      return TaskLink(
        rel: row["rel"],
        target: (row["rel"] as String) == "blocked_by"
          && (row["to_kind"] as String) == "url" ? SecretGuard.redacted(target) : target)
    }
    return task
  }
}
