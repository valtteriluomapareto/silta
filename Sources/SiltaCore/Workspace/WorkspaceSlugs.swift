import Foundation
import GRDB
import Yams

/// Owns the exact spellings of current, former and retired map references.
enum WorkspaceSlugs {
  enum Kind: String, CaseIterable {
    case app, topic
    var section: String { self == .app ? "apps" : "topics" }
  }

  struct Item {
    let id: Int64
    let slug: String
    let previous: [String]
  }

  struct Match {
    let old: Item
    let slug: String
    let previous: [String]
  }

  struct Plan {
    let retained: [Match]
    let retired: [String]
    let names: [String: String]

    var renames: [Match] { retained.filter { $0.old.slug != $0.slug } }
    func canonical(_ slug: String) -> String { names[slug] ?? slug }
  }

  struct Resolved {
    let id: Int64
    let slug: String
    var former = true

    func warning(for requested: String, kind: Kind) -> OutputWarning? {
      guard former, requested != slug else { return nil }
      return OutputWarning(
        code: "renamed",
        message:
          "\(kind.rawValue.capitalized) \(TaskError.shown(requested)) was renamed to \(TaskError.shown(slug))."
      )
    }
  }

  static let retiredKey = "_retired_map_slugs"

  static func read(_ kind: Kind, workspace: Int64, in db: Database) throws -> [Item] {
    try Row.fetchAll(
      db,
      sql: "SELECT id,slug,previous_slugs FROM \(kind.rawValue) WHERE workspace_id=? ORDER BY slug",
      arguments: [workspace]
    ).map { row in
      try Item(id: row["id"], slug: row["slug"], previous: previous(row["previous_slugs"]))
    }
  }

  static func resolve(_ kind: Kind, _ slug: String, workspace: Int64, in db: Database) throws
    -> Resolved?
  {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT id,CAST(slug AS BLOB) AS slug_bytes FROM \(kind.rawValue) AS item
        WHERE workspace_id=? AND (
          slug=CAST(? AS TEXT) OR EXISTS(
            SELECT 1 FROM json_each(
              CASE WHEN json_valid(item.previous_slugs) THEN
                CASE WHEN json_type(item.previous_slugs)='array'
                  THEN item.previous_slugs ELSE '[]' END
              ELSE '[]' END
            ) WHERE type='text' AND value=CAST(? AS TEXT)))
        ORDER BY slug LIMIT 2
        """, arguments: [workspace, Data(slug.utf8), Data(slug.utf8)])
    guard rows.count < 2 else { throw try lookupCollision(kind, slug, workspace, in: db) }
    guard let row = rows.first, let current = try row.strictText("slug_bytes") else { return nil }
    return Resolved(id: row["id"], slug: current)
  }

  static func topic(_ word: String, workspace: Int64, in db: Database) throws -> Resolved? {
    let name = try resolve(.topic, word, workspace: workspace, in: db)
    if let name, name.slug == word { return name }
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT topic.id,CAST(topic.slug AS BLOB) AS slug_bytes
        FROM topic_alias JOIN topic ON topic.id=topic_alias.topic_id
        WHERE topic_alias.workspace_id=? AND topic_alias.alias=CAST(? AS TEXT)
          AND topic.workspace_id=?
        """, arguments: [workspace, Data(WorkspaceConfig.normalize(word).utf8), workspace])
    let alias = try row.flatMap { row in
      try row.strictText("slug_bytes").map { Resolved(id: row["id"], slug: $0, former: false) }
    }
    if let name, let alias, name.id != alias.id {
      throw try lookupCollision(.topic, word, workspace, in: db)
    }
    return name ?? alias
  }

  static func previous(_ text: String?) throws -> [String] {
    guard let text else { return [] }
    let data = Data(text.utf8)
    guard let names = try? JSONDecoder().decode([String].self, from: data),  // Invalid history.
      names.allSatisfy(WorkspaceConfig.isValidIdentifier)
    else { throw WorkspaceError.invalid(["Invalid stored previous slugs."]) }
    return names
  }

  static func retired(_ settings: [String: Any]) throws -> [String: [String]] {
    guard let value = settings[retiredKey] else { return [:] }
    guard let names = value as? [String: [String]],
      Set(names.keys).isSubset(of: Set(Kind.allCases.map(\.rawValue))),
      names.values.allSatisfy({
        $0.allSatisfy(WorkspaceConfig.isValidIdentifier) && Set($0).count == $0.count
      })
    else { throw WorkspaceError.invalid(["Invalid retired map slugs."]) }
    return names
  }

  static func plan(
    _ kind: Kind, rows: [Node], stored: [Item], retired: [String]
  ) throws -> Plan {
    let owners = try ownership(kind, items: stored, retired: retired)
    let current = Dictionary(stored.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
    var used = Set<Int64>()
    var retained: [Match] = []
    var final: [Item] = []
    for (index, row) in rows.enumerated() {
      let slug = row["slug"]?.string ?? ""
      let listed = row["previous"]?.array(of: String.self) ?? []
      let source = try match(kind, slug: slug, previous: listed, current: current, owners: owners)
      if kind == .app, source?.slug != slug, WorkspaceConfig.reservedAppSlug(slug) {
        throw WorkspaceError.invalid([
          "New apps cannot use reserved slug \(slug); choose a different slug."
        ])
      }
      if let source {
        guard used.insert(source.id).inserted else { throw collision(kind, slug) }
        var history = source.previous.filter { $0 != slug }
        if source.slug != slug { history.append(source.slug) }
        retained.append(Match(old: source, slug: slug, previous: history))
        final.append(Item(id: source.id, slug: slug, previous: history))
      } else {
        final.append(Item(id: -Int64(index) - 1, slug: slug, previous: []))
      }
    }
    let after = Set(retired + stored.filter { !used.contains($0.id) }.flatMap(\.previous)).sorted()
    let resolved = try ownership(kind, items: final, retired: after)
    return Plan(retained: retained, retired: after, names: resolved.mapValues(\.slug))
  }

  private static func match(
    _ kind: Kind, slug: String, previous: [String], current: [String: Item],
    owners: [String: Item]
  ) throws -> Item? {
    var match = current[slug]
    for old in previous {
      guard let item = owners[old] else {
        throw WorkspaceError.invalid([
          "Unknown previous \(kind.rawValue) slug \(TaskError.shown(old))."
        ])
      }
      if let match, match.id != item.id { throw collision(kind, old) }
      match = item
    }
    if let owner = owners[slug], owner.id != match?.id { throw collision(kind, slug) }
    return match
  }

  static func ownership(_ kind: Kind, items: [Item], retired: [String]) throws -> [String: Item] {
    let unavailable = Set(retired)
    var owners: [String: Item] = [:]
    for item in items {
      for slug in [item.slug] + item.previous {
        guard !unavailable.contains(slug), owners.updateValue(item, forKey: slug) == nil else {
          throw collision(kind, slug)
        }
      }
    }
    return owners
  }

  static func checkTopicAliases(
    _ aliases: [(slug: String, alias: String)], history: [(owner: String?, name: String)]
  ) throws {
    let byName = Dictionary(grouping: history) { WorkspaceConfig.normalize($0.name) }
    for (slug, alias) in aliases
    where byName[WorkspaceConfig.normalize(alias)]?.contains(where: { $0.owner != slug }) == true {
      throw collision(.topic, alias)
    }
  }

  private static func lookupCollision(_ kind: Kind, _ slug: String, _ id: Int64, in db: Database)
    throws -> CommandFailure
  {
    let workspace = try String.fetchOne(
      db, sql: "SELECT slug FROM workspace WHERE id=?", arguments: [id])
    return CommandFailure(error: collision(kind, slug), next: [workspaceEditRead(workspace)])
  }

  private static func collision(_ kind: Kind, _ slug: String) -> WorkspaceError {
    .invalid([
      "\(kind.rawValue.capitalized) slug \(TaskError.shown(slug)) has conflicting or reserved ownership."
    ])
  }
}
