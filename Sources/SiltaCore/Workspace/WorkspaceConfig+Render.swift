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
    let settings =
      (try JSONSerialization.jsonObject(with: Data(settingsText.utf8)) as? [String: Any]) ?? [:]
    output +=
      "settings: "
      + (try WorkspaceConfig.json(
        settings.filter { (WorkspaceConfig.fields["settings"] ?? []).contains($0.key) }))
      + "\n"
    try renderAppsAndRepos()
    try renderRelationships()
    return output
  }

  mutating func section(_ name: String, _ rows: [Any]) throws {
    if rows.isEmpty {
      output += "\(name): []\n"
    } else {
      output +=
        "\(name):\n" + (try rows.map { "  - " + (try WorkspaceConfig.json($0)) + "\n" }.joined())
    }
  }
  func query(_ sql: String, fields: [String: String], arrays: [String] = []) throws -> [[String:
    Any]]
  {
    try Row.fetchAll(db, sql: sql, arguments: [id]).map { row in
      var value: [String: Any] = [:]
      for (key, column) in fields {
        if let text: String = row[column] {
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
    try section(
      "apps",
      query(
        """
        SELECT app.*,repo.slug AS repo_slug FROM app
        JOIN repo ON repo.id=app.repo_id
        WHERE app.workspace_id=?
        ORDER BY app.slug
        """,
        fields: [
          "slug": "slug", "repo": "repo_slug", "ref": "ref", "prod_ref": "prod_ref",
          "subpath": "subpath", "summary": "summary", "lifecycle": "lifecycle",
        ]
      ).map {
        var row = $0
        if row["lifecycle"] as? String == "active" { row.removeValue(forKey: "lifecycle") }
        return row
      })
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
      String.fetchAll(
        db,
        sql: """
          SELECT slug FROM service
          WHERE workspace_id=?
          ORDER BY slug
          """, arguments: [id]))
  }

  mutating func renderRelationships() throws {
    try section(
      "edges",
      query(
        """
        SELECT edge.*,a.slug AS from_slug,COALESCE(b.slug,'service:'||s.slug) AS to_slug FROM edge
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
      SELECT slug,id FROM topic
      WHERE workspace_id=?
      ORDER BY slug
      """, fields: ["slug": "slug"])
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
