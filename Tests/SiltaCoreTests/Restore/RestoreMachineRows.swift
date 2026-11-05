import Foundation
import GRDB
@testable import SiltaCore

/// The machine-local rows a restore of one workspace must keep, including another
/// workspace's: export never writes them, so only the database shows their loss.
enum RestoreMachineRows {
  /// The other workspace's repo path and the path of its worktree override.
  static let otherRepoPath = "/private/other/thumbnails"
  static let otherOverride = "/private/other/api-wt"

  /// What the database holds after a restore.
  struct Snapshot {
    /// The acme workspace's id.
    var workspaceID: Int64?
    /// Every repo path, the other workspace's included.
    var repoPaths: [String]
    /// Every worktree override path.
    var overrides: [String]
    /// The worktree of the task with seq 2.
    var worktree: String?
    /// The counter of the acme workspace.
    var next: Int?
    /// The other workspace's repo paths.
    var otherRepoPaths: [String]
    /// The other workspace's worktree overrides.
    var otherOverrides: [String]
  }

  /// Gives the other workspace a repo path and a worktree override.
  static func seed(_ store: DatabaseStore) throws {
    try DatabaseQueue(path: store.path).write { db in
      try db.execute(
        sql: """
          INSERT INTO repo_path(repo_id,path,fetched_at)
          SELECT id, ?, '2023-11-14T22:00:00.000Z' FROM repo
          WHERE uid='01HZREPO0000000000000OTHR';
          INSERT INTO worktree_override(path,app_id,set_by)
          SELECT ?, id, 'human:other' FROM app WHERE uid='01HZAPP00000000000000OTHR'
          """, arguments: [otherRepoPath, otherOverride])
    }
  }

  /// Every machine-local row there is now, and the other workspace's on their own.
  static func read(_ store: DatabaseStore) throws -> Snapshot {
    let row = try store.read { db in
      (
        try Int64.fetchOne(db, sql: "SELECT id FROM workspace WHERE slug='acme'"),
        try String.fetchAll(db, sql: "SELECT path FROM repo_path ORDER BY path"),
        try String.fetchAll(db, sql: "SELECT path FROM worktree_override ORDER BY path"),
        try String.fetchOne(db, sql: "SELECT worktree FROM task WHERE seq=2"),
        try Int.fetchOne(db, sql: "SELECT next FROM seq_counter WHERE scope='task:1'"),
        try String.fetchAll(
          db,
          sql: """
            SELECT p.path FROM repo_path p JOIN repo r ON r.id=p.repo_id
            JOIN workspace w ON w.id=r.workspace_id WHERE w.slug='other'
            """),
        try String.fetchAll(
          db,
          sql: """
            SELECT o.path FROM worktree_override o JOIN app a ON a.id=o.app_id
            JOIN workspace w ON w.id=a.workspace_id WHERE w.slug='other'
            """)
      )
    }
    return Snapshot(
      workspaceID: row.0, repoPaths: row.1, overrides: row.2, worktree: row.3, next: row.4,
      otherRepoPaths: row.5, otherOverrides: row.6)
  }
}
