package import Foundation
import GRDB

/// Fetches registered clones sequentially without prompting for credentials.
package enum RepositoryFetch {
  /// Preflights every selected path before network activity, then stops at the first failure.
  /// Each successful fetch records its timestamp; failed and unattempted clones are untouched.
  package static func fetch(
    _ repo: String?, workspace: String?, store: DatabaseStore, git: any GitRunner, at date: Date
  ) async throws -> [String] {
    let selected = try WorkspaceSelection.resolve(workspace, in: store)
    let paths = try store.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT repo.id,repo.slug,repo_path.path
          FROM repo
          JOIN workspace ON workspace.id=repo.workspace_id
          LEFT JOIN repo_path ON repo_path.repo_id=repo.id
          WHERE workspace.slug=? AND (? IS NULL OR repo.slug=?)
          ORDER BY repo.slug
          """, arguments: [selected, repo, repo]
      ).map { row -> LocalRepo in
        let id: Int64 = row["id"]
        let slug: String = row["slug"]
        guard let path: String = row["path"] else { throw RepoError.localPath }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory),
          directory.boolValue
        else { throw RepoError.localPath }
        return LocalRepo(id: id, slug: slug, path: URL(filePath: path, directoryHint: .isDirectory))
      }
    }
    guard !paths.isEmpty else { throw RepoError.notFound }
    for path in paths {
      do {
        let result = try await git.run(
          .init(arguments: ["fetch"], directory: path.path, timeout: 60))
        guard result.termination == .exit(0) else {
          throw RepoError.fetch(repo: path.slug, workspace: selected)
        }
      } catch { throw RepoError.fetch(repo: path.slug, workspace: selected) }
      try store.write { tx in
        try tx.database.execute(
          sql: """
            UPDATE repo_path
            SET fetched_at=?
            WHERE repo_id=? AND path=?
            """,
          arguments: [
            date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)), path.id,
            path.path.path,
          ])
        try tx.recordChange(kind: "repo", rowID: path.id)
      }
    }
    return paths.map(\.slug)
  }
}

private struct LocalRepo: Sendable {
  let id: Int64

  let slug: String

  let path: URL
}
