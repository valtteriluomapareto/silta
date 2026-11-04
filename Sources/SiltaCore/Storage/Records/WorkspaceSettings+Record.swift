import Foundation
import GRDB

extension WorkspaceSettings {
  /// Reads policy on the supplied connection so writes decide against their own snapshot.
  /// Malformed known values refuse the operation; defaults never loosen invalid policy.
  static func read(workspaceID: Int64, in db: Database) throws -> WorkspaceSettings {
    guard
      let json = try String.fetchOne(
        db, sql: "SELECT settings FROM workspace WHERE id=?", arguments: [workspaceID])
    else { throw StorageError.unavailable }
    return try JSONDecoder().decode(WorkspaceSettings.self, from: Data(json.utf8))
  }
}
