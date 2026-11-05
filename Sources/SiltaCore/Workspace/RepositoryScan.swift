import Darwin
package import Foundation
import GRDB

/// What a scan bound: the workspace it created or refreshed, and its naming warnings.
package struct ScanOutcome: Sendable {
  package let workspace: String
  package let warnings: [OutputWarning]
}

/// How a scan treats an existing workspace.
package enum ScanTarget: Sendable {
  /// `--ws`: refresh only the paths of a workspace that must exist.
  case rescan(String)

  /// No naming options: derive the name from the first directory, then create the
  /// workspace or refresh it when the derived slug already exists.
  case derived

  /// `--slug` and `--prefix`: create that workspace, refusing any name already taken.
  case named(slug: String?, prefix: String?)
}

/// Discovers local clones without fetching and binds their machine-local paths.
package enum RepositoryScan {
  /// Scans roots and two child levels. New workspaces get configuration stubs;
  /// existing workspaces retain their configuration and only refresh registered paths.
  package static func scan(
    _ roots: [URL], target: ScanTarget, store: DatabaseStore, git: any GitRunner,
    identity: (ids: any IDGenerator, date: Date)
  ) async throws -> ScanOutcome {
    guard let first = roots.first else { throw RepoError.scan }
    let paths = roots.map(\.path)
    let directory = first.standardizedFileURL.lastPathComponent
    let naming = try naming(target, directory: directory, roots: paths)
    let discovered = try await discover(roots, git: git)
    var warnings: [OutputWarning] = []
    let request = ScanRequest(
      target: target, choice: ScanChoice(target), slug: naming.slug,
      chosenPrefix: naming.prefix, directory: directory, roots: paths, repos: discovered,
      identity: identity)
    let workspace = try store.write { tx in
      try apply(tx, request: request, warnings: &warnings)
    }
    return ScanOutcome(workspace: workspace, warnings: warnings)
  }

  /// Creates or refreshes the workspace and binds every discovered clone in one write.
  private static func apply(
    _ tx: StorageTransaction, request: ScanRequest, warnings: inout [OutputWarning]
  ) throws -> String {
    do {
      let db = tx.database
      let existing = try existingWorkspace(request.slug, in: db)
      if case .named(let chosenSlug, _) = request.target, let existing {
        throw ScanError.slugExists(
          request.slug, chosen: chosenSlug != nil, workspace: existing["slug"] as String,
          roots: request.roots, choice: request.choice)
      }
      if case .rescan = request.target, existing == nil { throw WorkspaceError.notFound }
      let workspace = existing.map { $0["slug"] as String } ?? request.slug
      guard Set(request.repos.map(\.slug)).count == request.repos.count else {
        throw RepoError.duplicateSlug
      }
      let repos = try naming(
        request.repos, workspace: existing == nil ? nil : workspace, in: db, into: &warnings)
      // Remapping can give two clones in one scan the same name; never let a rewrite
      // bind both to one row or write a configuration with duplicate repo slugs.
      guard Set(repos.map(\.slug)).count == repos.count else { throw RepoError.duplicateSlug }
      if existing == nil {
        let prefix = try creationPrefix(request, in: db)
        let config = try configuration(
          slug: workspace, name: name(request.target, directory: request.directory), prefix: prefix,
          repos: repos)
        try config.apply(in: tx, ids: request.identity.ids, at: request.identity.date)
      }
      try registerPaths(repos, workspace: workspace, in: db)
      if let existing { try tx.recordChange(kind: "workspace", rowID: existing["id"] as Int64) }
      return workspace
    } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
      throw WorkspaceError.conflict
    }
  }

  /// The workspace the scan target names, matched without regard to case.
  private static func existingWorkspace(_ slug: String, in db: Database) throws -> Row? {
    try Row.fetchOne(
      db, sql: "SELECT id,slug FROM workspace WHERE lower(slug)=lower(?)", arguments: [slug])
  }

  /// Binds each clone to its repo row, after refusing a path another workspace holds.
  private static func registerPaths(
    _ repos: [DiscoveredRepo], workspace: String, in db: Database
  ) throws {
    for repo in repos {
      if let holder = try pathHolder(repo.path.path, excluding: workspace, in: db) {
        throw ScanError.repoPathTaken(
          repo: holder.repo, path: repo.path.path, workspace: holder.workspace)
      }
      guard
        let id = try Int64.fetchOne(
          db,
          sql: """
            SELECT repo.id
            FROM repo
            JOIN workspace ON workspace.id=repo.workspace_id
            WHERE workspace.slug=? AND repo.slug=?
            """, arguments: [workspace, repo.slug])
      else { throw RepoError.configuration(repo: repo.slug, workspace: workspace) }
      try db.execute(
        sql: """
          INSERT INTO repo_path(repo_id,path)
          VALUES(?,?)
          ON CONFLICT(repo_id) DO UPDATE SET path=excluded.path
          """, arguments: [id, repo.path.path])
    }
  }
}

extension RepositoryScan {
  /// The names a scan uses, validated before any discovery runs: an existing workspace
  /// keeps its slug, and a new one gets the chosen or directory-derived slug.
  private static func naming(
    _ target: ScanTarget, directory: String, roots: [String]
  ) throws -> (slug: String, prefix: String?) {
    let choice = ScanChoice(target)
    switch target {
    case .rescan(let slug):
      return (slug, nil)
    case .derived:
      return (
        try identifier(
          directory.lowercased(), derived: true, directory: directory, roots: roots,
          choice: choice),
        nil
      )
    case .named(let slug, let prefix):
      let value = try identifier(
        slug ?? directory.lowercased(), derived: slug == nil, directory: directory, roots: roots,
        choice: choice)
      guard let prefix else { return (value, nil) }
      guard WorkspaceConfig.isValidIdentifier(prefix) else {
        throw ScanError.invalidPrefix(prefix, origin: nil, roots: roots, choice: choice)
      }
      return (value, prefix)
    }
  }

  /// Refuses a slug that is no identifier, naming the flag that fixes it.
  private static func identifier(
    _ slug: String, derived: Bool, directory: String, roots: [String], choice: ScanChoice
  ) throws -> String {
    guard WorkspaceConfig.isValidIdentifier(slug) else {
      throw ScanError.invalidSlug(
        slug, derived: derived, directory: directory, roots: roots, choice: choice)
    }
    return slug
  }

  /// A workspace created from `--slug` takes that name; otherwise the directory's.
  private static func name(_ target: ScanTarget, directory: String) -> String {
    if case .named(let slug?, _) = target { return slug }
    return directory
  }

  /// The prefix of a new workspace. Refreshing an existing one never derives one, so
  /// directories whose first letters are no prefix keep working without options.
  private static func creationPrefix(_ request: ScanRequest, in db: Database) throws -> String {
    let derived = request.chosenPrefix == nil
    let prefix = request.chosenPrefix ?? String(request.slug.prefix(2)).uppercased()
    let origin: PrefixOrigin? =
      derived
      ? (request.choice.slug == nil ? .directory(request.directory) : .slug(request.slug)) : nil
    guard WorkspaceConfig.isValidIdentifier(prefix) else {
      throw ScanError.invalidPrefix(
        prefix, origin: origin, roots: request.roots, choice: request.choice)
    }
    if let holder = try String.fetchOne(
      db, sql: "SELECT slug FROM workspace WHERE lower(task_prefix)=lower(?)",
      arguments: [prefix])
    {
      throw ScanError.prefixTaken(
        prefix, derived: derived, workspace: holder, roots: request.roots, choice: request.choice)
    }
    return prefix
  }

  /// A repo slug is the clone directory's name normalized: `My Projects` is
  /// `my-projects`, and a name with no usable character is `repo`.
  private static func suggestedSlug(_ name: String) -> String {
    let body = name.lowercased().replacing(/[^a-z0-9_-]+/, with: "-")
    let trimmed = body.replacing(/^[^a-z0-9]+/, with: "").replacing(/[^a-z0-9]+$/, with: "")
    return trimmed.isEmpty ? "repo" : trimmed
  }

  /// The repo and workspace already binding `path`, if another workspace holds it.
  private static func pathHolder(
    _ path: String, excluding workspace: String, in db: Database
  ) throws -> (repo: String, workspace: String)? {
    try Row.fetchOne(
      db,
      sql: """
        SELECT repo.slug AS repo,workspace.slug AS workspace
        FROM repo_path
        JOIN repo ON repo.id=repo_path.repo_id
        JOIN workspace ON workspace.id=repo.workspace_id
        WHERE repo_path.path=? AND lower(workspace.slug)<>lower(?)
        LIMIT 1
        """, arguments: [path, workspace]
    ).map { (repo: $0["repo"] as String, workspace: $0["workspace"] as String) }
  }

  /// Repo slugs come from directory names, so a repo named `none` would collide with the
  /// word that means non-code work. Such a repo is always stored as `none-repo`; a
  /// workspace that binds that name to a clone that still exists keeps it, so the scan
  /// refuses instead of taking the name from the other clone. A binding whose clone is
  /// gone is a moved clone, and the rescan repoints it.
  private static func naming(
    _ repos: [DiscoveredRepo], workspace: String?, in db: Database,
    into warnings: inout [OutputWarning]
  ) throws -> [DiscoveredRepo] {
    guard let index = repos.firstIndex(where: { $0.slug == TaskDraft.noneApp }) else {
      return repos
    }
    let slug = TaskDraft.noneApp + "-repo"
    let path = repos[index].path.path
    var named = repos
    named[index] = repos[index].renamed(slug)
    if let workspace, let bound = try registeredPath(of: slug, workspace: workspace, in: db) {
      if bound == path { return named }
      if isClone(at: bound) {
        throw ScanError.reservedRepoBound(path: path, bound: bound, workspace: workspace)
      }
    }
    warnings.append(
      OutputWarning(
        code: "slug_renamed",
        message: "Repo \(TaskDraft.noneApp) was renamed \(slug) because "
          + "\(TaskDraft.noneApp) is reserved for non-code work."))
    return named
  }

  /// The path a workspace binds to `slug`, if any.
  private static func registeredPath(
    of slug: String, workspace: String, in db: Database
  ) throws -> String? {
    try String.fetchOne(
      db,
      sql: """
        SELECT repo_path.path
        FROM repo_path
        JOIN repo ON repo.id=repo_path.repo_id
        JOIN workspace ON workspace.id=repo.workspace_id
        WHERE workspace.slug=? AND repo.slug=?
        """, arguments: [workspace, slug])
  }

  private static func isClone(at path: String) -> Bool {
    FileManager.default.fileExists(atPath: URL(filePath: path).appending(path: ".git").path)
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
        path: main, slug: suggestedSlug(main.lastPathComponent), remote: url,
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

  private static func configuration(
    slug: String, name: String, prefix: String, repos: [DiscoveredRepo]
  ) throws -> WorkspaceConfig {
    let document: [String: Any] = [
      "workspace": [
        "slug": slug, "name": name, "task_prefix": prefix,
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

/// Everything one scan needs to create or refresh a workspace.
private struct ScanRequest: Sendable {
  let target: ScanTarget

  let choice: ScanChoice

  let slug: String

  let chosenPrefix: String?

  let directory: String

  let roots: [String]

  let repos: [DiscoveredRepo]

  let identity: (ids: any IDGenerator, date: Date)
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
