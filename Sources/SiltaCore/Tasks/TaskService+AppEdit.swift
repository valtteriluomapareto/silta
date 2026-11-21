import Foundation
import GRDB

extension TaskService {
  /// Changes the task's app without editing its Markdown document or its children.
  package func editApp(_ ref: String, to option: String) throws
    -> (result: TaskResult, approvalUsed: Bool)
  {
    let workspace = try selected()
    let at = environment.clock.now()
    let prepare: (Database) throws -> AppEdit = { [self] db in
      let task = try Self.lookup(ref, workspace: workspace, in: db)
      try ensureAppEditAllowed(task, workspace: workspace, at: at)
      let name = option.hasPrefix("app:") ? String(option.dropFirst(4)) : option
      let destination =
        option == TaskDraft.noneApp ? nil : try Self.appDestination(name, task: task, in: db)
      let command = "silta task edit " + shellWord(task.ref) + " --app " + shellWord(option)
      let approval = try approval(
        required: task.claimedBy != environment.actor.description,
        command: scopedCommand(command, workspace: workspace))
      let warning = destination?.warning(for: name, kind: .app)
      return AppEdit(
        task: task, destination: destination, command: command,
        approval: approval, warnings: [warning].compactMap { $0 })
    }
    if let unchanged = try environment.db.read({ db -> TaskResult? in
      let edit = try prepare(db)
      return edit.changed ? nil : receipt(edit.task, warnings: edit.warnings)
    }) {
      return (unchanged, false)
    }
    return try environment.db.write { tx in
      let edit = try prepare(tx.database)
      var result = receipt(edit.task, warnings: edit.warnings)
      guard edit.changed else { return (result, false) }
      let change = try applyAppEdit(edit, at: at, in: tx)
      try edit.approval?.record(
        command: edit.command, workspace: workspace, identity: (environment.ids, at), in: tx)
      result.appChange = change
      return (result, edit.approval != nil)
    }
  }

  private func ensureAppEditAllowed(_ task: TaskDetails, workspace: String, at: Date) throws {
    if let external = task.externalRef {
      let error = TaskError.promoted(task.ref, external: external)
      throw CommandFailure(
        error: error, next: error.next.map { scopedCommand($0, workspace: workspace) },
        message: "\(task.ref) is promoted; its primary app cannot change. "
          + "Work in tracker \(HumanText.line(external)).")
    }
    try validateClaim(task, workspace: workspace, at: at)
    guard task.status != "done", task.status != "dropped" else {
      let error = TaskError.transition(task.ref, status: task.status)
      throw CommandFailure(
        error: error, next: error.next.map { scopedCommand($0, workspace: workspace) },
        message: "\(task.ref) is \(task.status); its primary app cannot change.")
    }
  }

  private struct AppEdit {
    let task: TaskDetails
    let destination: WorkspaceSlugs.Resolved?
    let command: String
    let approval: HumanApproval?
    let warnings: [OutputWarning]

    var changed: Bool { task.appID != destination?.id }
  }

  private static func appDestination(_ name: String, task: TaskDetails, in db: Database)
    throws -> WorkspaceSlugs.Resolved
  {
    guard WorkspaceConfig.isValidIdentifier(name) else {
      throw TaskError.invalid("Use an app slug or none.")
    }
    do {
      return try namedSlug(.app, name, workspace: task.workspaceID, in: db)
    } catch let error as TaskError {
      guard case .notFound = error else { throw error }
      let workspace = try String.fetchOne(
        db, sql: "SELECT slug FROM workspace WHERE id=?", arguments: [task.workspaceID])
      throw CommandFailure(error: error, next: [workspaceEditRead(workspace)])
    }
  }

  private func applyAppEdit(
    _ edit: AppEdit, at: Date, in tx: StorageTransaction
  ) throws -> TaskAppChange {
    let task = edit.task
    let db = tx.database
    let oldApp = task.appID
    let newApp = edit.destination?.id
    let repoSQL = "SELECT repo_id FROM app WHERE id=?"
    let oldRepo = try oldApp.flatMap { try Int64.fetchOne(db, sql: repoSQL, arguments: [$0]) }
    let newRepo = try newApp.flatMap { try Int64.fetchOne(db, sql: repoSQL, arguments: [$0]) }
    let repositoryChanged = oldRepo != newRepo
    let stamp = Self.timestamp(at)
    try db.execute(
      sql: """
        UPDATE task SET app_id=?,updated_at=?,
          claimed_at=CASE WHEN claimed_by=? THEN ? ELSE claimed_at END,
          branch=CASE WHEN ? THEN NULL ELSE branch END,
          worktree=CASE WHEN ? THEN NULL ELSE worktree END
        WHERE id=?
        """,
      arguments: [
        newApp, stamp, environment.actor.description, stamp, repositoryChanged,
        repositoryChanged, task.id,
      ])
    let prefix = try Self.prefix(task.workspaceID, in: db)
    let children = try Int64.fetchAll(
      db,
      sql: """
        SELECT seq FROM task WHERE workspace_id=? AND parent_id=? AND app_id IS ?
          AND external_ref IS NULL AND status IN ('todo','doing','blocked','review') ORDER BY seq
        """, arguments: [task.workspaceID, task.id, oldApp]
    ).map { "\(prefix)-\($0)" }
    let change = TaskAppChange(
      from: task.app, to: edit.destination?.slug, childrenOnPreviousApp: children)
    try changed(task.id, kind: "field", body: change.text, at: at, in: tx)
    return change
  }
}
