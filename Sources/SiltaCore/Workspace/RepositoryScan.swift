import Darwin
package import Foundation
import GRDB

/// What a scan bound: the workspace it created or refreshed.
package struct ScanOutcome: Sendable {
  package struct App: Encodable, Sendable {
    package let slug: String
    /// Distinct display name, if configured.
    package let name: String?
  }

  package let workspace: String
  /// Slugs of the configured repositories bound by the scan.
  package let repositories: [String]
  /// Configured apps on those repositories.
  package let apps: [App]
  /// Skipped child directories or generated app stubs.
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
    identity: (ids: any IDGenerator, date: Date), human: Bool = false
  ) async throws -> ScanOutcome {
    guard let first = roots.first else { throw RepoError.scan }
    let paths = roots.map(\.path)
    let readable = try roots.map(readableRoot)
    let directory = first.standardizedFileURL.lastPathComponent
    let naming = try naming(target, directory: directory, roots: paths)
    let (repos, skipped) = try await discover(Array(zip(paths, readable)), git: git)
    if repos.isEmpty {
      if let firstSkipped = skipped.first { throw ScanError.unreadableRoot(firstSkipped) }
      throw ScanError.noRepositories(paths)
    }
    let request = ScanRequest(
      target: target, choice: ScanChoice(target), slug: naming.slug,
      chosenPrefix: naming.prefix, directory: directory, roots: paths, repos: repos,
      skipped: skipped, identity: identity, human: human)
    return try store.write { tx in
      try apply(tx, request: request)
    }
  }

  /// Creates or refreshes the workspace and binds every discovered clone in one write.
  private static func apply(_ tx: StorageTransaction, request: ScanRequest) throws -> ScanOutcome {
    do {
      let db = tx.database
      let existing = try existingWorkspace(request.slug, in: db)
      if let reserved = request.repos.first(where: { $0.slug == TaskDraft.noneApp }) {
        throw ScanError.reservedSlug(path: reserved.path.path)
      }
      guard Set(request.repos.map(\.slug)).count == request.repos.count else {
        throw RepoError.duplicateSlug
      }
      let bindings = try implicitBindings(request, workspace: existing?["slug"], in: db)
      if case .named(let chosenSlug, _) = request.target, let existing {
        throw ScanError.slugExists(
          chosen: chosenSlug != nil, workspace: existing["slug"] as String)
      }
      if case .rescan = request.target, existing == nil { throw WorkspaceError.notFound }
      let workspace = existing.map { $0["slug"] as String } ?? request.slug
      let repos = request.repos
      var warnings = request.skipped.map {
        OutputWarning(
          code: "scan_skipped", message: "Skipped unreadable directory \($0.debugDescription).")
      }
      if existing == nil {
        let prefix = try creationPrefix(request, in: db)
        let (apps, skippedApps) = generatedApps(repos)
        warnings += skippedApps
        let config = try configuration(
          slug: workspace, name: name(request.target, directory: request.directory), prefix: prefix,
          repos: repos, apps: apps)
        try config.apply(in: tx, ids: request.identity.ids, at: request.identity.date)
      }
      let registration = try registerPaths(
        request, workspace: workspace, bindings: bindings, created: existing == nil, in: db)
      if let existing { try tx.recordChange(kind: "workspace", rowID: existing["id"] as Int64) }
      return ScanOutcome(
        workspace: workspace, repositories: registration.repositories, apps: registration.apps,
        warnings: warnings + registration.warnings)
    } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
      throw WorkspaceError.conflict
    }
  }

  /// The workspace the scan target names, matched without regard to case.
  private static func existingWorkspace(_ slug: String, in db: Database) throws -> Row? {
    try Row.fetchOne(
      db, sql: "SELECT id,slug FROM workspace WHERE lower(slug)=lower(?)", arguments: [slug])
  }

  private static func implicitBindings(
    _ request: ScanRequest, workspace: String?, in db: Database
  ) throws -> [String: ScanRegistration] {
    if case .rescan = request.target { return [:] }
    let paths = request.repos.map { $0.path.path }
    let matches = try request.repos.map {
      try ScanRegistration.matching(path: $0.path.path, slug: $0.slug, origin: $0.remote, in: db)
    }
    if case .named = request.target, !matches.joined().contains(where: { !$0.isWeakSlug }) {
      return [:]
    }
    let recovery = ScanRegistration.recovery(matches, paths: paths, roots: request.roots)
    if case .derived = request.target, let workspace, !paths.isEmpty {
      if let bindings = derivedBindings(matches, paths: paths, workspace: workspace) {
        return bindings
      }
      if recovery == nil { throw ScanError.unverifiedWorkspace(workspace) }
    }
    guard let recovery else { return [:] }
    if paths.count == 1, let path = paths.first, let match = matches.first?.first,
      matches.first?.count == 1, match.path == path,
      match.workspace.lowercased() != request.slug.lowercased()
    {
      throw ScanError.repoPathTaken(repo: match.repo, path: path, workspace: match.workspace)
    }
    throw recovery
  }

  private static func derivedBindings(
    _ matches: [[ScanRegistration]], paths: [String], workspace: String
  ) -> [String: ScanRegistration]? {
    guard let rows = ScanRegistration.identities(matches),
      zip(rows, paths).allSatisfy({ binding, path in
        binding.workspace == workspace && binding.path != nil
          && canBind(path, insteadOf: binding.path)
      })
    else { return nil }
    return Dictionary(uniqueKeysWithValues: zip(paths, rows))
  }

  /// Binds each clone to its repo row, after refusing a path another workspace holds.
  private static func registerPaths(
    _ request: ScanRequest, workspace: String, bindings: [String: ScanRegistration],
    created: Bool, in db: Database
  ) throws -> ScanOutcome {
    let repos = request.repos
    let matches = try repos.map { repo -> Binding in
      let path = repo.path.path
      if let holder = try pathHolder(path, excluding: workspace, in: db) {
        throw ScanError.repoPathTaken(repo: holder.repo, path: path, workspace: holder.workspace)
      }
      if let binding = bindings[path] { return Binding(id: binding.id, slug: binding.repo) }
      return try registeredRepo(
        repo, workspace: workspace, created: created,
        permitMismatch: request.permitsMismatchedOrigin, in: db)
    }
    guard Set(matches.map(\.id)).count == matches.count else {
      throw ScanError.registeredWorkspaces([workspace], roots: nil)
    }
    var apps: [ScanOutcome.App] = []
    for (repo, match) in zip(repos, matches) {
      apps += try Row.fetchAll(
        db, sql: "SELECT slug,NULLIF(name,slug) AS display_name FROM app WHERE repo_id=?",
        arguments: [match.id]
      ).map { ScanOutcome.App(slug: $0["slug"], name: $0["display_name"]) }
      try db.execute(
        sql: """
          INSERT INTO repo_path(repo_id,path)
          VALUES(?,?)
          ON CONFLICT(repo_id) DO UPDATE SET path=excluded.path
          """, arguments: [match.id, repo.path.path])
    }
    return ScanOutcome(
      workspace: workspace, repositories: matches.map(\.slug).sorted(),
      apps: apps.sorted { $0.slug < $1.slug }, warnings: matches.compactMap(\.warning))
  }

  private struct Binding {
    let id: Int64
    let slug: String
    var warning: OutputWarning?
  }

  private static func registeredRepo(
    _ repo: DiscoveredRepo, workspace: String, created: Bool, permitMismatch: Bool, in db: Database
  ) throws -> Binding {
    if !created, let match = try existingBinding(repo, workspace: workspace, in: db) {
      return Binding(id: match.id, slug: match.repo)
    }
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT repo.id, repo.slug, repo.remote_url, repo_path.path
          FROM repo JOIN workspace ON workspace.id=repo.workspace_id
          LEFT JOIN repo_path ON repo_path.repo_id=repo.id
          WHERE workspace.slug=? AND repo.slug=?
          """, arguments: [workspace, repo.slug])
    else { throw RepoError.configuration(repo: repo.slug, workspace: workspace) }
    var binding = Binding(id: row["id"], slug: row["slug"])
    guard !created else { return binding }
    let bound: String? = row["path"]
    guard canBind(repo.path.path, insteadOf: bound) else {
      throw ScanError.registeredWorkspaces([workspace], roots: nil)
    }
    if let configured = row["remote_url"] as String?, !configured.isEmpty, let origin = repo.remote
    {
      guard permitMismatch, bound == nil else {
        throw ScanError.registeredWorkspaces([workspace], roots: nil)
      }
      binding.warning = ScanRegistration.mismatchWarning(declared: configured, checkout: origin)
    }
    return binding
  }

  /// Resolves existing registration evidence before a scoped rescan can use a repo's slug.
  private static func existingBinding(_ repo: DiscoveredRepo, workspace: String, in db: Database)
    throws -> ScanRegistration?
  {
    let path = repo.path.path
    let matches = try ScanRegistration.matching(
      path: path, slug: repo.slug, origin: repo.remote, in: db
    )
    .filter { $0.workspace == workspace && !$0.isMismatchedSlug }
    if matches.count == 1, let match = matches.first,
      match.isIdentity || (match.repo == repo.slug && match.permitsSelectedSlug),
      canBind(path, insteadOf: match.path)
    {
      return match
    }
    if !matches.isEmpty { throw ScanError.registeredWorkspaces([workspace], roots: nil) }
    return nil
  }

  private static func canBind(_ path: String, insteadOf recorded: String?) -> Bool {
    guard let recorded, recorded != path else { return true }
    // Refuse to replace a registration when its old checkout cannot be inspected.
    var marker = stat()
    return lstat(recorded + "/.git", &marker) != 0 && errno == ENOENT
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
        prefix, derived: derived, workspace: holder)
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

  private static func discover(_ roots: [(String, URL)], git: any GitRunner) async throws
    -> (repos: [DiscoveredRepo], skipped: [String])
  {
    var candidates: Set<String> = []
    var skipped: [String] = []
    for (path, directory) in roots {
      do {
        try walk(directory, depth: 0, into: &candidates, skipped: &skipped)
      } catch { throw ScanError.unreadableRoot(path) }
    }
    var found: [String: DiscoveredRepo] = [:]
    for candidate in candidates.sorted() {
      let directory = URL(filePath: candidate)
      let main = try await mainClone(directory, git: git)
      if found[main.path] != nil { continue }
      let url = try await cloneOrigin(main, git: git)
      let refs = try await output(
        ["for-each-ref", "--format=%(refname:short)", "refs/remotes"], in: main, git: git)
      found[main.path] = DiscoveredRepo(
        path: main, slug: suggestedSlug(main.lastPathComponent), remote: url,
        refs: refs.split(separator: "\n").map(String.init))
    }
    return (found.values.sorted { $0.path.path < $1.path.path }, Array(Set(skipped)).sorted())
  }

  private static func mainClone(_ directory: URL, git: any GitRunner) async throws -> URL {
    let worktrees = try await output(
      ["worktree", "list", "--porcelain", "-z"], in: directory, git: git)
    guard let entry = worktrees.split(separator: "\0").first, entry.hasPrefix("worktree ") else {
      throw RepoError.scan
    }
    return try canonical(URL(filePath: String(entry.dropFirst(9))))
  }

  private static func cloneOrigin(_ directory: URL, git: any GitRunner) async throws -> String? {
    let result: GitResult
    do {
      result = try await git.run(
        .init(arguments: ["remote", "get-url", "origin"], directory: directory))
    } catch { throw RepoError.scan }
    if result.termination == .exit(2) { return nil }
    guard result.termination == .exit(0), let text = String(data: result.stdout, encoding: .utf8)
    else { throw RepoError.scan }
    return text.trimmingCharacters(in: .newlines)
  }

}

extension RepositoryScan {
  /// Gives first-run instructions scoped to a Git checkout when one is present.
  package static func firstScanCommand(in directory: URL, git: any GitRunner) async -> String {
    do {
      let raw = try await output(["rev-parse", "--show-toplevel"], in: directory, git: git)
      let path = raw.trimmingCharacters(in: .newlines)
      let root = try canonical(URL(filePath: path))
      let current = try canonical(directory)
      let argument = current.path == root.path ? "." : shellWord(root.path)
      let derived = root.lastPathComponent.lowercased()
      let needsSlug = !WorkspaceConfig.isValidIdentifier(derived)
      let slug = needsSlug ? suggestedSlug(derived) : derived
      var command = "silta init --scan " + argument
      if needsSlug { command += " --slug " + shellWord(slug) }
      if !WorkspaceConfig.isValidIdentifier(String(slug.prefix(2))) {
        let prefix = slug.replacing(/[^a-z0-9]/, with: "").prefix(2).uppercased()
        command += " --prefix " + shellWord(prefix)
      }
      return command
    } catch {
      return "silta init --help"
    }
  }

  /// Finds existing declarations for an unregistered checkout without writing storage.
  static func repair(
    _ root: URL, workspace: String?, store: DatabaseStore, git: any GitRunner
  ) async throws -> ScanError? {
    guard !DatabaseFile.isMissing(store.path) else { return nil }
    let hasCandidates = try store.read {
      try Bool.fetchOne(
        $0,
        sql: """
          SELECT EXISTS(
            SELECT 1 FROM repo LEFT JOIN repo_path ON repo_path.repo_id=repo.id
            WHERE repo_path.repo_id IS NULL OR repo.remote_url<>''
          )
          """) ?? false
    }
    guard hasCandidates else { return nil }
    let main: URL
    let origin: String?
    do {
      main = try await mainClone(root, git: git)
      origin = try await cloneOrigin(main, git: git)
    } catch {
      return nil
    }
    let found = try store.read {
      try ScanRegistration.matching(
        path: main.path, slug: suggestedSlug(main.lastPathComponent), origin: origin, in: $0
      ).filter {
        workspace == nil || $0.workspace == workspace
      }
    }
    return ScanRegistration.recovery([found], paths: [main.path], roots: [main.path])
  }

  private static func walk(
    _ directory: URL, depth: Int, into paths: inout Set<String>, skipped: inout [String]
  ) throws {
    let fm = FileManager.default
    try requireReadable(directory)
    if fm.fileExists(atPath: directory.appending(path: ".git").path) {
      paths.insert(directory.path)
      return
    }
    guard depth < 2 else { return }
    let children = try fm.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [])
    for child in children {
      do {
        guard try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        else { continue }
        try walk(canonical(child), depth: depth + 1, into: &paths, skipped: &skipped)
      } catch { skipped.append(child.path) }
    }
  }

  private static func readableRoot(_ root: URL) throws -> URL {
    do {
      let directory = try canonical(root)
      try requireReadable(directory)
      return directory
    } catch { throw ScanError.unreadableRoot(root.path) }
  }

  private static func requireReadable(_ directory: URL) throws {
    let fm = FileManager.default
    guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
      fm.isReadableFile(atPath: directory.path), fm.isExecutableFile(atPath: directory.path)
    else { throw RepoError.scan }
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

  private static func generatedApps(_ repos: [DiscoveredRepo])
    -> (apps: [[String: String]], warnings: [OutputWarning])
  {
    var apps: [[String: String]] = []
    var warnings: [OutputWarning] = []
    var used: Set<String> = []
    for var app in repos.flatMap(\.apps) {
      guard let raw = app["slug"] else { continue }
      let slug = suggestedSlug(raw)
      if WorkspaceConfig.reservedAppSlug(slug) || !used.insert(slug).inserted {
        warnings.append(
          .init(
            code: "scan_skipped_app",
            message: "Skipped reserved or duplicate generated app \(slug.debugDescription)."))
      } else {
        app["slug"] = slug
        apps.append(app)
      }
    }
    return (apps, warnings)
  }

  private static func configuration(
    slug: String, name: String, prefix: String, repos: [DiscoveredRepo], apps: [[String: String]]
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
      "apps": apps,
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

  let skipped: [String]

  let identity: (ids: any IDGenerator, date: Date)
  let human: Bool

  var permitsMismatchedOrigin: Bool {
    if case .rescan = target { return human }
    return false
  }
}

private struct DiscoveredRepo: Sendable {
  let path: URL

  let slug: String

  let remote: String?

  let refs: [String]

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
