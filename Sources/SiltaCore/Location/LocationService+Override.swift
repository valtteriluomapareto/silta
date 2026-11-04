package import Foundation
import GRDB

extension LocationService {
  /// Stores or removes the exact canonical path's human decision and its approval
  /// atomically. Git is inspected before the write; configuration is checked again in it.
  package func override(
    path: URL, workspace: String? = nil, app: String?, approved: String? = nil
  ) async throws -> (result: LocationResult, approvalUsed: Bool) {
    let context = try await inspect(path: path, workspace: workspace)
    let repo = context.repo
    if let app { try validate(app, candidates: context.candidates, repo: repo, path: context.path) }
    let command =
      "silta --ws " + shellWord(repo.workspace) + " where --path "
      + shellWord(context.path.path) + (app.map { " --set " + shellWord($0) } ?? " --unset")
    let approval = try environment.actor.requireHuman(command: command, approved: approved)
    var result = try await resolve(
      context, app: app, task: nil, ignoringOverride: true)
    if app != nil { result.reason = result.candidates.count == 1 ? "single" : "override" }
    let approvalUsed = try environment.db.write { tx in
      let current = try LocationRepository.read(workspace: repo.workspace, in: tx.database)
      guard current.contains(repo) else {
        throw LocationError.changed(workspace: repo.workspace, path: context.path.path)
      }
      if let selected = context.candidates.first(where: { $0.app == app }) {
        try tx.database.execute(
          sql: """
            INSERT INTO worktree_override(path,app_id,set_by) VALUES(?,?,?)
            ON CONFLICT(path) DO UPDATE SET app_id=excluded.app_id,set_by=excluded.set_by
            """, arguments: [context.path.path, selected.id, environment.actor.description])
      } else {
        try tx.database.execute(
          sql: "DELETE FROM worktree_override WHERE path=?",
          arguments: [context.path.path])
      }
      try tx.recordChange(kind: "worktree_override", rowID: repo.id)
      try approval?.record(
        command: command, workspace: repo.workspace,
        identity: (environment.ids, environment.clock.now()), in: tx)
      return approval != nil
    }
    return (result, approvalUsed)
  }
}
