import Foundation
import GRDB
import Yams

/// The map changes and live references that an edit would affect.
package struct WorkspaceMapChanges: Encodable, Sendable {
  package struct Rename: Encodable, Sendable {
    package let kind: String
    package let from: String
    package let to: String
    package let docs: Int
    package let tasks: Int
    package let edges: Int
    package let environments: Int
  }

  package struct Blocker: Encodable, Sendable {
    package let item: String
    package let references: [String]
  }

  package struct AliasChange: Encodable, Sendable {
    package let topic: String
    package let added: [String]
    package let removed: [String]
  }

  package let added: [String]
  package let removed: [String]
  package let renamed: [Rename]
  package let blockers: [Blocker]
  package let retired: [String]?
  package let released: [String]?
  package let aliasesChanged: [AliasChange]?

  enum CodingKeys: String, CodingKey {
    case added, removed, renamed, blockers, retired, released
    case aliasesChanged = "aliases_changed"
  }

  package var isEmpty: Bool {
    added.isEmpty && removed.isEmpty && renamed.isEmpty && retired == nil && released == nil
      && aliasesChanged == nil
  }
}

struct WorkspaceMapEdit {
  let apps: WorkspaceSlugs.Plan
  let topics: WorkspaceSlugs.Plan
  let removals: [WorkspaceMapRow]
  let changes: WorkspaceMapChanges

  var retired: [String: [String]] {
    ["app": apps.retired, "topic": topics.retired].filter { !$0.value.isEmpty }
  }

  /// Computes exactly the identities the writer will retain, without writing or allocating ids.
  static func read(_ config: WorkspaceConfig, in db: Database) throws -> Self {
    let workspace = try Row.fetchOne(
      db, sql: "SELECT id,settings FROM workspace WHERE slug=?", arguments: [config.slug])
    let id: Int64 = workspace?["id"] ?? 0
    let raw: String = workspace?["settings"] ?? "{}"
    let settings = try settingsObject(raw)
    let retired = try WorkspaceSlugs.retired(settings)
    let apps = try plan(.app, config: config, retired: retired, workspace: id, in: db)
    let topics = try plan(.topic, config: config, retired: retired, workspace: id, in: db)
    try checkAliases(config.rows("topics"), plan: topics)
    let existing = try WorkspaceMapRow.read(workspace: id, in: db)
    let desired = try desiredRows(config, apps: apps)
    let oldKeys = Set(existing.map { $0.canonical(apps: apps, topics: topics).key })
    let newKeys = Set(desired.map(\.key))
    let removals = existing.filter {
      !newKeys.contains($0.canonical(apps: apps, topics: topics).key)
    }
    let additions = desired.filter { !oldKeys.contains($0.key) }
    try checkAdditions(additions)
    let removedIDs = Dictionary(grouping: removals, by: \.table).mapValues { Set($0.map(\.id)) }
    let newlyRetired = typedSlugs(
      apps.retired.filter { !(retired["app"] ?? []).contains($0) },
      topics.retired.filter { !(retired["topic"] ?? []).contains($0) })
    let released = typedSlugs(config.released(.app), config.released(.topic))
    let aliases = try aliasChanges(config.rows("topics"), plan: topics, workspace: id, in: db)
    let changes = WorkspaceMapChanges(
      added: additions.map(\.ref).sorted(), removed: removals.map(\.ref).sorted(),
      renamed: try [.app, .topic].flatMap { kind in
        try (kind == .app ? apps : topics).renames.map {
          try WorkspaceMapReferences.rename(kind, $0, removals: removedIDs, workspace: id, in: db)
        }
      },
      blockers: try WorkspaceMapReferences.blockers(removals, workspace: id, in: db),
      retired: newlyRetired.isEmpty ? nil : newlyRetired,
      released: released.isEmpty ? nil : released,
      aliasesChanged: aliases.isEmpty ? nil : aliases)
    return Self(apps: apps, topics: topics, removals: removals, changes: changes)
  }

  private static func plan(
    _ kind: WorkspaceSlugs.Kind, config: WorkspaceConfig, retired: [String: [String]],
    workspace: Int64, in db: Database
  ) throws -> WorkspaceSlugs.Plan {
    let names = Set(retired[kind.rawValue] ?? [])
    let released = Set(config.released(kind))
    if let unknown = released.subtracting(names).sorted().first {
      throw WorkspaceError.invalid([
        "\(kind.rawValue.capitalized) slug \(TaskError.shown(unknown)) is not already retired."
      ])
    }
    return try WorkspaceSlugs.plan(
      kind, rows: config.rows(kind.section),
      stored: WorkspaceSlugs.read(kind, workspace: workspace, in: db),
      retired: names.subtracting(released).sorted())
  }

  private static func typedSlugs(_ apps: [String], _ topics: [String]) -> [String] {
    apps.sorted().map { "app:" + TaskError.shown($0) }
      + topics.sorted().map { "topic:" + TaskError.shown($0) }
  }

  private static func checkAdditions(_ additions: [WorkspaceMapRow]) throws {
    for row in additions where row.table == "service" || row.table == "edge" {
      guard let name = row.parts.last, WorkspaceConfig.isValidIdentifier(name) else {
        throw WorkspaceError.invalid([
          "New \(row.table) \(row.table == "service" ? "slug" : "kind") must be an identifier."
        ])
      }
    }
  }

  private static func settingsObject(_ raw: String) throws -> [String: Any] {
    if let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),  // Repairable.
      let map = parsed as? [String: Any]
    {
      return map
    }
    if raw.contains(WorkspaceSlugs.retiredKey) {
      throw WorkspaceError.invalid(["Invalid stored map slug history."])
    }
    return [:]
  }

  private static func checkAliases(_ rows: [Node], plan: WorkspaceSlugs.Plan) throws {
    let aliases = rows.flatMap { row in
      (row["aliases"]?.array(of: String.self) ?? []).map { (row["slug"]?.string ?? "", $0) }
    }
    let prior = plan.names.compactMap { key, slug -> (String?, String)? in
      key == slug ? nil : (slug, key)
    }
    try WorkspaceSlugs.checkTopicAliases(
      aliases, history: prior + plan.retired.map { (nil, $0) })
  }

  private static func aliasChanges(
    _ rows: [Node], plan: WorkspaceSlugs.Plan, workspace: Int64, in db: Database
  ) throws -> [WorkspaceMapChanges.AliasChange] {
    let currentSlugs = Dictionary(uniqueKeysWithValues: plan.retained.map { ($0.old.id, $0.slug) })
    let stored = try Row.fetchAll(
      db,
      sql: """
        SELECT topic.id, topic.slug, topic_alias.alias FROM topic_alias
        JOIN topic ON topic.id=topic_alias.topic_id
        WHERE topic_alias.workspace_id=? AND topic.workspace_id=?
        """, arguments: [workspace, workspace])
    let before = stored.reduce(into: [String: Set<String>]()) { result, row in
      let slug = currentSlugs[row["id"]] ?? (row["slug"] as String)
      result[slug, default: []].insert(WorkspaceConfig.normalize(row["alias"]))
    }
    let after = Dictionary(
      uniqueKeysWithValues: rows.map { row in
        let normalized = (row["aliases"]?.array(of: String.self) ?? []).map(
          WorkspaceConfig.normalize)
        return (row["slug"]?.string ?? "", Set(normalized))
      })
    return Set(before.keys).union(after.keys).sorted().compactMap { slug in
      let old = before[slug] ?? []
      let new = after[slug] ?? []
      guard old != new else { return nil }
      return WorkspaceMapChanges.AliasChange(
        topic: "topic:" + TaskError.shown(slug),
        added: new.subtracting(old).sorted().map(TaskError.shown),
        removed: old.subtracting(new).sorted().map(TaskError.shown))
    }
  }

  private static func desiredRows(_ config: WorkspaceConfig, apps: WorkspaceSlugs.Plan) throws
    -> [WorkspaceMapRow]
  {
    var result: [WorkspaceMapRow] = []
    for (table, section) in WorkspaceMapRow.sections {
      var seen: Set<WorkspaceMapRow.Key> = []
      for row in config.rows(section) {
        let parts: [String] =
          switch table {
          case "environment": [apps.canonical(row["app"]?.string ?? ""), row["name"]?.string ?? ""]
          case "edge":
            [
              apps.canonical(row["from"]?.string ?? ""), apps.canonical(row["to"]?.string ?? ""),
              row["kind"]?.string ?? "",
            ]
          case "source": [row["kind"]?.string ?? "", row["root"]?.string ?? ""]
          case "service": [row.string ?? ""]
          default: [row["slug"]?.string ?? ""]
          }
        let item = WorkspaceMapRow(table: table, id: 0, parts: parts)
        guard seen.insert(item.key).inserted else {
          throw WorkspaceError.invalid([
            "duplicate \(section) identity \(TaskError.shown(item.ref))"
          ])
        }
        result.append(item)
      }
    }
    return result
  }
}

struct WorkspaceMapRow {
  struct Key: Hashable {
    let table: String
    let parts: [Data]
  }

  static let sections = [
    ("edge", "edges"), ("environment", "environments"), ("source", "sources"),
    ("app", "apps"), ("service", "services"), ("topic", "topics"), ("repo", "repos"),
  ]

  let table: String
  let id: Int64
  let parts: [String]

  var key: Key { Key(table: table, parts: parts.map { Data($0.utf8) }) }

  var ref: String {
    if table == "edge", parts.count == 3 {
      let target =
        parts[1].hasPrefix("service:")
        ? "service:" + TaskLinkTarget.encodeComponent(String(parts[1].dropFirst(8))) : parts[1]
      return "edge:" + parts[0] + "/" + target + "/" + TaskLinkTarget.encodeComponent(parts[2])
    }
    if table == "service", let slug = parts.first {
      return "service:" + TaskLinkTarget.encodeComponent(slug)
    }
    return table + ":" + parts.joined(separator: "/")
  }

  func canonical(apps: WorkspaceSlugs.Plan, topics: WorkspaceSlugs.Plan) -> Self {
    var result = parts
    switch table {
    case "edge" where result.count == 3:
      result[0] = apps.canonical(result[0])
      result[1] = apps.canonical(result[1])
    case "app", "environment":
      if let slug = parts.first { result[0] = apps.canonical(slug) }
    case "topic":
      if let slug = parts.first { result[0] = topics.canonical(slug) }
    default: break
    }
    return Self(table: table, id: id, parts: result)
  }

  static func read(workspace: Int64, in db: Database) throws -> [Self] {
    try sections.flatMap { table, _ in
      try Row.fetchAll(db, sql: query(table), arguments: [workspace]).map { row in
        let parts = try row.columnNames.dropFirst().compactMap { try row.strictText($0) }
        return Self(table: table, id: row["id"], parts: parts)
      }
    }
  }

  private static func query(_ table: String) -> String {
    switch table {
    case "edge":
      """
      SELECT e.id,CAST(a.slug AS BLOB) AS source,
        CAST(COALESCE(b.slug,'service:'||s.slug) AS BLOB) AS target,CAST(e.kind AS BLOB) AS kind
      FROM edge e JOIN app a ON a.id=e.from_app_id LEFT JOIN app b ON b.id=e.to_app_id
        LEFT JOIN service s ON s.id=e.to_service_id WHERE e.workspace_id=? ORDER BY e.id
      """
    case "environment":
      """
      SELECT e.id,CAST(a.slug AS BLOB) AS slug,CAST(e.name AS BLOB) AS name FROM environment e
      JOIN app a ON a.id=e.app_id WHERE a.workspace_id=? ORDER BY e.id
      """
    case "source":
      """
      SELECT id,CAST(kind AS BLOB) AS kind,CAST(root AS BLOB) AS root
      FROM source WHERE workspace_id=? ORDER BY id
      """
    default:
      "SELECT id,CAST(slug AS BLOB) AS slug FROM \(table) WHERE workspace_id=? ORDER BY id"
    }
  }
}
