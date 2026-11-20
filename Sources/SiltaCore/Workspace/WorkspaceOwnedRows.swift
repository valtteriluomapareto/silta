import GRDB

/// The workspace-owned graph shared by removal and restore replacement.
enum WorkspaceOwnedRows {
  private static let owned = "workspace_id=:ws"
  private static let tasks = "task_id IN (SELECT id FROM task WHERE workspace_id=:ws)"
  private static let apps = "app_id IN (SELECT id FROM app WHERE workspace_id=:ws)"
  private static let repos = "repo_id IN (SELECT id FROM repo WHERE workspace_id=:ws)"
  private static let revisions = """
    SELECT r.id FROM doc_rev r JOIN doc d ON d.id=r.doc_id WHERE d.workspace_id=:ws
    """
  private static let docRecords = "doc_rev_id IN (\(revisions))"
  private static let approvals = "workspace=(SELECT slug FROM workspace WHERE id=:ws)"
  private static let commentSequences =
    "scope IN (SELECT 'comment:doc_rev:'||id FROM (\(revisions)))"
  private static let sequences =
    "\(commentSequences) OR scope='task:'||:ws OR scope GLOB 'doc_rev:'||:ws||':*'"

  static func counts(_ id: Int64, in db: Database) throws -> [WorkspaceRemovalReport.Count] {
    let scopes = [
      ("alias_decision", owned), ("app", owned), ("approval", approvals),
      ("comment", "\(tasks) OR \(docRecords)"), ("doc", owned),
      ("doc_rev", "id IN (\(revisions))"), ("doc_verification", docRecords), ("edge", owned),
      ("environment", apps), ("link", owned), ("repo", owned), ("repo_path", repos),
      ("review_request", tasks), ("seq_counter", sequences), ("service", owned), ("source", owned),
      ("task", owned), ("task_event", tasks), ("task_plan_rev", tasks), ("topic", owned),
      ("topic_alias", owned), ("worktree_override", apps),
    ]
    let result = try scopes.map { table, filter in
      WorkspaceRemovalReport.Count(
        kind: table, count: try count(table, filter, id: id, in: db))
    }
    let claims = try count("task", owned + " AND claimed_by IS NOT NULL", id: id, in: db)
    return (result + [.init(kind: "claim", count: claims)]).sorted { $0.kind < $1.kind }
  }

  struct RemovedIDs {
    let tasks: [Int64]
    let docs: [Int64]
    let comments: [Int64]
  }

  static func rowIDs(_ id: Int64?, in db: Database) throws -> RemovedIDs {
    guard let id else { return .init(tasks: [], docs: [], comments: []) }
    func read(_ table: String, _ filter: String) throws -> [Int64] {
      try Int64.fetchAll(
        db, sql: "SELECT id FROM \(table) WHERE \(filter) ORDER BY id", arguments: ["ws": id])
    }
    return try RemovedIDs(
      tasks: read("task", owned), docs: read("doc", owned),
      comments: read("comment", "\(tasks) OR \(docRecords)"))
  }

  /// Replacement keeps the owner row, approval log and task/doc sequence namespaces.
  static func removeContents(_ id: Int64, in db: Database) throws {
    try db.execute(sql: "DELETE FROM link WHERE \(owned)", arguments: ["ws": id])
    try removeDocuments(id, in: db)
    try db.execute(
      sql: """
        DELETE FROM alias_decision WHERE \(owned);
        DELETE FROM review_request WHERE \(tasks);
        DELETE FROM comment WHERE \(tasks);
        DELETE FROM task_event WHERE \(tasks);
        DELETE FROM task_plan_rev WHERE \(tasks);
        DELETE FROM task WHERE \(owned);
        DELETE FROM worktree_override WHERE \(apps);
        DELETE FROM environment WHERE \(apps);
        DELETE FROM edge WHERE \(owned);
        DELETE FROM topic_alias WHERE \(owned);
        DELETE FROM source WHERE \(owned);
        DELETE FROM app WHERE \(owned);
        DELETE FROM repo_path WHERE \(repos);
        DELETE FROM repo WHERE \(owned);
        DELETE FROM service WHERE \(owned);
        DELETE FROM topic WHERE \(owned);
        """, arguments: ["ws": id])
  }

  static func removeDocuments(_ id: Int64, in db: Database) throws {
    try db.execute(
      sql: """
        DELETE FROM seq_counter WHERE \(commentSequences);
        DELETE FROM comment WHERE \(docRecords);
        DELETE FROM doc_verification WHERE \(docRecords);
        DELETE FROM doc_rev WHERE id IN (\(revisions));
        DELETE FROM doc WHERE \(owned);
        """, arguments: ["ws": id])
  }

  static func removeWorkspace(_ id: Int64, in tx: StorageTransaction) throws {
    let db = tx.database
    let rows = try rowIDs(id, in: db)
    try db.execute(
      sql: """
        DELETE FROM approval WHERE \(approvals);
        DELETE FROM meta WHERE key='current_workspace'
          AND value=(SELECT slug FROM workspace WHERE id=:ws);
        DELETE FROM seq_counter WHERE \(sequences);
        """, arguments: ["ws": id])
    try removeContents(id, in: db)
    try db.execute(sql: "DELETE FROM workspace WHERE id=?", arguments: [id])
    try tx.recordChange(kind: "workspace", rowID: id)
    for task in rows.tasks { try tx.recordChange(kind: "task", rowID: task) }
    for doc in rows.docs { try tx.recordChange(kind: "doc", rowID: doc) }
    for comment in rows.comments { try tx.recordChange(kind: "comment", rowID: comment) }
  }

  private static func count(_ table: String, _ filter: String, id: Int64, in db: Database) throws
    -> Int
  {
    try Int.fetchOne(
      db, sql: "SELECT count(*) FROM \(table) WHERE \(filter)", arguments: ["ws": id]) ?? 0
  }
}
