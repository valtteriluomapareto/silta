import Foundation
import GRDB

/// The replace inside the restore's transaction: checks against the database, the
/// report, the delete and inserts with ids mapped by uid, and the self-check.
struct RestoreWriter {
  let tx: StorageTransaction
  let tree: ExportSnapshot
  let slug: String

  var approvalsAdded = 0
  var reposWithoutPath: [String] = []
  var workspace: Int64?
  var current: ExportSnapshot?
  var ids: [String: [String: Int64]] = [:]
  var revisions: [String: Int64] = [:]

  init(tx: StorageTransaction, tree: ExportSnapshot, slug: String) {
    self.tx = tx
    self.tree = tree
    self.slug = slug
  }

  var db: Database { tx.database }

  /// Refuses what the database can't take, before anything changes, and reports the
  /// difference between the workspace now and the tree.
  mutating func prepare(digest: String, dryRun: Bool) throws -> RestoreReport {
    if try StorageSchema.migrator.hasBeenSuperseded(db) { throw StorageError.schemaTooNew }
    workspace = try Int64.fetchOne(
      db, sql: "SELECT id FROM workspace WHERE slug=?", arguments: [slug])
    current = try workspace.map { _ in try ExportSnapshot.read(db, workspace: slug) }
    let uid = tree.workspace.value("uid") ?? ""
    let prefix = tree.workspace.value("task_prefix") ?? ""
    if let other = try String.fetchOne(
      db, sql: "SELECT slug FROM workspace WHERE (uid=? OR task_prefix=?) AND slug<>?",
      arguments: [uid, prefix, slug])
    {
      throw ExportError.restoreConflict(
        "workspace \(other) already has the tree's uid or task prefix")
    }
    try checkForeignUIDs()
    return RestoreReport.between(current, tree, workspace: slug, digest: digest, dryRun: dryRun)
  }

  /// A uid of the tree that a row of another workspace holds; uids are unique across
  /// the database.
  func checkForeignUIDs() throws {
    var uids: [String: [String]] = [:]
    for (section, format) in zip(tree.sections, ExportFormat.sections) {
      uids[format.table, default: []] += section.rows.compactMap { $0.value("uid") }
    }
    uids["task"] = tree.tasks.compactMap { $0.row.value("uid") }
    uids["comment"] = tree.tasks.flatMap {
      $0.records.compactMap { $0.value("table") == "comment" ? $0.value("uid") : nil }
    }
    uids["doc"] = tree.documents.documents.compactMap { $0.row.value("uid") }
    for record in tree.documents.documents.flatMap(\.records) {
      if let table = record.value("table"), let uid = record.value("uid") {
        uids[table, default: []].append(uid)
      }
    }
    uids["link"] = tree.links.compactMap { $0.value("uid") }
    let ownership = [
      "environment": "app_id IN (SELECT id FROM app WHERE workspace_id IS :ws)",
      "doc_rev": "doc_id IN (SELECT id FROM doc WHERE workspace_id IS :ws)",
      "doc_verification": """
      doc_rev_id IN (SELECT r.id FROM doc_rev r JOIN doc d ON d.id=r.doc_id
      WHERE d.workspace_id IS :ws)
      """,
      "comment": """
      task_id IN (SELECT id FROM task WHERE workspace_id IS :ws)
      OR doc_rev_id IN (SELECT r.id FROM doc_rev r JOIN doc d ON d.id=r.doc_id
      WHERE d.workspace_id IS :ws)
      """,
    ]
    try checkApprovalUIDs()
    for (table, list) in uids.sorted(by: { $0.key < $1.key }) where !list.isEmpty {
      let mine = ownership[table] ?? "workspace_id IS :ws"
      let json = "[" + list.map(ExportFormat.quote).joined(separator: ",") + "]"
      if let uid = try String.fetchOne(
        db,
        sql:
          """
          SELECT uid FROM \(table) WHERE uid COLLATE BINARY IN (SELECT value FROM json_each(:uids))
          AND (\(mine)) IS NOT TRUE
          """,
        arguments: ["uids": json, "ws": workspace])
      {
        throw ExportError.restoreConflict("\(table) uid \(uid) belongs to another workspace")
      }
    }
  }

  private func checkApprovalUIDs() throws {
    let approvals =
      "["
      + tree.approvals.compactMap { $0.value("uid") }.map(ExportFormat.quote)
      .joined(separator: ",") + "]"
    if let uid = try String.fetchOne(
      db,
      sql: """
        SELECT uid FROM approval WHERE uid IN (SELECT value FROM json_each(?))
        AND workspace IS NOT ?
        """, arguments: [approvals, slug])
    {
      throw ExportError.restoreConflict("approval uid \(uid) belongs to another workspace")
    }
  }

  /// Deletes the workspace's rows, approvals aside, and inserts the tree's. A rule of
  /// the database the validation didn't foresee refuses the tree rather than failing as
  /// a storage error.
  mutating func replace() throws {
    do {
      try replaceRows()
    } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
      throw ExportError.invalidTree(
        reason: "it breaks a uniqueness or reference rule of the database", workspace: slug)
    }
  }

  private mutating func replaceRows() throws {
    let kept = try machineRows()
    let old = try removedIDs()
    if let workspace { try delete(workspace) }
    let row = tree.workspace
    if let workspace {
      try db.execute(
        sql: "UPDATE workspace SET uid=?, name=?, task_prefix=?, settings=? WHERE id=?",
        arguments: [
          row.value("uid"), row.value("name"), row.value("task_prefix"),
          row.value("settings") ?? "{}", workspace,
        ])
    } else {
      try db.execute(
        sql: "INSERT INTO workspace(uid,slug,name,task_prefix,settings) VALUES(?,?,?,?,?)",
        arguments: [
          row.value("uid"), slug, row.value("name"), row.value("task_prefix"),
          row.value("settings") ?? "{}",
        ])
      workspace = db.lastInsertedRowID
    }
    let id = workspace ?? 0
    for (section, format) in zip(tree.sections, ExportFormat.sections) {
      for row in section.rows {
        try insert(
          format.table, row, extra: format.table == "environment" ? [:] : ["workspace_id": id])
      }
    }
    try insertTasks(workspace: id)
    try insertLinks(workspace: id)
    for row in tree.aliasDecisions {
      try insert("alias_decision", row, extra: ["workspace_id": id])
    }
    try mergeApprovals()
    try counter(workspace: id)
    try restore(kept)
    try tx.recordChange(kind: "workspace", rowID: id)
    let new = (ids["task"]?.values.sorted() ?? [], ids["comment"]?.values.sorted() ?? [])
    for task in old.tasks + new.0 { try tx.recordChange(kind: "task", rowID: task) }
    for doc in old.docs + (ids["doc"]?.values.sorted() ?? []) {
      try tx.recordChange(kind: "doc", rowID: doc)
    }
    for comment in old.comments + new.1 { try tx.recordChange(kind: "comment", rowID: comment) }
  }

  struct RowIDs {
    var tasks: [Int64]
    var docs: [Int64]
    var comments: [Int64]
  }

  /// Owned row ids removed by replacement, for the change log.
  func removedIDs() throws -> RowIDs {
    RowIDs(
      tasks: try Int64.fetchAll(
        db, sql: "SELECT id FROM task WHERE workspace_id IS ?", arguments: [workspace]),
      docs: try Int64.fetchAll(
        db, sql: "SELECT id FROM doc WHERE workspace_id IS ? ORDER BY id", arguments: [workspace]),
      comments: try Int64.fetchAll(
        db,
        sql:
          """
          SELECT id FROM comment
          WHERE task_id IN (SELECT id FROM task WHERE workspace_id IS :ws)
            OR doc_rev_id IN (SELECT r.id FROM doc_rev r JOIN doc d ON d.id=r.doc_id
              WHERE d.workspace_id IS :ws)
          ORDER BY id
          """,
        arguments: ["ws": workspace])
    )
  }

  private func delete(_ workspace: Int64) throws {
    let tasks = "task_id IN (SELECT id FROM task WHERE workspace_id=:ws)"
    let apps = "app_id IN (SELECT id FROM app WHERE workspace_id=:ws)"
    try db.execute(
      sql: """
        DELETE FROM link WHERE workspace_id=:ws;
        DELETE FROM alias_decision WHERE workspace_id=:ws;
        DELETE FROM review_request WHERE \(tasks);
        DELETE FROM comment WHERE \(tasks);
        DELETE FROM task_event WHERE \(tasks);
        DELETE FROM task_plan_rev WHERE \(tasks);
        DELETE FROM task WHERE workspace_id=:ws;
        DELETE FROM worktree_override WHERE \(apps);
        DELETE FROM environment WHERE \(apps);
        DELETE FROM edge WHERE workspace_id=:ws;
        DELETE FROM topic_alias WHERE workspace_id=:ws;
        DELETE FROM source WHERE workspace_id=:ws;
        DELETE FROM app WHERE workspace_id=:ws;
        DELETE FROM repo_path WHERE repo_id IN (SELECT id FROM repo WHERE workspace_id=:ws);
        DELETE FROM repo WHERE workspace_id=:ws;
        DELETE FROM service WHERE workspace_id=:ws;
        DELETE FROM topic WHERE workspace_id=:ws;
        """, arguments: ["ws": workspace])
  }
}
