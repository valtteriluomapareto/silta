package import GRDB

extension ExportSnapshot {
  /// Reads the workspace named `slug` inside the caller's read transaction, so the
  /// tree is one consistent state. Throws `StorageError.schemaTooNew` for a database
  /// with migrations this binary doesn't know, `WorkspaceError.unknown` for a missing
  /// workspace and `ExportError.unsupported` for data this exporter cannot represent.
  package static func read(_ db: Database, workspace slug: String) throws -> Self {
    let migrator = StorageSchema.migrator
    if try migrator.hasBeenSuperseded(db) { throw StorageError.schemaTooNew }
    guard try migrator.hasCompletedMigrations(db), let schema = migrator.migrations.last else {
      throw StorageError.internalMisuse
    }
    guard let found = try Row.fetchOne(db, sql: Query.workspace, arguments: [slug]) else {
      throw WorkspaceError.unknown(slug)
    }
    let id: Int64 = found["id"]
    let workspace = try ExportRow(keys: ExportFormat.workspaceKeys, row: found)
    try requireNoDocsOrReservations(db, workspace: id)
    if let kind = try String.fetchOne(db, sql: Query.unsupportedLink, arguments: [id, id]) {
      throw ExportError.unsupported("\(kind) links")
    }
    func rows(_ sql: String, _ keys: [String], _ argument: any DatabaseValueConvertible = id) throws
      -> [ExportRow]
    {
      try Row.fetchAll(db, sql: sql, arguments: [argument]).map {
        try ExportRow(keys: keys, row: $0)
      }
    }
    let sections = try zip(ExportFormat.sections, Query.sections).map { format, sql in
      Section(name: format.name, rows: try rows(sql, format.keys))
    }
    var records: [Int64: [ExportRow]] = [:]
    for (format, sql) in zip(ExportFormat.records, Query.records) {
      for row in try Row.fetchAll(db, sql: sql, arguments: [id]) {
        records[row["task_id"], default: []].append(try ExportRow(keys: format.keys, row: row))
      }
    }
    let tasks = try Row.fetchAll(db, sql: Query.tasks, arguments: [id]).map { row in
      let exported = try ExportRow(keys: ExportFormat.taskKeys, row: row)
      return ExportTask(
        ref: exported.value("ref") ?? "", row: exported, records: records[row["id"]] ?? [])
    }
    return Self(
      schema: schema, workspace: workspace, sections: sections, tasks: tasks,
      links: try rows(ExportLinks.query, ExportFormat.linkKeys),
      aliasDecisions: try rows(Query.aliasDecisions, ExportFormat.aliasDecisionKeys),
      approvals: try rows(Query.approvals, ExportFormat.approvalKeys, slug))
  }
  private static func requireNoDocsOrReservations(_ db: Database, workspace id: Int64) throws {
    if try Bool.fetchOne(
      db, sql: "SELECT EXISTS(SELECT 1 FROM doc WHERE workspace_id=?)", arguments: [id])
      == true
    {
      throw ExportError.unsupported("docs")
    }
    if try Bool.fetchOne(
      db, sql: "SELECT EXISTS(SELECT 1 FROM seq_counter WHERE scope GLOB ?)",
      arguments: ["doc_rev:\(id):*"]) == true
    {
      throw ExportError.unsupported("reserved doc revision history")
    }
  }
}

/// One query per file section, each ordered by id (rowid for keyless tables), with
/// foreign keys mapped to the target's uid under the format's key.
private enum Query {
  static let workspace = """
    SELECT id, uid, slug, name, task_prefix, settings,
      (SELECT next FROM seq_counter WHERE scope='task:'||workspace.id) AS next_task_seq
    FROM workspace WHERE slug=?
    """

  static let sections = [
    "SELECT uid, slug, remote_url, default_ref FROM repo WHERE workspace_id=? ORDER BY id",
    """
    SELECT a.uid, a.slug, a.previous_slugs, a.name, r.uid AS repo, a.ref, a.prod_ref, a.subpath,
      a.is_primary, a.stack, a.summary, a.lifecycle
    FROM app a LEFT JOIN repo r ON r.id=a.repo_id WHERE a.workspace_id=? ORDER BY a.id
    """,
    """
    SELECT e.uid, a.uid AS app, e.name, e.url, e.deploy, e.notes
    FROM environment e JOIN app a ON a.id=e.app_id WHERE a.workspace_id=? ORDER BY e.id
    """,
    """
    SELECT uid, slug, name, summary, secrets_location FROM service WHERE workspace_id=?
    ORDER BY id
    """,
    """
    SELECT e.uid, f.uid AS from_app, t.uid AS to_app, s.uid AS to_service, e.kind, e.summary,
      e.code_refs
    FROM edge e LEFT JOIN app f ON f.id=e.from_app_id LEFT JOIN app t ON t.id=e.to_app_id
      LEFT JOIN service s ON s.id=e.to_service_id
    WHERE e.workspace_id=? ORDER BY e.id
    """,
    """
    SELECT uid, slug, previous_slugs, name, summary, status FROM topic WHERE workspace_id=?
    ORDER BY id
    """,
    """
    SELECT t.uid AS topic, a.alias FROM topic_alias a LEFT JOIN topic t ON t.id=a.topic_id
    WHERE a.workspace_id=? ORDER BY a.rowid
    """,
    """
    SELECT s.uid, s.kind, s.root, s.include, s.exclude, r.uid AS repo
    FROM source s LEFT JOIN repo r ON r.id=s.repo_id WHERE s.workspace_id=? ORDER BY s.id
    """,
  ]

  static let tasks = """
    SELECT w.task_prefix||'-'||t.seq AS ref, t.id, t.uid, t.seq, t.title, t.type, t.status,
      t.priority, t.description_md, t.plan_md, t.plan_rev, t.acceptance_md, t.result_md,
      p.uid AS parent, a.uid AS app, t.claimed_by, t.claimed_at, t.branch, t.done_sha,
      t.done_branch, t.done_dirty, t.archive_override, t.external_ref, t.created_by,
      t.created_at, t.updated_at, t.closed_at, t.follow_up_at
    FROM task t JOIN workspace w ON w.id=t.workspace_id LEFT JOIN task p ON p.id=t.parent_id
      LEFT JOIN app a ON a.id=t.app_id
    WHERE t.workspace_id=? ORDER BY t.seq
    """

  private static let ofWorkspace = "task_id IN (SELECT id FROM task WHERE workspace_id=?)"

  static let records = [
    """
    SELECT 'task_plan_rev' AS "table", task_id, rev, body_md, actor, created_at
    FROM task_plan_rev WHERE \(ofWorkspace) ORDER BY id
    """,
    """
    SELECT 'task_event' AS "table", task_id, actor, kind, body, created_at
    FROM task_event WHERE \(ofWorkspace) ORDER BY id
    """,
    """
    SELECT 'comment' AS "table", c.task_id, c.uid, c.seq, r.uid AS thread, c.kind, c.verdict,
      c.subject, c.anchor, c.anchor_sha, c.anchor_snippet, c.body_md, c.mentions, c.accepted,
      c.actor, c.resolved_at, c.resolved_by, c.deleted_at, c.created_at
    FROM comment c LEFT JOIN comment r ON r.id=c.thread_id
    WHERE c.task_id IN (SELECT id FROM task WHERE workspace_id=?) ORDER BY c.id
    """,
    """
    SELECT 'review_request' AS "table", task_id, reviewer, subject, requested_by, created_at,
      taken_by, taken_at, done_at
    FROM review_request WHERE \(ofWorkspace) ORDER BY id
    """,
  ]

  /// A link end the public exporter cannot represent.
  static let unsupportedLink = """
    SELECT from_kind FROM link WHERE workspace_id=? AND from_kind NOT IN ('task','comment')
    UNION ALL
    SELECT to_kind FROM link WHERE workspace_id=? AND to_id IS NOT NULL
      AND to_kind NOT IN ('task','task_plan_rev','comment','app','topic')
    LIMIT 1
    """

  static let aliasDecisions = """
    SELECT a.note_ref, t.uid AS topic, a.decision, a.actor, a.created_at
    FROM alias_decision a LEFT JOIN topic t ON t.id=a.topic_id
    WHERE a.workspace_id=? ORDER BY a.rowid
    """

  static let approvals = """
    SELECT uid, actor, command, words, created_at FROM approval WHERE workspace=? ORDER BY id
    """
}
