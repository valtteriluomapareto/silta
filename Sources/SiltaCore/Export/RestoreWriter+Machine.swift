import Foundation
import GRDB

extension RestoreWriter {
  /// Machine paths of the workspace now, keyed by the uid of the row they belong to.
  /// A worktree override, keyed by its app's uid.
  struct MachineOverride {
    let path: String
    let app: String
    let setBy: String
  }

  /// A task's worktree with the claim it was recorded for.
  struct MachineWorktree {
    let path: String
    let claimedBy: String?
    let branch: String?
  }

  struct MachineRows {
    var repoPaths: [Data: (path: String, fetched: String?)] = [:]
    var overrides: [MachineOverride] = []
    var worktrees: [Data: MachineWorktree] = [:]
  }

  func machineRows() throws -> MachineRows {
    var kept = MachineRows()
    guard let workspace else { return kept }
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT r.uid, p.path, p.fetched_at FROM repo_path p JOIN repo r ON r.id=p.repo_id
        WHERE r.workspace_id=?
        """,
      arguments: [workspace])
    {
      kept.repoPaths[Data((row["uid"] as String).utf8)] = (row["path"], row["fetched_at"])
    }
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT o.path, a.uid, o.set_by FROM worktree_override o JOIN app a ON a.id=o.app_id
        WHERE a.workspace_id=?
        """,
      arguments: [workspace])
    {
      kept.overrides.append(.init(path: row["path"], app: row["uid"], setBy: row["set_by"]))
    }
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT uid, worktree, claimed_by, branch FROM task
        WHERE workspace_id=? AND worktree IS NOT NULL
        """,
      arguments: [workspace])
    {
      kept.worktrees[Data((row["uid"] as String).utf8)] = .init(
        path: row["worktree"], claimedBy: row["claimed_by"], branch: row["branch"])
    }
    return kept
  }

  /// Puts machine paths back for rows the tree keeps; a task's worktree only while the
  /// tree has the same claim and branch.
  mutating func restore(_ kept: MachineRows) throws {
    for (uid, path) in kept.repoPaths {
      guard let repo = ids["repo"]?[uid] else { continue }
      try db.execute(
        sql: "INSERT INTO repo_path(repo_id,path,fetched_at) VALUES(?,?,?)",
        arguments: [repo, path.path, path.fetched])
    }
    for override in kept.overrides {
      guard let app = ids["app"]?[Data(override.app.utf8)] else { continue }
      try db.execute(
        sql: "INSERT INTO worktree_override(path,app_id,set_by) VALUES(?,?,?)",
        arguments: [override.path, app, override.setBy])
    }
    for task in tree.tasks {
      guard let uid = task.row.value("uid"), let kept = kept.worktrees[Data(uid.utf8)],
        kept.claimedBy == task.row.value("claimed_by"), kept.branch == task.row.value("branch"),
        let id = ids["task"]?[Data(uid.utf8)]
      else { continue }
      try db.execute(sql: "UPDATE task SET worktree=? WHERE id=?", arguments: [kept.path, id])
    }
    let section = zip(tree.sections, ExportFormat.sections).first { $0.1.table == "repo" }?.0
    reposWithoutPath = (section?.rows ?? []).compactMap { row in
      kept.repoPaths[Data((row.value("uid") ?? "").utf8)] == nil ? row.value("slug") : nil
    }
  }

  /// Compares literal incoming truth with only the explicit restore normalizations.
  func check(_ after: ExportSnapshot, revisionAllocations: [ExportRow]) throws {
    var expected = tree
    expected.format = after.format
    expected.schema = after.schema
    expected.workspace = tree.workspace.replacing(
      "next_task_seq", with: after.workspace.value("next_task_seq"),
      keys: ExportFormat.workspaceKeys)
    expected.approvals = after.approvals
    expected.documents.revisionAllocations = revisionAllocations
    let want = try expected.files()
    let got = try after.files()
    if let path = Set(want.keys).union(got.keys).filter({ want[$0] != got[$0] }).min(
      by: ExportSnapshot.byteOrder)
    {
      throw ExportError.invalidTree(
        reason: "\(path) does not come back the same after restoring", workspace: slug)
    }
  }

  /// Public readback uses the public source admission guard.
  func check() throws {
    try check(
      ExportSnapshot.read(db, workspace: slug),
      revisionAllocations: tree.documents.revisionAllocations)
  }
}
