package import Foundation
import GRDB

extension TaskService {
  /// Creates a task, its initial claim and its links in one transaction.
  /// App work records the current worktree; no-app work never invokes git.
  package func add(_ draft: TaskDraft, directory: URL) async throws -> TaskResult {
    let title = try checked(
      draft.title, allow: draft.allowSecret, command: "silta task add '<title>'")
    let body = try checked(
      draft.description, allow: draft.allowSecret, command: "silta task add '<title>'")
    try validateDraft(draft)
    let slug = try selected()
    let at = environment.clock.now()
    let uid = try environment.ids.next(at: at)
    let path = try appPath(draft.app, workspace: slug)
    let git = try await TaskGit.inspect(
      repo: path, directory: directory, runner: environment.git,
      enabled: draft.start && draft.app != nil, completion: false)
    return try environment.db.write { tx in
      let db = tx.database
      let ws = try Self.workspaceID(slug, in: db)
      let parent = try draft.parent.map { try Self.lookup($0, workspace: slug, in: db) }
      if let parent, !environment.actor.isHuman {
        guard parent.claimedBy == environment.actor.description else {
          throw TaskError.invalid("Agent subtasks require a parent claimed by this exact session.")
        }
      }
      let app = try draft.app.map { try Self.entity("app", slug: $0, workspace: ws, in: db) }
      if let app, try Self.repoPath(app: app, in: db) != path { throw TaskError.changed(nil) }
      let seq = try tx.nextSequence(scope: "task:\(ws)")
      let status =
        draft.start ? "doing" : environment.actor.isHuman || parent != nil ? "todo" : "proposed"
      let stamp = Self.timestamp(at)
      try db.execute(
        sql: """
          INSERT INTO task(uid,workspace_id,seq,title,status,description_md,parent_id,app_id,
            claimed_by,claimed_at,branch,worktree,created_by,created_at,updated_at)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
          """,
        arguments: [
          uid, ws, seq, title.0, status, body.0, parent?.id, app,
          draft.start ? environment.actor.description : nil, draft.start ? stamp : nil,
          git.branch, git.worktree, environment.actor.description, stamp, stamp,
        ])
      let id = db.lastInsertedRowID
      try addLinks(draft, task: id, workspace: ws, at: at, in: db)
      try changed(id, kind: "created", body: status, redacted: title.1 || body.1, at: at, in: tx)
      return TaskResult(
        ref: "\(try Self.prefix(ws, in: db))-\(seq)", status: status,
        warnings: title.1 || body.1 ? [SecretGuard.warning] : [])
    }
  }

  private func appPath(_ app: String?, workspace: String) throws -> String? {
    try app.flatMap { app in
      try environment.db.read { db in
        let ws = try Self.workspaceID(workspace, in: db)
        let id = try Self.entity("app", slug: app, workspace: ws, in: db)
        return try Self.repoPath(app: id, in: db)
      }
    }
  }

  private func validateDraft(_ draft: TaskDraft) throws {
    guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TaskError.invalid("A task title is required.")
    }
    if let source = draft.source, !source.hasPrefix("note:") || source.count == 5 {
      throw TaskError.invalid("--from requires a note: reference.")
    }
  }

  private func addLinks(
    _ draft: TaskDraft, task: Int64, workspace: Int64, at date: Date, in db: Database
  ) throws {
    for topic in Set(draft.topics).sorted() {
      let id = try Self.entity("topic", slug: topic, workspace: workspace, in: db)
      try insertLink(
        task: task, workspace: workspace, target: ("topic", id.databaseValue), at: date, in: db)
    }
    if let source = draft.source {
      try insertLink(
        task: task, workspace: workspace,
        target: ("note", String(source.dropFirst(5)).databaseValue), at: date, in: db)
    }
  }

  func insertLink(
    task: Int64, workspace: Int64, target: (String, DatabaseValue),
    at date: Date, in db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,to_ext,
          created_by,created_at)
        VALUES(?,?,'task',?,?,?,?,?,?,?)
        """,
      arguments: [
        try environment.ids.next(at: date), workspace, task,
        target.0 == "note" ? "source" : "about", target.0, target.0 == "note" ? nil : target.1,
        target.0 == "note" ? target.1 : nil,
        environment.actor.description, Self.timestamp(date),
      ])
  }

  static func prefix(_ workspace: Int64, in db: Database) throws -> String {
    guard
      let value = try String.fetchOne(
        db, sql: "SELECT task_prefix FROM workspace WHERE id=?", arguments: [workspace])
    else { throw WorkspaceError.notFound }
    return value
  }

  static func repoPath(app: Int64, in db: Database) throws -> String? {
    try String.fetchOne(
      db,
      sql: """
        SELECT repo_path.path
        FROM app
        LEFT JOIN repo_path ON repo_path.repo_id=app.repo_id
        WHERE app.id=?
        """, arguments: [app])
  }
}
