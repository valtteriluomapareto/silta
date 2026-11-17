import Foundation
import GRDB

/// Typed map data read from one workspace transaction.
package struct WorkspaceMap: Sendable {
  /// App properties used by the viewer.
  package struct App: Sendable {
    /// App identity.
    package let slug: String
    /// Display name.
    package let name: String
    /// Repository slug.
    package let repo: String
    /// Development ref.
    package let ref: String
    /// Optional production ref.
    package let productionRef: String?
    /// Optional repository subdirectory.
    package let subpath: String?
    /// Purpose.
    package let summary: String?
    /// Stored lifecycle.
    package let lifecycle: String
  }

  /// External service properties.
  package struct Service: Sendable {
    /// Service identity.
    package let slug: String
    /// Display name.
    package let name: String
    /// Purpose.
    package let summary: String?
    /// Canonical typed attachment.
    package let attachment: String
  }

  /// A directed connection and its canonical attachment.
  package struct Connection: Sendable {
    /// Canonical typed attachment.
    package let attachment: String
    /// Source app slug.
    package let source: String
    /// Target app slug or service-prefixed slug.
    package let target: String
    /// Connection kind.
    package let kind: String
    /// Purpose.
    package let summary: String
    /// App-relative code references.
    package let codeReferences: [String]
  }

  /// Apps in slug order.
  package let apps: [App]
  /// Services in slug order.
  package let services: [Service]
  /// Connections in source, target and kind order.
  package let connections: [Connection]

  /// Reads existing map rows without initializing storage or rendering an editing format.
  package static func read(workspace: String, in store: DatabaseStore) throws -> Self {
    try store.read { db in
      guard
        let id = try Int64.fetchOne(
          db, sql: "SELECT id FROM workspace WHERE slug=?", arguments: [workspace])
      else {
        throw WorkspaceError.unknown(workspace)
      }
      return Self(
        apps: try apps(in: db, workspace: id),
        services: try services(in: db, workspace: id),
        connections: try connections(in: db, workspace: id))
    }
  }

  private static func apps(in db: Database, workspace: Int64) throws -> [App] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT app.*,repo.slug AS repo_slug FROM app JOIN repo ON repo.id=app.repo_id
        WHERE app.workspace_id=? ORDER BY app.slug
        """, arguments: [workspace]
    ).map { row in
      App(
        slug: row["slug"], name: row["name"], repo: row["repo_slug"], ref: row["ref"],
        productionRef: row["prod_ref"], subpath: row["subpath"], summary: row["summary"],
        lifecycle: row["lifecycle"])
    }
  }

  private static func services(in db: Database, workspace: Int64) throws -> [Service] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT CAST(slug AS BLOB) AS slug,name,summary FROM service
        WHERE workspace_id=? ORDER BY slug
        """, arguments: [workspace]
    ).map { row in
      guard let slug = try row.strictText("slug") else { throw StorageError.corrupt }
      return Service(
        slug: slug, name: row["name"], summary: row["summary"],
        attachment: "service:" + TaskLinkTarget.encodeComponent(slug))
    }
  }

  private static func connections(in db: Database, workspace: Int64) throws -> [Connection] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT a.slug AS source,b.slug AS app,CAST(s.slug AS BLOB) AS service,
          CAST(edge.kind AS BLOB) AS kind,edge.summary,edge.code_refs,
          COALESCE(b.slug,'service:'||s.slug) AS target
        FROM edge JOIN app a ON a.id=edge.from_app_id
        LEFT JOIN app b ON b.id=edge.to_app_id LEFT JOIN service s ON s.id=edge.to_service_id
        WHERE edge.workspace_id=? ORDER BY source,target,edge.kind
        """, arguments: [workspace]
    ).map { row in
      guard let kind = try row.strictText("kind") else { throw StorageError.corrupt }
      let source: String = row["source"]
      let service = try row.strictText("service")
      let app: String? = row["app"]
      guard let target = service.map({ "service:" + $0 }) ?? app,
        let encodedTarget = service.map({ "service:" + TaskLinkTarget.encodeComponent($0) })
          ?? app
      else { throw StorageError.corrupt }
      let code: String = row["code_refs"]
      let references: [String]
      do { references = try JSONDecoder().decode([String].self, from: Data(code.utf8)) } catch {
        throw StorageError.corrupt
      }
      return Connection(
        attachment: "edge:" + source + "/" + encodedTarget + "/"
          + TaskLinkTarget.encodeComponent(kind),
        source: source, target: target, kind: kind, summary: row["summary"],
        codeReferences: references)
    }
  }
}
