import Foundation
import GRDB

/// Shared task visibility and date-based archive predicates for local backlog reads.
struct TaskVisibility {
  static let archiveSQL = """
    CASE WHEN task.archive_override IS NOT NULL THEN task.archive_override='archived'
    WHEN task.status NOT IN ('done','dropped') OR task.closed_at IS NULL THEN 0
    WHEN julianday(task.closed_at) IS NULL THEN -1
    ELSE julianday(task.closed_at)<julianday(:archive_cutoff) END
    """
  static let sql = """
    (task.status<>'proposed' OR :all_proposals OR task.created_by=:viewer)
    AND (task.external_ref IS NULL OR :promoted)
    AND (:archived OR (\(archiveSQL))=0)
    """

  let arguments: StatementArguments

  init(
    actor: ActorID, at date: Date, days: Int, proposed: Bool = false,
    promoted: Bool = false, archived: Bool = false
  ) {
    arguments = [
      "viewer": actor.description, "all_proposals": proposed || actor.isHuman,
      "promoted": promoted, "archived": archived,
      "archive_cutoff": TaskService.timestamp(date.addingTimeInterval(-Double(days) * 86400)),
    ]
  }

  func validateDates(workspace: Int64, in db: Database) throws {
    var values = arguments
    values += ["workspace": workspace]
    if try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(SELECT 1 FROM task WHERE task.workspace_id=:workspace
          AND (task.external_ref IS NULL OR :promoted) AND (\(Self.archiveSQL))=-1)
        """, arguments: values) == true
    {
      throw StorageError.unavailable
    }
  }

  static func isArchived(_ task: TaskDetails, at date: Date, days: Int, in db: Database) throws
    -> Bool
  {
    let value = try Int.fetchOne(
      db,
      sql: """
        SELECT \(archiveSQL) FROM (SELECT :choice AS archive_override,
          :status AS status,:closed AS closed_at) AS task
        """,
      arguments: [
        "choice": task.archiveOverride, "status": task.status,
        "closed": task.closedAt,
        "archive_cutoff": TaskService.timestamp(date.addingTimeInterval(-Double(days) * 86400)),
      ])
    guard let value, value >= 0 else { throw StorageError.unavailable }
    return value == 1
  }
}
