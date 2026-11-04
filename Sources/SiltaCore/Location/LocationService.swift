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
    let selectedTask = try task.map { try explicitTask($0, workspace: repo.workspace) }
    let git = context.git
    let candidates = context.candidates
    let branch = try await git.value(
      ["symbolic-ref", "--quiet", "--short", "HEAD"], optional: true)
    let head = try await git.required(["rev-parse", "--verify", "HEAD"])
    var result = LocationResult(
      path: context.path.path, worktree: context.root.path,
      workspace: repo.workspace, repo: repo.slug, branch: branch,
      head: head, confidence: "low", reason: "unresolved", candidates: candidates,
      warnings: context.warnings)
    func picked(_ app: String, _ reason: String) -> LocationResult {
      var selected = result
      selected.app = app
      selected.confidence = "high"
      selected.reason = reason
      return selected
    }
    if let app {
      try validate(app, candidates: candidates, repo: repo, path: context.path)
      return picked(app, "explicit")
    }
    if candidates.count == 1, let single = candidates.first { return picked(single.app, "single") }
    let override = try environment.db.read {
      try Self.overrideID(context.root, in: $0)
    }
    if !ignoringOverride, let selected = candidates.first(where: { $0.id == override }) {
      return picked(selected.app, "override")
    }
    if let taskApp = try taskApp(
      selectedTask, branch: branch, repo: repo, candidates: candidates, path: context.path)
    {
      return picked(taskApp, "task")
    }
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
      return try TaskService(environment: environment, workspace: workspace).show(task)
    } catch let error as any CodedError where error.code == .notFound {
      throw CommandFailure(
        error: error, next: ["silta --ws " + shellWord(workspace) + " task ls"])
    }
  }

  private func taskApp(
    _ selected: TaskDetails?, branch: String?, repo: LocationRepository,
    candidates: [LocationCandidate], path: URL
  ) throws -> String? {
    if let selected {
      if let app = selected.app {
        try validate(app, candidates: candidates, repo: repo, path: path)
        return app
      }
      return nil
    }
    return try environment.db.read { db in
      for (column, value) in [("claimed_by", environment.actor.description), ("branch", branch)] {
        guard let value else { continue }
        let ids = try Int64.fetchAll(
          db,
          sql: """
            SELECT DISTINCT task.app_id FROM task JOIN repo ON repo.id=?
            WHERE task.workspace_id=repo.workspace_id AND task.\(column)=?
              AND task.app_id IS NOT NULL AND task.status IN ('todo','doing','review')
            AND task.external_ref IS NULL
            """, arguments: [repo.id, value])
        let matches = candidates.filter { ids.contains($0.id) }
        if matches.count == 1 { return matches.first?.app }
      }
      return nil
    }
  }

  func validate(_ app: String, candidates: [LocationCandidate], repo: LocationRepository, path: URL)
    throws
  {
    guard try WorkspaceSelection.app(app, workspace: repo.workspace, in: environment.db) != nil
    else {
      throw LocationError.app(app, workspace: repo.workspace)
    }
    guard candidates.contains(where: { $0.app == app }) else {
      throw LocationError.outsideCandidates(
        candidates.map(\.app), workspace: repo.workspace, path: path.path)
    }
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
    let root = try LocationPath.canonical(
      URL(
        filePath:
          try await git.required(["rev-parse", "--show-toplevel"])))
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
        refs: refs, warnings: warnings)
    }
    throw unregistered(path: root, workspace: workspace)
  }

  private func unregistered(path: URL, workspace: String?) -> CommandFailure {
    let selection = workspace.map { " --ws " + shellWord($0) } ?? ""
    return CommandFailure(
      error: LocationError.unregistered,
      next: ["silta" + selection + " init --scan " + shellWord(path.path)])
  }
}
