import Foundation
import GRDB

/// The shared open-task ranking for location and brief context (spec §8).
enum CurrentTaskSelector {
  static func select(
    _ context: LocationContext, app: String?, actor: String, branch: String?, in db: Database
  ) throws -> TaskDetails? {
    let workspaceID = try TaskService.workspaceID(context.repo.workspace, in: db)
    let candidates = context.candidates.filter { app == nil || app == $0.app }.map(\.id)
    let slots = candidates.map { _ in "?" }.joined(separator: ",")
    let row = try Row.fetchOne(
      db,
      sql: TaskService.query + """
        \nWHERE task.workspace_id=? AND task.status IN ('todo','doing','review','blocked')
          AND task.external_ref IS NULL AND task.archive_override IS NOT 'archived'
          AND ((task.app_id IS NULL AND (task.worktree IS NULL OR task.worktree=?))
            OR task.app_id IN (\(slots)))
          AND (task.claimed_by=? OR task.branch=?)
        ORDER BY COALESCE(task.claimed_by=?,0) DESC,
          CASE WHEN task.claimed_by=? THEN task.claimed_at ELSE task.updated_at END DESC,
          task.seq DESC LIMIT 1
        """,
      arguments: StatementArguments(
        [workspaceID, context.root.path] as [(any DatabaseValueConvertible)?]
          + candidates.map { $0 as (any DatabaseValueConvertible)? }
          + [
            actor, branch, actor,
            actor,
          ]))
    return row.map { TaskDetails(row: $0) }
  }
}
