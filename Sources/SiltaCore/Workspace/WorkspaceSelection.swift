import Foundation
import GRDB

/// Selects workspaces without invoking location inference.
package enum WorkspaceSelection {
  /// Uses an explicit slug, or the current workspace recorded in meta.
  package static func resolve(_ slug: String? = nil, in store: DatabaseStore) throws -> String {
    guard FileManager.default.fileExists(atPath: store.path) else { throw WorkspaceError.notFound }
    return try store.read { db in
      let selected =
        try slug ?? String.fetchOne(db, sql: "SELECT value FROM meta WHERE key='current_workspace'")
      guard let selected,
        try Bool.fetchOne(
          db, sql: "SELECT EXISTS(SELECT 1 FROM workspace WHERE slug=?)", arguments: [selected])
          == true
      else {
        throw WorkspaceError.notFound
      }
      return selected
    }
  }

  /// Stores an existing slug as the current workspace in one owned write.
  package static func use(_ slug: String, in store: DatabaseStore) throws {
    let selected = try resolve(slug, in: store)
    try store.write { transaction in
      try transaction.database.execute(
        sql: """
          INSERT INTO meta(key,value)
          VALUES('current_workspace',?)
          ON CONFLICT(key) DO UPDATE SET value=excluded.value
          """, arguments: [selected])
    }
  }

  /// Lists workspace display values without initializing a missing database.
  package static func list(in store: DatabaseStore) throws -> [WorkspaceSummary] {
    guard FileManager.default.fileExists(atPath: store.path) else { return [] }
    return try store.read {
      try Row.fetchAll($0, sql: "SELECT slug,name,task_prefix FROM workspace ORDER BY slug").map {
        WorkspaceSummary(slug: $0["slug"], name: $0["name"], taskPrefix: $0["task_prefix"])
      }
    }
  }
}

/// The workspace values exposed by the list command.
package struct WorkspaceSummary: Encodable, Sendable {
  /// Identifies the workspace in commands.
  package let slug: String

  /// Names the workspace for display.
  package let name: String

  /// Prefixes task references in the workspace.
  package let taskPrefix: String

  private enum CodingKeys: String, CodingKey {
    case slug, name
    case taskPrefix = "task_prefix"
  }
}
