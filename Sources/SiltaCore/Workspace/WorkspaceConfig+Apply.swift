package import Foundation
import GRDB
import Yams

extension WorkspaceConfig {
  /// Applies the complete editing view in the caller's single write transaction.
  /// Keeps retained identities and unknown columns; referenced deletions throw conflict.
  package func apply(in transaction: StorageTransaction, ids: any IDGenerator, at date: Date) throws
  {
    var writer = WorkspaceWriter(config: self, db: transaction.database, ids: ids, date: date)
    do {
      try writer.apply()
      try transaction.recordChange(kind: "workspace", rowID: writer.workspace)
    } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
      throw WorkspaceError.conflict
    }
  }

  static func json(_ value: Any) throws -> String {
    let bytes = try JSONSerialization.data(
      withJSONObject: value,
      options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    guard let result = String(data: bytes, encoding: .utf8) else {
      throw StorageError.internalMisuse
    }
    return result
  }
}

private struct WorkspaceWriter {
  let config: WorkspaceConfig

  let db: Database

  let ids: any IDGenerator

  let date: Date

  var workspace: Int64 = 0

  var kept: [String: Set<Int64>] = [:]

  var repos: [String: Int64] = [:]

  var apps: [String: Int64] = [:]

  var services: [String: Int64] = [:]

  mutating func apply() throws {
    var settings: [String: Any] = [:]
    if let old = try String.fetchOne(
      db, sql: "SELECT settings FROM workspace WHERE slug=?", arguments: [config.slug])
    {
      do {
        settings =
          (try JSONSerialization.jsonObject(
            with: Data(old.utf8), options: .fragmentsAllowed) as? [String: Any]) ?? [:]
      } catch {
        // A validated replacement can repair corrupt JSON with no recoverable mapping.
        settings = [:]
      }
    }
    for key in WorkspaceConfig.fields["settings"] ?? [] { settings.removeValue(forKey: key) }
    for (key, value) in config.root["settings"]?.mapping ?? Node.Mapping([]) {
      settings[key.string ?? ""] = value.any
    }
    workspace = try save(
      table: "workspace", identity: ["slug": config.slug.databaseValue],
      values: [
        "name": text(config.root["workspace"], "name"),
        "task_prefix": text(config.root["workspace"], "task_prefix"),
        "settings": try WorkspaceConfig.json(settings).databaseValue,
      ])

    try applyReposAppsAndEnvironments()
    try applyEdgesTopicsAndSources()
    try deleteMissing()
  }

  mutating func applyReposAppsAndEnvironments() throws {
    for repo in config.rows("repos") {
      repos[repo["slug"]?.string ?? ""] = try persist(
        "repo",
        identity: [
          "workspace_id": workspace.databaseValue, "slug": text(repo, "slug"),
        ], values: ["remote_url": text(repo, "remote")])
    }
    // Release the uniqueness slot while a valid configuration swaps refs between apps.
    try db.execute(
      sql: "UPDATE app SET is_primary=0 WHERE workspace_id=?", arguments: [workspace])
    for app in config.rows("apps") {
      apps[app["slug"]?.string ?? ""] = try persist(
        "app",
        identity: [
          "workspace_id": workspace.databaseValue, "slug": text(app, "slug"),
        ],
        values: [
          "name": text(app, "slug"), "repo_id": repos[app["repo"]?.string ?? ""].databaseValue,
          "ref": text(app, "ref"), "prod_ref": text(app, "prod_ref"),
          "subpath": text(app, "subpath"),
          "summary": text(app, "summary"),
          "lifecycle": (app["lifecycle"]?.string ?? "active").databaseValue,
          "is_primary": (app["subpath"] == nil).databaseValue,
        ])
    }
    for env in config.rows("environments") {
      _ = try persist(
        "environment",
        identity: [
          "app_id": apps[env["app"]?.string ?? ""].databaseValue, "name": text(env, "name"),
        ], values: ["url": text(env, "url")])
    }
    for service in config.rows("services") {
      let name = service.string ?? ""
      services[name] = try persist(
        "service",
        identity: [
          "workspace_id": workspace.databaseValue, "slug": name.databaseValue,
        ], values: ["name": name.databaseValue])
    }

  }

  mutating func applyEdgesTopicsAndSources() throws {
    for edge in config.rows("edges") {
      let target = edge["to"]?.string ?? ""
      let isService = target.hasPrefix("service:")
      _ = try persist(
        "edge",
        identity: [
          "workspace_id": workspace.databaseValue,
          "from_app_id": apps[edge["from"]?.string ?? ""].databaseValue,
          "to_app_id": (isService ? nil : apps[target]).databaseValue,
          "to_service_id": (isService ? services[String(target.dropFirst(8))] : nil)
            .databaseValue,
          "kind": text(edge, "kind"),
        ],
        values: [
          "summary": text(edge, "summary"),
          "code_refs": try WorkspaceConfig.json(edge["code"]?.array(of: String.self) ?? [])
            .databaseValue,
        ])
    }
    try applyTopics()
    for source in config.rows("sources") {
      _ = try persist(
        "source",
        identity: [
          "workspace_id": workspace.databaseValue, "kind": text(source, "kind"),
          "root": text(source, "root"),
        ],
        values: [
          "include": try WorkspaceConfig.json(source["include"]?.array(of: String.self) ?? [])
            .databaseValue,
          "exclude": try WorkspaceConfig.json(source["exclude"]?.array(of: String.self) ?? [])
            .databaseValue,
        ])
    }

  }

  private mutating func applyTopics() throws {
    var aliases: Set<String> = []
    for topic in config.rows("topics") {
      let id = try persist(
        "topic",
        identity: [
          "workspace_id": workspace.databaseValue, "slug": text(topic, "slug"),
        ], values: ["name": text(topic, "slug")])
      for raw in topic["aliases"]?.array(of: String.self) ?? [] {
        let alias = WorkspaceConfig.normalize(raw)
        aliases.insert(alias)
        try db.execute(
          sql: """
            INSERT INTO topic_alias(workspace_id,topic_id,alias)
            VALUES(?,?,?)
            ON CONFLICT(workspace_id,alias) DO UPDATE SET topic_id=excluded.topic_id
            """, arguments: [workspace, id, alias])
      }
    }
    let existing = try String.fetchAll(
      db,
      sql: """
        SELECT alias FROM topic_alias
        WHERE workspace_id=?
        """, arguments: [workspace])
    for alias in existing where !aliases.contains(alias) {
      try db.execute(
        sql: """
          DELETE FROM topic_alias
          WHERE workspace_id=? AND alias=?
          """, arguments: [workspace, alias])
    }
  }

  private func deleteMissing() throws {
    for table in ["edge", "environment", "source", "app", "service", "topic", "repo"] {
      let filter =
        table == "environment"
        ? "app_id IN (SELECT id FROM app WHERE workspace_id=?)" : "workspace_id=?"
      let existing = try Int64.fetchAll(
        db, sql: "SELECT id FROM \(table) WHERE \(filter) ORDER BY id", arguments: [workspace])
      for id in existing where !(kept[table] ?? []).contains(id) {
        if ["app", "edge", "service", "topic"].contains(table) {
          try config.prepareDocRemoval(of: table, id: id, workspace: workspace, in: db)
        }
        if ["app", "edge", "service", "topic"].contains(table),
          try Bool.fetchOne(
            db,
            sql: """
              SELECT EXISTS(SELECT 1 FROM link WHERE to_kind=? AND to_id=? AND from_kind<>'doc')
              """, arguments: [table, id]) == true
        {
          throw WorkspaceError.conflict
        }
        if table == "repo" {
          try db.execute(sql: "DELETE FROM repo_path WHERE repo_id=?", arguments: [id])
        }
        try db.execute(sql: "DELETE FROM \(table) WHERE id=?", arguments: [id])
      }
    }

  }

  private mutating func persist(
    _ table: String, identity: [String: DatabaseValue], values: [String: DatabaseValue]
  ) throws -> Int64 {
    let id = try save(table: table, identity: identity, values: values)
    kept[table, default: []].insert(id)
    return id
  }
  private func text(_ node: Node?, _ key: String) -> DatabaseValue {
    node?[key]?.string.databaseValue ?? .null
  }

  private func save(
    table: String, identity: [String: DatabaseValue],
    values: [String: DatabaseValue]
  ) throws -> Int64 {
    let keys = identity.keys.sorted()
    let filter = keys.map { "\($0) IS ?" }.joined(separator: " AND ")
    let identityArguments = StatementArguments(keys.compactMap { identity[$0] })
    if let id = try Int64.fetchOne(
      db, sql: "SELECT id FROM \(table) WHERE \(filter)", arguments: identityArguments)
    {
      let columns = values.keys.sorted()
      try db.execute(
        sql: """
          UPDATE \(table)
          SET \(columns.map { "\($0)=?" }.joined(separator: ","))
          WHERE id=?
          """, arguments: StatementArguments(columns.compactMap { values[$0] } + [id.databaseValue])
      )
      return id
    }
    if table == "app", let slug = identity["slug"].flatMap(String.fromDatabaseValue),
      ["doc", "edge", "service"].contains(slug)
    {
      throw WorkspaceError.invalid([
        "New apps cannot use reserved slug \(slug); choose a different slug."
      ])
    }
    if table == "service" || table == "edge" {
      let field = table == "service" ? "slug" : "kind"
      guard let value = identity[field].flatMap(String.fromDatabaseValue),
        WorkspaceConfig.isValidIdentifier(value)
      else {
        throw WorkspaceError.invalid(["New \(table) \(field) must be an identifier."])
      }
    }
    var inserted = identity.merging(values) { _, value in value }
    inserted["uid"] = try ids.next(at: date).databaseValue
    let columns = inserted.keys.sorted()
    try db.execute(
      sql: """
        INSERT INTO \(table)(\(columns.joined(separator: ",")))
        VALUES(\(columns.map { _ in "?" }.joined(separator: ",")))
        """, arguments: StatementArguments(columns.compactMap { inserted[$0] }))
    return db.lastInsertedRowID
  }

}
