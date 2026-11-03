import Darwin
package import Foundation
import GRDB

/// Discovers local clones without fetching and binds their machine-local paths.
package enum RepositoryScan {
  /// Scans roots and two child levels. New workspaces get configuration stubs;
  /// existing workspaces retain their configuration and only refresh registered paths.
  package static func scan(
    _ roots: [URL], store: DatabaseStore, git: any GitRunner,
    identity: (ids: any IDGenerator, date: Date), workspace: String? = nil
  ) async throws -> String {
    guard let first = roots.first else { throw RepoError.scan }
    let slug = workspace ?? first.standardizedFileURL.lastPathComponent.lowercased()
    let repos = try await discover(roots, git: git)
    guard Set(repos.map(\.slug)).count == repos.count else { throw RepoError.duplicateSlug }
    try store.write { tx in
      do {
        let db = tx.database
        let existing = try Int64.fetchOne(
          db,
          sql: "SELECT id FROM workspace WHERE slug=?", arguments: [slug])
        if workspace != nil && existing == nil { throw WorkspaceError.notFound }
        if existing == nil {
          let config = try configuration(slug: slug, name: first.lastPathComponent, repos: repos)
          try config.apply(in: tx, ids: identity.ids, at: identity.date)
        }
        for repo in repos {
          guard
            let id = try Int64.fetchOne(
              db,
              sql: """
                SELECT repo.id
                FROM repo
                JOIN workspace ON workspace.id=repo.workspace_id
                WHERE workspace.slug=? AND repo.slug=?
                """, arguments: [slug, repo.slug])
          else { throw RepoError.configuration(repo: repo.slug, workspace: slug) }
          try db.execute(
            sql: """
              INSERT INTO repo_path(repo_id,path)
              VALUES(?,?)
              ON CONFLICT(repo_id) DO UPDATE SET path=excluded.path
              """, arguments: [id, repo.path.path])
        }
        if let existing { try tx.recordChange(kind: "workspace", rowID: existing) }
      } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
        throw WorkspaceError.conflict
      }
    }
    return slug
  }

  private static func discover(_ roots: [URL], git: any GitRunner) async throws -> [DiscoveredRepo]
  {
    var candidates: Set<String> = []
    for root in roots { try walk(canonical(root), depth: 0, into: &candidates) }
    var found: [String: DiscoveredRepo] = [:]
    for candidate in candidates.sorted() {
      let directory = URL(filePath: candidate)
      let worktrees = try await output(
        ["worktree", "list", "--porcelain", "-z"], in: directory, git: git)
      guard let entry = worktrees.split(separator: "\0").first, entry.hasPrefix("worktree ") else {
        throw RepoError.scan
      }
      let main = try canonical(URL(filePath: String(entry.dropFirst(9))))
      if found[main.path] != nil { continue }
      let remote: GitResult
      do {
        remote = try await git.run(
          .init(arguments: ["remote", "get-url", "origin"], directory: main))
      } catch { throw RepoError.scan }
      let url: String?
      switch remote.termination {
      case .exit(0):
        guard let decoded = String(data: remote.stdout, encoding: .utf8) else {
          throw RepoError.scan
        }
        url = decoded.trimmingCharacters(in: .newlines)
      case .exit(2): url = nil
      default: throw RepoError.scan
      }
      let refs = try await output(
        ["for-each-ref", "--format=%(refname:short)", "refs/remotes"], in: main, git: git)
      found[main.path] = DiscoveredRepo(
        path: main, remote: url, refs: refs.split(separator: "\n").map(String.init))
    }
    return found.values.sorted { $0.path.path < $1.path.path }
  }

  private static func walk(_ directory: URL, depth: Int, into paths: inout Set<String>) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: directory.appending(path: ".git").path) {
      paths.insert(directory.path)
      return
    }
    guard depth < 2 else { return }
    do {
      let children = try fm.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [])
      for child in children
      where try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
        try walk(canonical(child), depth: depth + 1, into: &paths)
      }
    } catch { throw RepoError.scan }
  }

  private static func canonical(_ url: URL) throws -> URL {
    guard let path = realpath(url.path, nil) else { throw RepoError.scan }
    defer { free(path) }
    let resolved = URL(filePath: String(cString: path))
    let values = try resolved.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
    return values.volumeSupportsCaseSensitiveNames == false
      ? URL(filePath: resolved.path.lowercased()) : resolved
  }

  private static func output(_ arguments: [String], in directory: URL, git: any GitRunner)
    async throws -> String
  {
    do {
      let result = try await git.run(.init(arguments: arguments, directory: directory))
      guard result.termination == .exit(0), let text = String(data: result.stdout, encoding: .utf8)
      else { throw RepoError.scan }
      return text
    } catch { throw RepoError.scan }
  }

  private static func configuration(slug: String, name: String, repos: [DiscoveredRepo]) throws
    -> WorkspaceConfig
  {
    let document: [String: Any] = [
      "workspace": [
        "slug": slug, "name": name, "task_prefix": String(slug.prefix(2)).uppercased(),
      ],
      "repos": repos.map { repo -> [String: String] in
        var row = ["slug": repo.slug]
        row["remote"] = repo.remote
        return row
      },
      "apps": repos.flatMap(\.apps),
    ]
    return try WorkspaceConfig.parse(WorkspaceConfig.json(document))
  }
}

private struct DiscoveredRepo: Sendable {
  let path: URL

  let remote: String?

  let refs: [String]

  var slug: String {
    path.lastPathComponent.lowercased()
  }

  var apps: [[String: String]] {
    var apps: [[String: String]] = []
    for ref in refs.sorted() where refs.contains(ref + "-prod") {
      let branch = ref.split(separator: "/").dropFirst().joined(separator: "-")
      apps.append([
        "slug": slug + "-" + branch, "repo": slug, "ref": ref, "prod_ref": ref + "-prod",
      ])
    }
    if let ref = ["origin/main", "origin/master"].first(where: refs.contains),
      !apps.contains(where: { $0["ref"] == ref })
    {
      apps.append(["slug": slug, "repo": slug, "ref": ref])
    }
    return apps
  }
}
