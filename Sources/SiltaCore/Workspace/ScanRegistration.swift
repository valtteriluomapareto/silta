import Foundation
import GRDB

/// A configured repo and its optional machine-local path.
struct ScanRegistration {
  let id: Int64
  let repo: String
  let workspace: String
  let path: String?
  let isIdentity: Bool

  /// An exact canonical binding wins over origin evidence. Keep competing origin rows
  /// visible so a pathless declaration won't be chosen in an ambiguous workspace.
  static func matching(path: String, origin: String?, in db: Database) throws -> [Self] {
    let stableOrigin = origin.map(identifiableOrigin) ?? false
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT repo.id, repo.slug AS repo, workspace.slug AS workspace, repo_path.path
        FROM repo JOIN workspace ON workspace.id=repo.workspace_id
        LEFT JOIN repo_path ON repo_path.repo_id=repo.id
        WHERE repo_path.path=? OR (repo.remote_url=? AND repo.remote_url<>'')
        ORDER BY workspace.slug, repo.slug
        """, arguments: [path, origin]
    ).map {
      let binding: String? = $0["path"]
      return Self(
        id: $0["id"], repo: $0["repo"], workspace: $0["workspace"], path: binding,
        isIdentity: binding == path || stableOrigin)
    }
    let bound = rows.filter { $0.path == path }
    return bound.isEmpty ? rows : bound
  }

  /// Git treats paths without a scheme or an scp-style host as local paths.
  private static func identifiableOrigin(_ origin: String) -> Bool {
    if origin.hasPrefix("/") { return true }
    guard let colon = origin.firstIndex(of: ":") else { return false }
    return colon != origin.startIndex && !origin[..<colon].contains("/")
  }

  static func identities(_ matches: [[Self]]) -> [Self]? {
    let rows = matches.compactMap { $0.count == 1 && $0.first?.isIdentity == true ? $0.first : nil }
    guard rows.count == matches.count, Set(rows.map(\.id)).count == rows.count else { return nil }
    return rows
  }

  static func recovery(_ matches: [[Self]], paths: [String], roots: [String]) -> ScanError? {
    let choices = Set(matches.flatMap { $0.map(\.workspace) }).sorted()
    guard !choices.isEmpty else { return nil }
    let usable =
      choices.count == 1
      && identities(matches).map { rows in
        zip(rows, paths).allSatisfy { row, path in row.path == nil || row.path == path }
      } == true
    return .registeredWorkspaces(choices, roots: usable ? roots : nil)
  }
}
