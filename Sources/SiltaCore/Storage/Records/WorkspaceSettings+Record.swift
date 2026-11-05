import GRDB

extension WorkspaceSettings {
  /// Reads policy on the supplied connection so writes decide against their own snapshot.
  /// Each typed getter validates only its own key, with workspace-scoped recovery.
  static func read(workspaceID: Int64, in db: Database) throws -> WorkspaceSettings {
    guard
      let row = try Row.fetchOne(
        db, sql: "SELECT slug,settings FROM workspace WHERE id=?", arguments: [workspaceID])
    else { throw StorageError.corrupt }
    return WorkspaceSettings(workspace: row["slug"], json: row["settings"])
  }
}
