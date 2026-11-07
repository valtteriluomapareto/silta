package import Foundation
import GRDB

/// Selects an existing workspace from explicit, stored or repository context.
package enum WorkspaceSelection {
  /// Captures the current selection, or infers a unique workspace from Git common-directory
  /// identity. Missing storage or an unregistered location returns nil without writes.
  /// Stale current selections refuse; multiple matching workspaces are ambiguous.
  package static func fallback(path: URL, environment: SiltaEnvironment) async throws -> String? {
    let store = environment.db
    guard FileManager.default.fileExists(atPath: store.path) else { return nil }
    let current = try store.read { db in
      let selected = try String.fetchOne(
        db, sql: "SELECT value FROM meta WHERE key='current_workspace'")
      if let selected,
        try Bool.fetchOne(
          db, sql: "SELECT EXISTS(SELECT 1 FROM workspace WHERE slug=?)",
          arguments: [selected]) != true
      {
        throw WorkspaceError.notFound
      }
      return selected
    }
    if let current { return current }
    let repositories = try LocationRepository.all(workspace: nil, in: store)
    guard !repositories.isEmpty else { return nil }
    let directory = try LocationPath.canonical(path)
    guard
      let common = try await LocationGit(runner: environment.git, directory: directory)
        .commonDirectory()
    else { return nil }
    var workspaces = Set<String>()
    for repository in repositories {
      guard FileManager.default.fileExists(atPath: repository.path) else { continue }
      let registered = LocationGit(
        runner: environment.git, directory: URL(filePath: repository.path))
      let expected = try? await registered.commonDirectory()  // Skip stale registrations.
      if expected == common { workspaces.insert(repository.workspace) }
    }
    guard workspaces.count <= 1 else { throw WorkspaceError.ambiguous(workspaces.sorted()) }
    return workspaces.first
  }

  /// Uses an explicit slug, or the current workspace recorded in meta. A slug that names
  /// no workspace is `unknown`, so the refusal names it.
  package static func resolve(_ slug: String? = nil, in store: DatabaseStore) throws -> String {
    let missing = slug.map(WorkspaceError.unknown) ?? .notFound
    guard FileManager.default.fileExists(atPath: store.path) else { throw missing }
    return try store.read { db in
      let selected =
        try slug ?? String.fetchOne(db, sql: "SELECT value FROM meta WHERE key='current_workspace'")
      guard let selected,
        try Bool.fetchOne(
          db, sql: "SELECT EXISTS(SELECT 1 FROM workspace WHERE slug=?)", arguments: [selected])
          == true
      else {
        throw missing
      }
      return selected
    }
  }

  /// Reads an existing app identity for diagnostics without initializing storage.
  package static func app(_ slug: String, workspace: String, in store: DatabaseStore) throws
    -> String?
  {
    try store.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT app.slug
          FROM app
          JOIN workspace ON workspace.id=app.workspace_id
          WHERE workspace.slug=? AND app.slug=?
          """, arguments: [workspace, slug])
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
