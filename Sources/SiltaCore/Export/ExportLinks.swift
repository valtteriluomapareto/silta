import GRDB

/// Workspace-owned link rows with typed stable UID ends.
enum ExportLinks {
  static let tables = ExportFormat.linkTables.merging([
    "doc": "doc", "doc_rev": "doc_rev", "edge": "edge", "service": "service",
  ]) { _, new in new }

  static func read(_ db: Database, workspace: Int64) throws -> [ExportRow] {
    try Row.fetchAll(db, sql: query, arguments: [workspace]).map {
      try ExportRow(keys: ExportFormat.linkKeys, row: $0)
    }
  }

  private static func uid(of column: String, kind: String) -> String {
    """
    CASE l.\(kind)
      WHEN 'task' THEN (SELECT uid FROM task WHERE id=l.\(column))
      WHEN 'task_plan_rev' THEN
        (SELECT t.uid FROM task_plan_rev v JOIN task t ON t.id=v.task_id WHERE v.id=l.\(column))
      WHEN 'comment' THEN (SELECT uid FROM comment WHERE id=l.\(column))
      WHEN 'app' THEN (SELECT uid FROM app WHERE id=l.\(column))
      WHEN 'topic' THEN (SELECT uid FROM topic WHERE id=l.\(column))
      WHEN 'doc' THEN (SELECT uid FROM doc WHERE id=l.\(column))
      WHEN 'doc_rev' THEN (SELECT uid FROM doc_rev WHERE id=l.\(column))
      WHEN 'edge' THEN (SELECT uid FROM edge WHERE id=l.\(column))
      WHEN 'service' THEN (SELECT uid FROM service WHERE id=l.\(column))
    END
    """
  }

  static let query = """
    SELECT l.uid, l.from_kind, \(uid(of: "from_id", kind: "from_kind")) AS "from", l.rel,
      l.to_kind, \(uid(of: "to_id", kind: "to_kind")) AS "to",
      CASE WHEN l.to_kind='task_plan_rev' THEN (SELECT rev FROM task_plan_rev WHERE id=l.to_id)
      END AS to_rev,
      l.to_ext, l.created_by, l.created_at, l.anchor
    FROM link l WHERE l.workspace_id=? ORDER BY l.id
    """

}
