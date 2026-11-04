import Darwin
package import Foundation
import GRDB

/// What a scan bound: the workspace it created or refreshed, and its naming warnings.
package struct ScanOutcome: Sendable {
  package let workspace: String
  package let warnings: [OutputWarning]
}

/// Discovers local clones without fetching and binds their machine-local paths.
package enum RepositoryScan {
  /// Scans roots and two child levels. New workspaces get configuration stubs;
  /// existing workspaces retain their configuration and only refresh registered paths.
  package static func scan(
    _ roots: [URL], store: DatabaseStore, git: any GitRunner,
    identity: (ids: any IDGenerator, date: Date), workspace: String? = nil
  ) async throws -> ScanOutcome {
    guard let first = roots.first else { throw RepoError.scan }
    let slug = workspace ?? first.standardizedFileURL.lastPathComponent.lowercased()
    let discovered = try await discover(roots, git: git)
    var warnings: [OutputWarning] = []
    try store.write { tx in
      do {
        let db = tx.database
        let existing = try Int64.fetchOne(
          db,
          sql: "SELECT id FROM workspace WHERE slug=?", arguments: [slug])
        if workspace != nil && existing == nil { throw WorkspaceError.notFound }
        let repos = try Self.naming(
          discovered, workspace: existing == nil ? nil : slug, in: db, into: &warnings)
        guard Set(repos.map(\.slug)).count == repos.count else { throw RepoError.duplicateSlug }
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
    return ScanOutcome(workspace: slug, warnings: warnings)
  }

  /// Repo slugs come from directory names, so a repo named `none` would collide with the
  /// word that means non-code work. A new workspace names it `none-repo` with a warning;
  /// an existing one keeps the slug it already stores, so a rescan finds its rows.
  private static func naming(
    _ repos: [DiscoveredRepo], workspace: String?, in db: Database,
    into warnings: inout [OutputWarning]
  ) throws -> [DiscoveredRepo] {
    var stored: Set<String> = []
    if let workspace {
      stored = Set(
        try String.fetchAll(
          db,
          sql: """
            SELECT repo.slug
            FROM repo
            JOIN workspace ON workspace.id=repo.workspace_id
            WHERE workspace.slug=?
            """, arguments: [workspace]))
    }
    var taken = Set(repos.map(\.slug))
    taken.remove(TaskDraft.noneApp)
    return repos.map { repo in
      guard repo.slug == TaskDraft.noneApp else { return repo }
      let slug: String
      if stored.contains(TaskDraft.noneApp) {
        slug = TaskDraft.noneApp
      } else if let kept = Self.storedReservedSlug(in: stored) {
        slug = kept
      } else {
        slug = Self.freeReservedSlug(excluding: taken)
        warnings.append(
          OutputWarning(
            code: "slug_renamed",
            message: "Repo \(repo.slug) was renamed \(slug) because "
              + "\(TaskDraft.noneApp) is reserved for non-code work."))
      }
      taken.insert(slug)
      return repo.renamed(slug)
    }
  }

  /// The `none-repo` name an existing workspace already stores, if any.
  private static func storedReservedSlug(in stored: Set<String>) -> String? {
    var slug = TaskDraft.noneApp + "-repo"
    var suffix = 2
    while suffix <= stored.count + 1 {
      if stored.contains(slug) { return slug }
      slug = TaskDraft.noneApp + "-repo-\(suffix)"
      suffix += 1
    }
    return nil
  }

  /// The first `none-repo` name this scan has not given to another repo.
  private static func freeReservedSlug(excluding taken: Set<String>) -> String {
    var slug = TaskDraft.noneApp + "-repo"
    var suffix = 2
    while taken.contains(slug) {
      slug = TaskDraft.noneApp + "-repo-\(suffix)"
      suffix += 1
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
        path: main, slug: main.lastPathComponent.lowercased(), remote: url,
        refs: refs.split(separator: "\n").map(String.init))
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

  let slug: String

  let remote: String?

  let refs: [String]

  /// The same repo under another config slug.
  func renamed(_ slug: String) -> DiscoveredRepo {
    DiscoveredRepo(path: path, slug: slug, remote: remote, refs: refs)
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
