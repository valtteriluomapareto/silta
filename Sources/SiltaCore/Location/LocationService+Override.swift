package import Foundation
import GRDB

extension LocationService {
  /// Changes this worktree's filtered app decision and approval atomically.
  /// A read-proven no-op bypasses truth writes; mutation races are checked again in the write.
  package func override(
    path: URL, workspace: String? = nil, app: String?, approved: String? = nil
  ) async throws -> (result: LocationResult, approvalUsed: Bool) {
    let context = try await inspect(path: path, workspace: workspace)
    let repo = context.repo
    if let app { try validate(app, candidates: context.candidates, repo: repo, path: context.path) }
    let selected = context.candidates.first { $0.app == app }?.id
    let before = try environment.db.read { try Self.overrideID(context.root, in: $0) }
    var result = try await resolve(context, app: app, task: nil, ignoringOverride: true)
    if app != nil { result.reason = result.candidates.count == 1 ? "single" : "override" }
    result.overrideChanged = false
    guard before != selected else { return (result, false) }
    let command =
      "silta --ws " + shellWord(repo.workspace) + " where --path "
      + shellWord(context.path.path) + (app.map { " --set " + shellWord($0) } ?? " --unset")
    let change = try writeOverride(context, appID: selected, command: command, approved: approved)
    result.overrideChanged = change.changed
    return (result, change.approvalUsed)
  }

  static func overrideID(_ root: URL, in db: Database) throws -> Int64? {
    try Int64.fetchOne(
      db, sql: "SELECT app_id FROM worktree_override WHERE path=?",
      arguments: [root.path])
  }

  private func writeOverride(
    _ context: LocationContext, appID: Int64?, command: String, approved: String?
  ) throws -> (changed: Bool, approvalUsed: Bool) {
    let repo = context.repo
    return try environment.db.write { tx in
      let current = try LocationRepository.read(workspace: repo.workspace, in: tx.database)
      guard current.contains(repo) else {
        throw LocationError.changed(workspace: repo.workspace, path: context.path.path)
      }
      guard try Self.overrideID(context.root, in: tx.database) != appID else {
        return (false, false)
      }
      let approval = try environment.actor.requireHuman(command: command, approved: approved)
      if let appID {
        try tx.database.execute(
          sql: """
            INSERT INTO worktree_override(path,app_id,set_by) VALUES(?,?,?)
            ON CONFLICT(path) DO UPDATE SET app_id=excluded.app_id,set_by=excluded.set_by
            """, arguments: [context.root.path, appID, environment.actor.description])
      } else {
        try tx.database.execute(
          sql: "DELETE FROM worktree_override WHERE path=?",
          arguments: [context.root.path])
      }
      try tx.recordChange(kind: "worktree_override", rowID: repo.id)
      try approval?.record(
        command: command, workspace: repo.workspace,
        identity: (environment.ids, environment.clock.now()), in: tx)
      return (true, approval != nil)
    }
  }
}
