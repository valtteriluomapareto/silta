import Foundation
import GRDB

/// Shared task visibility and date-based archive predicates for local backlog reads.
struct TaskVisibility {
  static let archiveSQL = """
    CASE WHEN task.archive_override IS NOT NULL THEN task.archive_override='archived'
    WHEN task.status NOT IN ('done','dropped') OR task.closed_at IS NULL THEN 0
    WHEN silta_archive_instant(task.closed_at) IS NULL THEN -1
    ELSE silta_archive_instant(task.closed_at)<:archive_cutoff END
    """
  static let localSQL = """
    (task.status<>'proposed' OR :all_proposals OR task.created_by=:viewer)
    AND (task.external_ref IS NULL OR :promoted)
    """
  static let sql = """
    \(localSQL) AND (\(archiveSQL))=0
    """

  let arguments: StatementArguments

  init(
    actor: ActorID, at date: Date, days: Int, proposed: Bool = false,
    promoted: Bool = false
  ) {
    arguments = [
      "viewer": actor.description, "all_proposals": proposed || actor.isHuman,
      "promoted": promoted,
      "archive_cutoff": date.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970,
    ]
  }

  static func register(in db: Database) {
    db.add(
      function: DatabaseFunction("silta_archive_instant", argumentCount: 1, pure: true) { values in
        guard let value = values.first, let text = String.fromDatabaseValue(value) else {
          return nil
        }
        do {
          return try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(text).timeIntervalSince1970
        } catch { return nil }
      })
  }

  static func validateDates(scope: String, arguments: StatementArguments, in db: Database) throws {
    if try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(SELECT 1 FROM task LEFT JOIN app ON app.id=task.app_id
          WHERE \(scope) AND \(localSQL) AND (\(archiveSQL))=-1)
        """, arguments: arguments) == true
    {
      throw StorageError.internalMisuse
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
        "archive_cutoff": date.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970,
      ])
    guard let value, value >= 0 else { throw StorageError.internalMisuse }
    return value == 1
  }
}
