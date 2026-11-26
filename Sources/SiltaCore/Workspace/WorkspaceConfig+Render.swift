import Foundation
package import GRDB

extension WorkspaceConfig {
  /// Renders the known editing fields in deterministic YAML, excluding machine-local paths.
  package static func render(from db: Database, slug: String) throws -> String {
    guard
      let workspace = try Row.fetchOne(
        db,
        sql: "SELECT * FROM workspace WHERE slug=?", arguments: [slug])
    else {
      throw WorkspaceError.notFound
    }
    var renderer = WorkspaceRenderer(db: db, id: workspace["id"])
    return try renderer.render(workspace: workspace, slug: slug)
  }
}

private struct WorkspaceRenderer {
  let db: Database

  let id: Int64

  var output = ""

  mutating func render(workspace: Row, slug: String) throws -> String {
    output =
      "workspace: "
      + (try WorkspaceConfig.json([
        "slug": slug, "name": workspace["name"] as String,
        "task_prefix": workspace["task_prefix"] as String,
      ])) + "\n"
    let settingsText: String = workspace["settings"]
    let stored: Any
    do {
      stored = try JSONSerialization.jsonObject(
        with: Data(settingsText.utf8), options: .fragmentsAllowed)
    } catch {
      stored = settingsText
    }
    let settings: Any
    if let mapping = stored as? [String: Any] {
      settings = mapping.filter { (WorkspaceConfig.fields["settings"] ?? []).contains($0.key) }
    } else {
      // Preserve corrupt settings visibly so the editing view can be used for repair.
      settings = stored
    }
    output +=
      "settings: "
      + (try WorkspaceConfig.json(settings))
      + "\n"
    renderRetiredSlugs(stored)
    try renderAppsAndRepos()
    try renderRelationships()
    return output
  }

  private mutating func renderRetiredSlugs(_ settings: Any) {
    guard let mapping = settings as? [String: Any],
      let retired = try? WorkspaceSlugs.retired(mapping)  // Keep malformed maps inspectable.
    else { return }
    for kind in WorkspaceSlugs.Kind.allCases {
      guard let names = retired[kind.rawValue], !names.isEmpty else { continue }
      output +=
        "# Retired \(kind.rawValue) slugs: "
        + names.sorted().map(TaskError.shown)
        .joined(separator: ", ") + "\n"
    }
  }

  mutating func section(_ name: String, _ rows: [Any]) throws {
    section(name, encodedRows: try rows.map(WorkspaceConfig.json))
  }

  private mutating func section(_ name: String, encodedRows: [String]) {
    if encodedRows.isEmpty {
      output += "\(name): []\n"
    } else {
      output += "\(name):\n" + encodedRows.map { "  - " + $0 + "\n" }.joined()
    }
  }
  func query(_ sql: String, fields: [String: String], arrays: [String] = []) throws -> [[String:
    Any]]
  {
    try Row.fetchAll(db, sql: sql, arguments: [id]).map { row in
      var value: [String: Any] = [:]
      for (key, column) in fields {
        let stored: DatabaseValue = row[column]
        let text: String?
        if case .blob = stored.storage {
          text = try row.strictText(column)
        } else {
          text = row[column]
        }
        if let text {
          value[key] =
            arrays.contains(key) ? try JSONSerialization.jsonObject(with: Data(text.utf8)) : text
        }
      }
      return value
    }
  }
  mutating func renderAppsAndRepos() throws {
    try section(
      "repos",
      query(
        """
        SELECT slug,remote_url FROM repo
        WHERE workspace_id=?
        ORDER BY slug
        """, fields: ["slug": "slug", "remote": "remote_url"]))
    try renderApps()
    try section(
      "environments",
      query(
        """
        SELECT environment.*,app.slug AS app_slug FROM environment
        JOIN app ON app.id=environment.app_id
        WHERE app.workspace_id=?
        ORDER BY app.slug,environment.name
        """, fields: ["app": "app_slug", "name": "name", "url": "url"]))
    try section(
      "services",
      Row.fetchAll(
        db,
        sql: """
          SELECT CAST(slug AS BLOB) AS slug FROM service
          WHERE workspace_id=?
          ORDER BY service.slug
          """, arguments: [id]
      ).map {
        guard let slug = try $0.strictText("slug") else { throw StorageError.corrupt }
        return slug
      })
  }

  private mutating func renderApps() throws {
    // YAML folds some raw scalars that the JSON encoder leaves intact.
    let apps = try query(
      """
      SELECT app.*,NULLIF(app.name,app.slug) AS display_name,repo.slug AS repo_slug FROM app
      JOIN repo ON repo.id=app.repo_id
      WHERE app.workspace_id=?
      ORDER BY app.slug
      """,
      fields: [
        "slug": "slug", "name": "display_name", "repo": "repo_slug", "ref": "ref",
        "prod_ref": "prod_ref", "subpath": "subpath", "summary": "summary",
        "lifecycle": "lifecycle", "previous": "previous_slugs",
      ], arrays: ["previous"]
    ).map { row in
      let fields = row.keys.sorted().compactMap { key -> String? in
        if let list = row[key] as? [String], !list.isEmpty {
          return ExportFormat.quote(key) + ":["
            + list.map(ExportFormat.quote).joined(separator: ",") + "]"
        }
        guard let value = row[key] as? String, key != "lifecycle" || value != "active" else {
          return nil
        }
        return ExportFormat.quote(key) + ":" + ExportFormat.quote(value)
      }
      return "{" + fields.joined(separator: ",") + "}"
    }
    section("apps", encodedRows: apps)
  }

  mutating func renderRelationships() throws {
    try section(
      "edges",
      query(
        """
        SELECT CAST(edge.kind AS BLOB) AS kind,edge.summary,edge.code_refs,a.slug AS from_slug,
          CAST(COALESCE(b.slug,'service:'||s.slug) AS BLOB) AS to_slug FROM edge
        JOIN app a ON a.id=edge.from_app_id
        LEFT JOIN app b ON b.id=edge.to_app_id
        LEFT JOIN service s ON s.id=edge.to_service_id
        WHERE edge.workspace_id=?
        ORDER BY from_slug,to_slug,kind
        """,
        fields: [
          "from": "from_slug", "to": "to_slug", "kind": "kind", "summary": "summary",
          "code": "code_refs",
        ], arrays: ["code"]
      ).map {
        var row = $0
        if (row["code"] as? [String])?.isEmpty == true { row.removeValue(forKey: "code") }
        return row
      })
    try renderTopicsAndSources()
  }

  mutating func renderTopicsAndSources() throws {
    var topics = try query(
      """
      SELECT slug,id,previous_slugs FROM topic
      WHERE workspace_id=?
      ORDER BY slug
      """, fields: ["slug": "slug", "previous": "previous_slugs"], arrays: ["previous"])
    for index in topics.indices where (topics[index]["previous"] as? [String])?.isEmpty == true {
      topics[index].removeValue(forKey: "previous")
    }
    for index in topics.indices {
      topics[index]["aliases"] = try String.fetchAll(
        db,
        sql: """
          SELECT alias FROM topic_alias
          JOIN topic ON topic.id=topic_alias.topic_id
          WHERE topic.workspace_id=? AND topic.slug=?
          ORDER BY alias
          """, arguments: [id, topics[index]["slug"] as? String])
    }
    try section("topics", topics)
    try section(
      "sources",
      query(
        """
        SELECT * FROM source
        WHERE workspace_id=?
        ORDER BY kind,root
        """, fields: ["kind": "kind", "root": "root", "include": "include", "exclude": "exclude"],
        arrays: ["include", "exclude"]
      ).map {
        var row = $0
        if (row["exclude"] as? [String])?.isEmpty == true { row.removeValue(forKey: "exclude") }
        return row
      })
  }
}
