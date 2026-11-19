import Foundation
import GRDB

/// A configured repo and its optional machine-local path.
struct ScanRegistration {
  let id: Int64
  let repo: String
  let workspace: String
  let path: String?

  /// An exact canonical binding wins over origin evidence. Keep competing origin rows
  /// visible so a pathless declaration won't be chosen in an ambiguous workspace.
  static func matching(path: String, origin: String?, in db: Database) throws -> [Self] {
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
      Self(id: $0["id"], repo: $0["repo"], workspace: $0["workspace"], path: $0["path"])
    }
    let bound = rows.filter { $0.path == path }
    return bound.isEmpty ? rows : bound
  }

  static func recovery(_ matches: [[Self]], paths: [String], roots: [String]) -> ScanError? {
    let choices = Set(matches.flatMap { $0.map(\.workspace) }).sorted()
    guard !choices.isEmpty else { return nil }
    let single = matches.compactMap { $0.count == 1 ? $0.first : nil }
    let unique =
      choices.count == 1 && single.count == paths.count
      && Set(single.map(\.id)).count == single.count
    let usable =
      unique
      && zip(single, paths).allSatisfy { row, path in
        row.path == nil || row.path == path
      }
    return .registeredWorkspaces(choices, roots: usable ? roots : nil)
  }
}
