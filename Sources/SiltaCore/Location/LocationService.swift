package import Foundation
import GRDB

/// Resolves a path from registered repositories and live git/task evidence.
package struct LocationService {
  let environment: SiltaEnvironment

  /// Uses injected command dependencies; construction does no I/O.
  package init(environment: SiltaEnvironment) {
    self.environment = environment
  }

  /// Reports low confidence rather than guessing. Reads only truth storage; distance
  /// results may be cached opportunistically in index.db.
  package func resolve(
    path: URL, workspace: String? = nil, app: String? = nil, task: String? = nil,
    cacheWrites: Bool = true
  ) async throws -> LocationResult {
    let context = try await inspect(path: path, workspace: workspace)
    return try await resolve(context, app: app, task: task, cacheWrites: cacheWrites)
  }

  func resolve(
    _ context: LocationContext, app: String?, task: String?, ignoringOverride: Bool = false,
    cacheWrites: Bool = true
  )
    async throws -> LocationResult
  {
    let repo = context.repo
    let explicit = try app.map {
      try validate($0, candidates: context.candidates, repo: repo, path: context.path)
    }
    let selectedTask = try task.map { try explicitTask($0, workspace: repo.workspace) }
    let git = context.git
    let candidates = context.candidates
    let (branch, head) = try await git.headState()
    let current = try await currentTask(
      selectedTask, context: context, app: explicit?.slug, branch: branch)
    var result = LocationResult(
      path: context.path.path, worktree: context.root.path,
      workspace: repo.workspace, repo: repo.slug, branch: branch,
      head: head, confidence: "low", reason: "unresolved", candidates: candidates,
      warnings: context.warnings)
    result.currentTask = current
    result.displayWorktree = context.displayRoot?.path
    func picked(_ app: String, _ reason: String) -> LocationResult {
      var selected = result
      selected.app = app
      selected.confidence = "high"
      selected.reason = reason
      return selected
    }
    if let app, let explicit {
      if let warning = explicit.warning(for: app, kind: .app) { result.warnings.append(warning) }
      return picked(explicit.slug, "explicit")
    }
    if candidates.count == 1, let single = candidates.first { return picked(single.app, "single") }
    let override = try environment.db.read {
      try Self.overrideID(context.root, in: $0)
    }
    if !ignoringOverride, let selected = candidates.first(where: { $0.id == override }) {
      return picked(selected.app, "override")
    }
    if let taskApp = try taskApp(
      current, repo: repo, candidates: candidates, path: context.path)
    {
      return picked(taskApp, "task")
    }
    guard !head.isEmpty else { return result }
    let available = candidates.filter { candidate in context.refs.contains { $0.0 == candidate.app }
    }
    if let evidence = try await git.evidence(branch: branch, candidates: available) {
      result.app = evidence.app
      result.confidence = evidence.app == nil ? "low" : "high"
      result.reason = evidence.reason
      return result
    }
    return try await distance(result, context: context, cacheWrites: cacheWrites)
  }

  private func explicitTask(_ task: String, workspace: String) throws -> TaskDetails {
    do {
      return try environment.db.read { try TaskService.lookup(task, workspace: workspace, in: $0) }
    } catch let error as any CodedError where error.code == .notFound {
      throw CommandFailure(
        error: error, next: ["silta --ws " + shellWord(workspace) + " task ls"])
    }
  }

  private func currentTask(
    _ explicit: TaskDetails?, context: LocationContext,
    app: String?, branch: String?
  ) async throws -> TaskDetails? {
    if let explicit { return explicit }
    func lookup(_ branches: [String], in db: Database) throws -> TaskDetails? {
      try CurrentTaskSelector.select(
        context, app: app, actor: environment.actor.description, branches: branches, in: db)
    }
    let names = branch.map { [$0] } ?? []
    let legacy = branch.map { ["heads/" + $0, gitBranchPrefix + $0] } ?? []
    let (current, hasLegacy) = try environment.db.read { db in
      let current = try lookup(names, in: db)
      guard current == nil, !legacy.isEmpty else { return (current, false) }
      return (nil, try lookup(legacy, in: db) != nil)
    }
    guard hasLegacy, let spelling = try await context.git.legacyBranchSpelling(in: legacy)
    else { return current }
    return try environment.db.read { db in
      try lookup(names, in: db) ?? lookup([spelling], in: db)
    }
  }

  private func taskApp(
    _ selected: TaskDetails?, repo: LocationRepository,
    candidates: [LocationCandidate], path: URL
  ) throws -> String? {
    if let selected {
      if let app = selected.app {
        return try validate(app, candidates: candidates, repo: repo, path: path).slug
      }
      return nil
    }
    return nil
  }

  func validate(_ app: String, candidates: [LocationCandidate], repo: LocationRepository, path: URL)
    throws -> WorkspaceSlugs.Resolved
  {
    guard
      let named = try WorkspaceSelection.appName(app, workspace: repo.workspace, in: environment.db)
    else {
      throw LocationError.app(app, workspace: repo.workspace)
    }
    guard candidates.contains(where: { $0.app == named.slug }) else {
      throw LocationError.outsideCandidates(
        candidates.map(\.app), workspace: repo.workspace, path: path.path)
    }
    return named
  }

  func inspect(path: URL, workspace: String?) async throws
    -> LocationContext
  {
    let path = try LocationPath.canonical(path)
    guard try path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw LocationError.invalidPath
    }
    let git = LocationGit(runner: environment.git, directory: path)
    guard let common = try await git.commonDirectory() else {
      throw LocationError.outsideRepository
    }
    if let workspace { _ = try WorkspaceSelection.resolve(workspace, in: environment.db) }
    let displayRoot = URL(filePath: try await git.required(["rev-parse", "--show-toplevel"]))
    let root = try LocationPath.canonical(displayRoot)
    for repo in try LocationRepository.all(workspace: workspace, in: environment.db) {
      guard FileManager.default.fileExists(atPath: repo.path) else { continue }
      let registered = LocationGit(runner: environment.git, directory: URL(filePath: repo.path))
      let expected = try? await registered.commonDirectory()  // Skip stale registrations.
      guard expected == common else { continue }
      let candidates = try repo.candidates(at: path, root: root)
      var refs: [(String, String)] = []
      var warnings: [OutputWarning] = []
      for candidate in candidates {
        if let sha = try await git.refSHA(candidate.ref) {
          refs.append((candidate.app, sha))
        } else {
          warnings.append(
            .init(
              code: "ref_missing",
              message:
                "Ref \(candidate.ref) for \(candidate.app) is missing; run silta --ws "
                + shellWord(repo.workspace) + " repo fetch " + shellWord(repo.slug) + "."))
        }
      }
      return LocationContext(
        path: path, root: root, repo: repo, git: git, candidates: candidates,
        refs: refs, warnings: warnings, displayRoot: displayRoot)
    }
    if let recovery = try await RepositoryScan.repair(
      root, workspace: workspace, store: environment.db, git: environment.git)
    {
      throw CommandFailure(
        error: LocationError.unregistered, next: recovery.next, message: recovery.message)
    }
    throw unregistered(path: root, workspace: workspace)
  }

  private func unregistered(path: URL, workspace: String?) -> CommandFailure {
    let next =
      workspace.map { "silta --ws " + shellWord($0) + " ws show" }
      ?? ("silta init --scan " + shellWord(path.path))
    return CommandFailure(error: LocationError.unregistered, next: [next])
  }
}
