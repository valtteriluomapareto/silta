import Foundation
import GRDB

extension TaskService {
  package static let statuses = [
    "proposed", "todo", "doing", "review", "blocked", "done", "dropped",
  ]

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
    try listWithWarnings(filter).tasks
  }

  package func listWithWarnings(_ filter: TaskFilter) throws
    -> (tasks: [TaskDetails], warnings: [OutputWarning])
  {
    if let status = filter.status, !Self.statuses.contains(status) {
      throw TaskError.invalid("Unknown task status.")
    }
    let slug = try selected()
    return try environment.db.read { db in
      let id = try Self.workspaceID(slug, in: db)
      let app = try filter.app.flatMap {
        try WorkspaceSlugs.resolve(.app, $0, workspace: id, in: db)
      }
      let topic = try filter.topic.flatMap {
        try WorkspaceSlugs.resolve(.topic, $0, workspace: id, in: db)
      }
      let warnings = [
        filter.app.flatMap { app?.warning(for: $0, kind: .app) },
        filter.topic.flatMap { topic?.warning(for: $0, kind: .topic) },
      ].compactMap { $0 }
      let appSlug = app?.slug ?? filter.app
      let topicSlug = topic?.slug ?? filter.topic
      if let on = filter.on { _ = try Self.blocker(on, workspace: slug, in: db) }
      let visibility = TaskVisibility(
        actor: environment.actor, at: environment.clock.now(),
        days: WorkspaceSettings.defaultArchiveAfterDays,
        proposed: filter.proposed || filter.status == "proposed", promoted: filter.promoted)
      var arguments = visibility.arguments
      arguments += ["workspace": id]
      let tasks = try Row.fetchAll(
        db,
        sql: Self.query + """
          \nWHERE task.workspace_id=:workspace AND \(TaskVisibility.localSQL)
          ORDER BY task.priority,task.seq
          """, arguments: arguments
      ).map { TaskDetails(row: $0) }.filter {
        (filter.status == nil || filter.status == $0.status)
          && (appSlug == nil || appSlug == $0.app)
          && (!filter.mine || $0.createdBy == environment.actor.description
            || $0.claimedBy == environment.actor.description)
      }.filter { try Self.matchesBlocker(filter.on, task: $0, workspace: slug, in: db) }
        .map { try Self.decorate($0, at: environment.clock.now(), in: db) }.filter {
          (!($0.archived) || filter.archived)
            && (topicSlug == nil
              || $0.links.contains {
                $0.target == "topic:" + (topicSlug ?? "") && $0.rel == "about"
              })
        }
      return (tasks, warnings)
    }
  }

  /// Reads a task and optionally its event history without creating storage.
  package func show(_ ref: String, timeline: Bool = false) throws -> TaskDetails {
    let slug = try selected()
    return try environment.db.read { db in
      try read(ref, workspace: slug, timeline: timeline, in: db)
    }
  }

  /// The Mac inspector's read, in one transaction and without the event timeline: the
  /// normal read, the resolved threads it hides, the tasks it names and what keeps a
  /// block from being ready. A deleted resolved root without live replies stays hidden,
  /// as in the normal read.
  package func inspect(_ ref: String) throws -> TaskInspection {
    let slug = try selected()
    return try environment.db.read { db in
      let task = try read(ref, workspace: slug, timeline: false, in: db)
      let unmet =
        task.status == "blocked" ? try Self.unmet(task, in: db) : (open: [], dropped: [])
      return TaskInspection(
        task: task, resolved: try Self.resolvedThreads(task, in: db),
        related: try Self.relatives(task, in: db), open: unmet.open, dropped: unmet.dropped)
    }
  }

  /// Posts of the resolved threads the normal read hides, each root before its replies.
  private static func resolvedThreads(_ task: TaskDetails, in db: Database) throws
    -> [CommentDetails]
  {
    guard task.resolvedThreads != nil else { return [] }
    let posts = try discussion(task, timeline: true, in: db)
    let shown = Set((task.comments ?? []).map(\.ref))
    let roots = posts.filter { root in
      guard root.replyTo == nil, root.resolvedAt != nil, !shown.contains(root.ref) else {
        return false
      }
      return !root.deleted || posts.contains { $0.replyTo == root.ref && !$0.deleted }
    }
    return roots.flatMap { root in [root] + posts.filter { $0.replyTo == root.ref } }
  }

  /// The parent, subtasks and blocker tasks of a task, in sequence order. No visibility
  /// filter applies: a promoted, archived or proposed relative is still named.
  private static func relatives(_ task: TaskDetails, in db: Database) throws -> [TaskRelative] {
    let blockers = try blockLinks(task, in: db).filter { ($0["to_kind"] as String) == "task" }
      .map { $0["to_id"] as Int64 }
    let marks = Array(repeating: "?", count: blockers.count).joined(separator: ",")
    let rows = try Row.fetchAll(
      db,
      sql: query + """
        \nWHERE task.workspace_id=? AND task.id<>? AND (task.parent_id=?
          OR task.id=(SELECT parent_id FROM task WHERE id=?)
          \(blockers.isEmpty ? "" : "OR task.id IN (\(marks))"))
        ORDER BY task.seq
        """,
      arguments: StatementArguments(
        [task.workspaceID, task.id, task.id, task.id] + blockers))
    return rows.map {
      let relative = TaskDetails(row: $0)
      return TaskRelative(
        ref: relative.ref, title: relative.title, status: relative.status,
        parent: relative.parent, externalRef: relative.externalRef)
    }
  }

  private func read(_ ref: String, workspace slug: String, timeline: Bool, in db: Database)
    throws -> TaskDetails
  {
    var task = try Self.decorate(
      Self.lookup(ref, workspace: slug, in: db), at: environment.clock.now(), in: db)
    let comments = try Self.discussion(task, timeline: timeline, in: db)
    task.comments = comments.isEmpty ? nil : comments
    if !timeline {
      let resolved = try Self.hiddenResolvedThreads(task, displayed: comments, in: db)
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

  /// Reads the latest actual submission for a task currently awaiting review.
  package func reviewSubmission(_ ref: String) throws -> TaskEvent? {
    let workspace = try selected()
    return try environment.db.read { db in
      let task = try Self.lookup(ref, workspace: workspace, in: db)
      guard task.status == "review",
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT kind,actor,body,created_at FROM task_event
            WHERE task_id=? AND kind='status' AND body='review' ORDER BY id DESC LIMIT 1
            """, arguments: [task.id])
      else { return nil }
      return try Self.safeEvent(row, in: db)
    }
  }

  private static func hiddenResolvedThreads(
    _ task: TaskDetails, displayed comments: [CommentDetails], in db: Database
  ) throws -> Int {
    let resolved =
      try Int.fetchOne(
        db,
        sql: """
          SELECT count(*) FROM comment
          WHERE task_id=? AND thread_id IS NULL AND resolved_at IS NOT NULL
          """, arguments: [task.id]) ?? 0
    let displayed = comments.filter {
      $0.kind == "handoff" && $0.replyTo == nil && $0.resolvedAt != nil
    }.count
    return resolved - displayed
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
