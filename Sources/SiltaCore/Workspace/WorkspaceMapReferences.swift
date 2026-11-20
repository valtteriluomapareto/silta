import GRDB

/// Live references used by the map edit preview and the guarded save.
enum WorkspaceMapReferences {
  static func blockers(_ removals: [WorkspaceMapRow], workspace: Int64, in db: Database) throws
    -> [WorkspaceMapChanges.Blocker]
  {
    let sources = Set(removals.filter { $0.table == "source" }.map(\.id))
    return try removals.compactMap { row in
      var refs: [String] = []
      if ["app", "topic", "service", "edge"].contains(row.table) {
        refs = try documents(row, workspace: workspace, in: db).map {
          "doc:" + ($0["slug"] as String)
        }
        refs += try links(row, workspace: workspace, in: db)
      }
      if row.table == "app" {
        refs += try appTasks(row.id, in: db)
        let overrides = try count("worktree_override", by: "app_id", id: row.id, in: db)
        if overrides > 0 { refs.append("\(overrides) worktree override(s)") }
      }
      if row.table == "topic" {
        let decisions = try count("alias_decision", by: "topic_id", id: row.id, in: db)
        if decisions > 0 { refs.append("\(decisions) alias decision(s)") }
      }
      if row.table == "repo" {
        refs += try Row.fetchAll(
          db, sql: "SELECT id,kind,root FROM source WHERE repo_id=? ORDER BY id",
          arguments: [row.id]
        ).filter { !sources.contains($0["id"]) }.map {
          "source:" + ($0["kind"] as String) + "/" + ($0["root"] as String)
        }
      }
      return refs.isEmpty ? nil : .init(item: row.ref, references: Set(refs).sorted())
    }.sorted { $0.item < $1.item }
  }

  static func rename(
    _ kind: WorkspaceSlugs.Kind, _ match: WorkspaceSlugs.Match, removals: [String: Set<Int64>],
    workspace: Int64, in db: Database
  ) throws -> WorkspaceMapChanges.Rename {
    let id = match.old.id
    let row = WorkspaceMapRow(table: kind.rawValue, id: id, parts: [match.old.slug])
    let docs = try documents(row, workspace: workspace, in: db).count
    let tagged = try links(row, workspace: workspace, in: db, tasksOnly: true)
    let tasks = try Set(tagged + (kind == .app ? appTasks(id, in: db) : [])).count
    let edges =
      try kind == .app
      ? Int64.fetchAll(
        db, sql: "SELECT id FROM edge WHERE from_app_id=? OR to_app_id=?",
        arguments: [id, id]
      ).filter { removals["edge"]?.contains($0) != true }.count : 0
    let environments =
      try kind == .app
      ? Int64.fetchAll(db, sql: "SELECT id FROM environment WHERE app_id=?", arguments: [id])
        .filter { removals["environment"]?.contains($0) != true }.count : 0
    return .init(
      kind: kind.rawValue, from: match.old.slug, to: match.slug, docs: docs,
      tasks: tasks, edges: edges, environments: environments)
  }

  static func documents(
    _ row: WorkspaceMapRow, workspace: Int64, in db: Database
  ) throws -> [Row] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT DISTINCT doc.id,doc.slug FROM link
        JOIN doc ON link.from_kind='doc' AND link.from_id=doc.id
        JOIN doc_rev ON doc_rev.doc_id=doc.id AND doc_rev.rev=doc.current_rev
        WHERE link.workspace_id=? AND doc.workspace_id=? AND link.rel='about'
          AND link.to_kind=? AND link.to_id=? AND doc.archived=0 AND doc_rev.state='accepted'
        ORDER BY doc.slug
        """, arguments: [workspace, workspace, row.table, row.id])
  }

  private static func links(
    _ row: WorkspaceMapRow, workspace: Int64, in db: Database, tasksOnly: Bool = false
  ) throws -> [String] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT DISTINCT from_kind AS to_kind,from_id AS to_id,NULL AS to_ext,NULL AS anchor
        FROM link WHERE workspace_id=? AND to_kind=? AND to_id=? AND from_kind<>'doc'
          AND (NOT ? OR from_kind='task')
        """, arguments: [workspace, row.table, row.id, tasksOnly]
    ).map { link in
      let kind: String = link["to_kind"]
      if kind == "task" || kind == "comment" {
        return String(try TaskLinkTarget.render(link, in: db).dropFirst(kind.count + 1))
      }
      return kind + " link #" + String(link["to_id"] as Int64)
    }
  }

  private static func appTasks(_ id: Int64, in db: Database) throws -> [String] {
    try String.fetchAll(
      db,
      sql: """
        SELECT workspace.task_prefix||'-'||task.seq FROM task
        JOIN workspace ON workspace.id=task.workspace_id WHERE task.app_id=?
        """, arguments: [id])
  }

  private static func count(_ table: String, by field: String, id: Int64, in db: Database) throws
    -> Int
  {
    try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table) WHERE \(field)=?", arguments: [id])
      ?? 0
  }
}
