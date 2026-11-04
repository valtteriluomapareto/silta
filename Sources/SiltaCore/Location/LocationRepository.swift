import Foundation
import GRDB

struct LocationRepository: Equatable {
  let id: Int64
  let workspace: String
  let slug: String
  let path: String
  let apps: [LocationCandidate]

  static func all(workspace: String?, in store: DatabaseStore) throws -> [Self] {
    guard FileManager.default.fileExists(atPath: store.path) else { return [] }
    return try store.read { try read(workspace: workspace, in: $0) }
  }

  static func read(workspace: String?, in db: Database) throws -> [Self] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT repo.id,workspace.slug AS workspace,repo.slug,repo_path.path
        FROM repo JOIN workspace ON workspace.id=repo.workspace_id
        JOIN repo_path ON repo_path.repo_id=repo.id
        WHERE (? IS NULL OR workspace.slug=?) ORDER BY repo.id
        """, arguments: [workspace, workspace]
    ).map { row in
      let id: Int64 = row["id"]
      let apps = try Row.fetchAll(
        db,
        sql: """
          SELECT id,slug,ref,prod_ref,subpath FROM app WHERE repo_id=? ORDER BY slug
          """, arguments: [id]
      ).map {
        LocationCandidate(
          id: $0["id"], app: $0["slug"], ref: $0["ref"],
          prodRef: $0["prod_ref"], subpath: $0["subpath"])
      }
      return Self(
        id: id, workspace: row["workspace"], slug: row["slug"],
        path: row["path"], apps: apps)
    }
  }

  func candidates(at path: URL, root: URL) throws -> [LocationCandidate] {
    let subpaths = try apps.filter { app in
      guard let subpath = app.subpath else { return false }
      let directory = root.appending(path: subpath)
      guard FileManager.default.fileExists(atPath: directory.path) else { return false }
      return try LocationPath.contains(LocationPath.canonical(directory), path)
    }
    return subpaths.isEmpty ? apps.filter { $0.subpath == nil } : subpaths
  }
}
